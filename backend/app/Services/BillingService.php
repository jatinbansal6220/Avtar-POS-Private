<?php
namespace App\Services;

use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;

final class BillingService {
    private function ids(array $order, string $field, ?string $ownId): array {
        $value=$order[$field]??[];
        if (is_string($value)) $value=json_decode($value,true)?:[];
        // Old POS/takeaway receipts legitimately have no table id. Keep this
        // helper null-safe so a valid bill can never become a server 500 and
        // remain permanently pending in a terminal's invoice outbox.
        return array_values(array_unique(array_filter([$ownId,...(is_array($value)?$value:[])],fn($id)=>is_string($id) && $id!=='')));
    }

    public function bill(int $tenant,array $v,string $cashier): array {
        $order=Records::get('orders',$tenant,$v['order_id']);
        abort_unless($order['status']==='open',409,'This order has already been finalized.');
        abort_unless($order['version']==$v['version'],409,'Order changed. Reload before billing.');
        $orderIds=$this->ids($order,'merged_order_ids',$order['id']);
        $memberOrders=[]; $items=[]; $tableSections=[];
        foreach($orderIds as $orderId) {
            $member=Records::get('orders',$tenant,$orderId);
            abort_unless($member['status']==='open',409,'One joined table order has already been closed.');
            $memberOrders[]=$member;
            $sectionItems=[]; $sectionSubtotal=0;
            foreach($member['items'] as $item) {
                // The order owns the table label. Do not trust a stale client
                // item value here: a joined receipt must always group every
                // item below the table that actually owns its order.
                $item['source_table_number']=$member['table_number'];
                $items[]=$item;
                $sectionItems[]=$item;
                $sectionSubtotal+=(int)$item['quantity']*(int)$item['price_minor'];
            }
            if ($sectionItems) $tableSections[]=[
                'table_id'=>$member['table_id'],
                'table_number'=>$member['table_number'],
                'items'=>$sectionItems,
                'subtotal_minor'=>$sectionSubtotal,
            ];
        }
        abort_unless(count($items)>0,422,'Add at least one item.');
        // POS, takeaway and online orders have no table_id. Only dining
        // orders can carry joined-table ids, so never pass a null table id to
        // the typed helper. This was the source of a 500 that left otherwise
        // valid non-table invoices permanently pending in the client outbox.
        $tableIds=!empty($order['table_id'])
            ? $this->ids($order,'merged_table_ids',$order['table_id'])
            : [];
        // A joined party may use an additional table before ordering from it.
        // Preserve that empty table in the final receipt/table release even
        // though it intentionally has no member order or receipt line.
        $tableNumbers=[];
        foreach($tableIds as $tableId) $tableNumbers[]=Records::get('tables',$tenant,$tableId)['table_number'];
        if (!$tableNumbers) $tableNumbers=[$order['table_number']];
        $settings=Records::query('settings',$tenant)->first(); abort_unless($settings,422,'Complete restaurant settings first.');
        $bank=null;
        if (!empty($v['bank_account_id'])) {
            $bank=Records::get('banks',$tenant,$v['bank_account_id']);
            abort_unless(in_array($bank['is_active']??false,[true,1,'1','true'],true),422,'Bank account is disabled.');
        }
        $qrBank=null;
        if (!empty($v['qr_bank_account_id'])) {
            $qrBank=Records::get('banks',$tenant,$v['qr_bank_account_id']);
            abort_unless(in_array($qrBank['is_active']??false,[true,1,'1','true'],true),422,'Bill QR account is disabled.');
            abort_unless(!empty($qrBank['qr_image_base64']),422,'The selected bill QR account has no QR image.');
        }
        // Electronic payments require a valid bank even when this bill is
        // saved offline first and reaches the server later through sync.
        $paymentRows=$v['payments']??[];
        $hasCardTender=in_array($v['payment_method'],['card','online'],true)
            || ($v['payment_method']==='mixed' && collect($paymentRows)->contains(fn($payment)=>in_array($payment['method'],['card','online'],true) && (int)$payment['amount_minor']>0));
        $hasUpiTender=$v['payment_method']==='upi'
            || ($v['payment_method']==='mixed' && collect($paymentRows)->contains(fn($payment)=>$payment['method']==='upi' && (int)$payment['amount_minor']>0));
        // Account/QR validation was introduced after some terminals had
        // already saved legitimate invoices offline. Those historical queue
        // entries do not carry payment_schema_version or bank ids. Continue
        // accepting them so an upgrade never strands invoice data, while all
        // current clients explicitly send version 2 and remain strict.
        $requiresPaymentAccounts=(int)($v['payment_schema_version']??0)>=2;
        abort_if($requiresPaymentAccounts && $hasCardTender && !$bank,422,'Select an active Card settlement account before saving this payment.');
        abort_if($requiresPaymentAccounts && $hasUpiTender && !$qrBank,422,'Select an active UPI account with an uploaded bill QR before saving this payment.');
        // Cash-only invoices intentionally have no settlement bank. Do not
        // inspect a null bank while validating card payments: PHP 8 throws a
        // TypeError here, which previously turned a valid cash bill into a
        // 500 response and left the local sync outbox permanently pending.
        $cardEnabled=$bank===null || (array_key_exists('use_for_card',$bank)
            ? in_array($bank['use_for_card'],[true,1,'1','true'],true)
            : in_array($bank['account_type']??'', ['card','current','savings','cash_drawer'],true));
        abort_if($requiresPaymentAccounts && $hasCardTender && !$cardEnabled,422,'Enable Use for Card on the selected settlement account first.');
        abort_if($requiresPaymentAccounts && $hasUpiTender && !in_array($qrBank['account_type']??'', ['upi','upi_merchant'],true),422,'The selected bill QR is not a UPI account.');
        $subtotal=0; $itemDiscount=0;
        foreach ($items as $item) {
            $line=(int)$item['quantity']*(int)$item['price_minor'];
            $subtotal += $line;
            $type=$item['discount_type']??'percent'; $value=(int)($item['discount_value']??0);
            $itemDiscount += $type==='fixed' ? $value : (int)round($line*$value/10000);
        }
        // Older desktop/mobile builds sent the display label "minus". It is
        // a fixed rupee discount, accepted here to release any saved outbox
        // invoices after an app upgrade.
        $displayType=$v['discount_display_type']??($v['discount_type']??'percent');
        $discountType=in_array($displayType,['minus','charges_not_applicable'],true)?'fixed':($v['discount_type']??'percent');
        $discountValue=(int)($v['discount_value']??$v['discount_basis_points']);
        abort_if($displayType==='charges_not_applicable' && empty(trim((string)($v['settlement_remark']??''))),422,'A settlement remark is required when charges are not applicable.');
        abort_if($discountType==='percent' && $discountValue>10000,422,'Bill discount cannot exceed 100%.');
        abort_if($discountType==='fixed' && $discountValue>$subtotal-$itemDiscount,422,'Bill discount exceeds the amount available.');
        $billDiscount=$discountType==='fixed' ? $discountValue : (int)round(($subtotal-$itemDiscount)*$discountValue/10000);
        $discount=$itemDiscount+$billDiscount;
        // Database drivers may return booleans as 0/1 or strings. Never let a
        // non-empty string such as "false" turn GST on for a final invoice.
        $taxEnabled=in_array($settings->is_tax_enabled,[true,1,'1','true'],true);
        $taxRate=$taxEnabled?(int)$settings->tax_basis_points:0;
        $tax=(int)round(($subtotal-$discount)*$taxRate/10000);
        $additionalCharges=$v['additional_charges']??[];
        $additionalAmount=array_sum(array_map(fn($charge)=>(int)$charge['amount_minor'],$additionalCharges));
        $total=$subtotal-$discount+$tax+$additionalAmount;
        $payments=$v['payments']??[];
        if (!$payments) $payments=[['method'=>$v['payment_method'],'amount_minor'=>$total]];
        abort_if($v['payment_method']==='mixed' && count($payments)<2,422,'Split payment needs at least two tenders.');
        abort_if(count($payments)>1 && $v['payment_method']!=='mixed',422,'Use mixed payment for multiple tenders.');
        abort_if(array_sum(array_map(fn($payment)=>(int)$payment['amount_minor'],$payments))!==$total,422,'Payment amounts must equal the bill total.');
        $parts=$v['split_amounts']??[];
        abort_if($parts && array_sum($parts)!==$total,422,'Bill parts must equal the total.');
        // The counter belongs to a terminal so it can reset daily and keep
        // working offline. The server stores terminal + number as the unique
        // receipt identity; this permits a phone and desktop to both create
        // BILL-YYYYMMDD-001 without losing either legitimate sale.
        $id=(string)Str::uuid();
        $hasTerminalBill=!empty($v['client_bill_number']) || !empty($v['client_generated_at']) || !empty($v['source_terminal_id']);
        if ($hasTerminalBill) {
            abort_unless(!empty($v['client_bill_number']) && !empty($v['client_generated_at']) && !empty($v['source_terminal_id']) && !empty($v['source_terminal_label']),422,'Incomplete terminal bill identity. Update this terminal before retrying.');
            $generated=\Carbon\CarbonImmutable::parse($v['client_generated_at'],'Asia/Kolkata');
            $number=$v['client_bill_number'];
            abort_unless(preg_match('/^BILL-(\d{8})-\d{3,}$/',$number,$parts)===1 && $parts[1]===$generated->format('Ymd'),422,'Bill number must match the bill date.');
            $terminalId=$v['source_terminal_id'];
            $terminalLabel=$v['source_terminal_label'];
        } else {
            // Existing desktop/APK builds remain billable during rollout.
            $generated=now('Asia/Kolkata');
            $daily=(clone Records::query('bills',$tenant))->whereDate('generated_at',$generated->toDateString())->count()+1;
            $number='BILL-'.$generated->format('Ymd').'-'.str_pad((string)$daily,3,'0',STR_PAD_LEFT);
            $terminalId=null;
            $terminalLabel='Legacy terminal';
        }
        if ($terminalId!==null) {
            $duplicate=Records::query('bills',$tenant)
                ->where('source_terminal_id',$terminalId)
                ->where('bill_number',$number)
                ->exists();
            abort_if($duplicate,409,'This terminal already has the same daily bill number. Check the device date or open Sync review.');
        }
        $receipt=['restaurant'=>array_intersect_key((array)$settings,array_flip(['restaurant_name','restaurant_address','restaurant_phone','gstin','fssai_lic','tagline','timezone'])),
            'bill_number'=>$number,'source_terminal_id'=>$terminalId,'source_terminal_label'=>$terminalLabel,
            'table_number'=>implode(' + ',$tableNumbers),'merged_table_numbers'=>$tableNumbers,'order_type'=>$order['order_type'],'online_platform'=>$order['online_platform'],'online_platform_name'=>$order['online_platform_name'],
            'customer_name'=>$order['customer_name'],'customer_phone'=>$order['customer_phone'],'items'=>$items,'table_sections'=>$tableSections,
            'voids'=>is_string($order['voids']??null)?json_decode($order['voids'],true):($order['voids']??[]),'subtotal_minor'=>$subtotal,
            'item_discount_minor'=>$itemDiscount,'bill_discount_minor'=>$billDiscount,'discount_minor'=>$discount,'tax_minor'=>$tax,'additional_amount_minor'=>$additionalAmount,'additional_charges'=>$additionalCharges,'total_minor'=>$total,
            'tax_basis_points'=>$taxRate,'discount_basis_points'=>$v['discount_basis_points'],'discount_type'=>$discountType,'discount_display_type'=>$displayType,'discount_value'=>$discountValue,
            'settlement_remark'=>$v['settlement_remark']??null,
            'payment_method'=>$v['payment_method'],'payments'=>$payments,'split_amounts'=>$parts,'bank_account_name'=>$bank['account_name']??null,
            'qr_bank_account_id'=>$qrBank['id']??null,'qr_bank_account_name'=>$qrBank['account_name']??null,'qr_upi_id'=>$qrBank['account_number']??null,'qr_image_base64'=>$qrBank['qr_image_base64']??null,
            'cashier_name'=>$cashier,'generated_at'=>$generated->toIso8601String()];
        $receipt['items']=$items;
        DB::table('bills')->insert(['id'=>$id,'user_id'=>$tenant,'order_id'=>$order['id'],'bill_number'=>$number,
            'source_terminal_id'=>$terminalId,'source_terminal_label'=>$terminalLabel,'table_id'=>$order['table_id'],
            'table_number'=>$order['table_number'],'subtotal_minor'=>$subtotal,'item_discount_minor'=>$itemDiscount,'bill_discount_minor'=>$billDiscount,'additional_amount_minor'=>$additionalAmount,
            'discount_minor'=>$discount,'tax_minor'=>$tax,'total_minor'=>$total,
            'tax_basis_points'=>$taxRate,'discount_basis_points'=>$v['discount_basis_points'],'payment_method'=>$v['payment_method'],'bank_account_id'=>$v['bank_account_id']??null,
            'payments'=>json_encode($payments),'split_amounts'=>json_encode($parts),'receipt'=>json_encode($receipt),'generated_at'=>$generated,'created_at'=>$generated,'updated_at'=>$generated]);
        DB::table('orders')->whereIn('id',$orderIds)->update(['status'=>'billed','version'=>DB::raw('version + 1'),'updated_at'=>now()]);
        foreach($tableIds as $tableId) {
            DB::table('tables')->where('id',$tableId)->update(['status'=>'empty','current_order_id'=>null,'version'=>DB::raw('version + 1'),'updated_at'=>now()]);
            Records::emit('tables',$tenant,$tableId);
        }
        foreach($orderIds as $orderId) Records::emit('orders',$tenant,$orderId);
        Records::emit('bills',$tenant,$id);
        return Records::get('bills',$tenant,$id);
    }

    /**
     * Re-settles an already-issued invoice without reopening its order or
     * changing its immutable menu lines. Every save appends an audit entry to
     * the receipt itself, making the full settlement history available to all
     * terminals through normal bill sync.
     */
    public function settle(int $tenant, string $billId, array $v, string $cashier): array {
        return DB::transaction(function () use ($tenant, $billId, $v, $cashier): array {
            $row=DB::table('bills')->where('id',$billId)->where('user_id',$tenant)->whereNull('deleted_at')->lockForUpdate()->first();
            abort_unless($row,404,'Invoice not found.');
            $bill=Records::decode('bills',$row);
            abort_unless((int)$bill['version']===(int)$v['version'],409,'Invoice changed on another device. Reload it before editing settlement.');
            $receipt=is_array($bill['receipt']??null)?$bill['receipt']:[];
            $items=is_array($receipt['items']??null)?$receipt['items']:[];
            abort_unless($items,422,'This invoice has no items to settle.');
            $settings=Records::query('settings',$tenant)->first();
            abort_unless($settings,422,'Complete restaurant settings first.');

            $bank=null;
            if (!empty($v['bank_account_id'])) {
                $bank=Records::get('banks',$tenant,$v['bank_account_id']);
                abort_unless(in_array($bank['is_active']??false,[true,1,'1','true'],true),422,'Bank account is disabled.');
            }
            $qrBank=null;
            if (!empty($v['qr_bank_account_id'])) {
                $qrBank=Records::get('banks',$tenant,$v['qr_bank_account_id']);
                abort_unless(in_array($qrBank['is_active']??false,[true,1,'1','true'],true),422,'Bill QR account is disabled.');
                abort_unless(!empty($qrBank['qr_image_base64']),422,'The selected bill QR account has no QR image.');
            }
            $paymentRows=$v['payments']??[];
            $hasCardTender=in_array($v['payment_method'],['card','online'],true)
                || ($v['payment_method']==='mixed' && collect($paymentRows)->contains(fn($payment)=>in_array($payment['method'],['card','online'],true) && (int)$payment['amount_minor']>0));
            $hasUpiTender=$v['payment_method']==='upi'
                || ($v['payment_method']==='mixed' && collect($paymentRows)->contains(fn($payment)=>$payment['method']==='upi' && (int)$payment['amount_minor']>0));
            $requiresPaymentAccounts=(int)($v['payment_schema_version']??0)>=2;
            abort_if($requiresPaymentAccounts && $hasCardTender && !$bank,422,'Select an active Card settlement account for this settlement.');
            abort_if($requiresPaymentAccounts && $hasUpiTender && !$qrBank,422,'Select an active UPI QR account for this settlement.');
            // Settlement can also be cash-only, so a missing bank is valid
            // until a card tender actually requires one.
            $cardEnabled=$bank===null || (array_key_exists('use_for_card',$bank)
                ? in_array($bank['use_for_card'],[true,1,'1','true'],true)
                : in_array($bank['account_type']??'', ['card','current','savings','cash_drawer'],true));
            abort_if($requiresPaymentAccounts && $hasCardTender && !$cardEnabled,422,'Enable Use for Card on the selected settlement account first.');
            abort_if($requiresPaymentAccounts && $hasUpiTender && !in_array($qrBank['account_type']??'', ['upi','upi_merchant'],true),422,'The selected bill QR is not a UPI account.');

            $subtotal=0; $itemDiscount=0;
            foreach ($items as $item) {
                $line=(int)$item['quantity']*(int)$item['price_minor'];
                $subtotal+=$line;
                $type=$item['discount_type']??'percent'; $value=(int)($item['discount_value']??0);
                $itemDiscount+=$type==='fixed'?$value:(int)round($line*$value/10000);
            }
            $displayType=$v['discount_display_type']??($v['discount_type']??'percent');
            $discountType=in_array($displayType,['minus','charges_not_applicable'],true)?'fixed':($v['discount_type']??'percent');
            $discountValue=(int)($v['discount_value']??$v['discount_basis_points']);
            abort_if($displayType==='charges_not_applicable' && empty(trim((string)($v['settlement_remark']??''))),422,'A settlement remark is required when charges are not applicable.');
            abort_if($discountType==='percent' && $discountValue>10000,422,'Bill discount cannot exceed 100%.');
            abort_if($discountType==='fixed' && $discountValue>$subtotal-$itemDiscount,422,'Bill discount exceeds the amount available.');
            $billDiscount=$discountType==='fixed'?$discountValue:(int)round(($subtotal-$itemDiscount)*$discountValue/10000);
            $discount=$itemDiscount+$billDiscount;
            $taxEnabled=in_array($settings->is_tax_enabled,[true,1,'1','true'],true);
            $taxRate=$taxEnabled?(int)$settings->tax_basis_points:0;
            $tax=(int)round(($subtotal-$discount)*$taxRate/10000);
            $additionalCharges=$v['additional_charges']??[];
            $additionalAmount=array_sum(array_map(fn($charge)=>(int)$charge['amount_minor'],$additionalCharges));
            $total=$subtotal-$discount+$tax+$additionalAmount;
            $payments=$v['payments']??[];
            if (!$payments) $payments=[['method'=>$v['payment_method'],'amount_minor'=>$total]];
            abort_if($v['payment_method']==='mixed' && count($payments)<2,422,'Split payment needs at least two tenders.');
            abort_if(count($payments)>1 && $v['payment_method']!=='mixed',422,'Use mixed payment for multiple tenders.');
            abort_if(array_sum(array_map(fn($payment)=>(int)$payment['amount_minor'],$payments))!==$total,422,'Payment amounts must equal the bill total.');
            $parts=$v['split_amounts']??[];
            abort_if($parts && array_sum($parts)!==$total,422,'Bill parts must equal the total.');

            $audit=$receipt['settlement_edits']??[];
            if (!is_array($audit)) $audit=[];
            $audit[]=[
                'edited_at'=>now('Asia/Kolkata')->toIso8601String(),
                'edited_by'=>$cashier,
                'remark'=>trim((string)$v['settlement_remark']),
                'previous_total_minor'=>(int)($receipt['total_minor']??$bill['total_minor']),
                'new_total_minor'=>$total,
                'previous_payment_method'=>$receipt['payment_method']??$bill['payment_method'],
                'payment_method'=>$v['payment_method'],
                'discount_display_type'=>$displayType,
                'discount_value'=>$discountValue,
            ];
            $receipt=[...$receipt,
                'subtotal_minor'=>$subtotal,'item_discount_minor'=>$itemDiscount,'bill_discount_minor'=>$billDiscount,'discount_minor'=>$discount,'tax_minor'=>$tax,
                'additional_amount_minor'=>$additionalAmount,'additional_charges'=>$additionalCharges,'total_minor'=>$total,'tax_basis_points'=>$taxRate,
                'discount_basis_points'=>(int)$v['discount_basis_points'],'discount_type'=>$discountType,'discount_display_type'=>$displayType,'discount_value'=>$discountValue,
                'settlement_remark'=>trim((string)$v['settlement_remark']),'payment_method'=>$v['payment_method'],'payments'=>$payments,'split_amounts'=>$parts,
                'bank_account_name'=>$bank['account_name']??null,'qr_bank_account_id'=>$qrBank['id']??null,'qr_bank_account_name'=>$qrBank['account_name']??null,
                'qr_upi_id'=>$qrBank['account_number']??null,'qr_image_base64'=>$qrBank['qr_image_base64']??null,
                'settlement_edits'=>$audit,'last_settlement_edited_at'=>now('Asia/Kolkata')->toIso8601String(),'last_settlement_edited_by'=>$cashier,
            ];
            DB::table('bills')->where('id',$billId)->where('user_id',$tenant)->update([
                'subtotal_minor'=>$subtotal,'item_discount_minor'=>$itemDiscount,'bill_discount_minor'=>$billDiscount,'additional_amount_minor'=>$additionalAmount,
                'discount_minor'=>$discount,'tax_minor'=>$tax,'total_minor'=>$total,
                'tax_basis_points'=>$taxRate,'discount_basis_points'=>(int)$v['discount_basis_points'],'payment_method'=>$v['payment_method'],
                'bank_account_id'=>$v['bank_account_id']??null,'payments'=>json_encode($payments),'split_amounts'=>json_encode($parts),'receipt'=>json_encode($receipt),
                'version'=>(int)$bill['version']+1,'updated_at'=>now(),
            ]);
            Records::emit('bills',$tenant,$billId);
            return Records::get('bills',$tenant,$billId);
        });
    }
}
