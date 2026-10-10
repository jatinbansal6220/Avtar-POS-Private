<?php
namespace App\Http\Controllers;

use App\Services\Records;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Validation\Rule;

final class PurchaseLedgerController {
    private function rows(string $resource,int $tenant): array {
        return Records::query($resource,$tenant)->get()->map(fn($r)=>Records::decode($resource,$r))->all();
    }
    private function rounded(int $n,int $d): int { return intdiv($n+intdiv($d,2),$d); }
    private function stock(string $item,string $unit,array $bills,array $events,string $date): int {
        $days=[];
        foreach($bills as $bill) if($bill['status']==='received') foreach($bill['lines'] as $line) {
            if($line['purchase_item_id']===$item && $line['unit']===$unit) $days[$bill['purchase_date']]=($days[$bill['purchase_date']]??0)+$line['quantity_milli'];
        }
        foreach($events as $event) foreach($event['lines']??[] as $line) {
            if($line['purchase_item_id']===$item && $line['unit']===$unit) $days[$event['date']]=($days[$event['date']]??0)+($event['kind']==='opening'?1:-1)*$line['quantity_milli'];
        }
        $days[$date]??=0; ksort($days); $balance=0; $minimum=null;
        foreach($days as $day=>$delta) { $balance+=$delta; if($day>=$date) $minimum=$minimum===null?$balance:min($minimum,$balance); }
        return $minimum??0;
    }
    public function save(Request $r,string $resource,?string $id=null) {
        Records::requireManager();
        $tenant=$r->user()->tenantId();
        $ref=fn($table)=>['required','uuid',Rule::exists($table,'id')->where('user_id',$tenant)->whereNull('deleted_at')];
        $money='required|integer|min:0|max:100000000';
        $rules=match($resource) {
            'purchase_suppliers'=>['name'=>'required|string|max:160','phone'=>'nullable|string|max:30','gstin'=>['nullable','regex:/^\d{2}[A-Z]{5}\d{4}[A-Z][A-Z0-9]Z[A-Z0-9]$/'],'address'=>'nullable|string|max:500','note'=>'nullable|string|max:2000','is_active'=>'required|boolean'],
            'purchase_bills'=>[
                'name'=>'required|string|max:160','supplier_id'=>$ref('purchase_suppliers'),'supplier_name'=>'required|string|max:160',
                'purchase_date'=>'required|date_format:Y-m-d','due_date'=>'nullable|date_format:Y-m-d|after_or_equal:purchase_date',
                'invoice_number'=>'nullable|string|max:80','status'=>'required|in:draft,ordered,received,cancelled',
                'freight_minor'=>$money,'paid_minor'=>$money,'payment_mode'=>'required|in:cash,upi,bank_transfer,credit',
                'bank_account_id'=>['nullable','uuid',Rule::exists('banks','id')->where('user_id',$tenant)->whereNull('deleted_at')],
                'note'=>'nullable|string|max:2000','lines'=>'required|array|min:1|max:100','lines.*.id'=>'required|uuid|distinct',
                'lines.*.purchase_item_id'=>$ref('purchase_items'),'lines.*.item_name'=>'required|string|max:160',
                'lines.*.unit'=>'required|string|max:20','lines.*.quantity_milli'=>'required|integer|min:1|max:100000000',
                'lines.*.unit_price_minor'=>$money,'lines.*.discount_minor'=>$money,'lines.*.tax_basis_points'=>'required|integer|min:0|max:2800',
            ],
            'purchase_events'=>[
                'name'=>'required|string|max:160','kind'=>'required|in:payment,refund,return,opening,usage,waste',
                'bill_id'=>['nullable','uuid',Rule::exists('purchase_bills','id')->where('user_id',$tenant)->whereNull('deleted_at')],
                'date'=>'required|date_format:Y-m-d','amount_minor'=>$money,'payment_mode'=>'nullable|in:cash,upi,bank_transfer',
                'bank_account_id'=>['nullable','uuid',Rule::exists('banks','id')->where('user_id',$tenant)->whereNull('deleted_at')],
                'note'=>'nullable|string|max:2000','lines'=>'present|array|max:100',
                'lines.*.purchase_item_id'=>$ref('purchase_items'),'lines.*.item_name'=>'required|string|max:160',
                'lines.*.line_id'=>'nullable|uuid','lines.*.unit'=>'required|string|max:20','lines.*.quantity_milli'=>'required|integer|min:1|max:100000000',
            ],
            default=>abort(404),
        };
        $v=$r->validate($rules+['id'=>'required|uuid','version'=>$id?'required|integer|min:1':'sometimes|integer']);
        $old=$id?Records::get($resource,$tenant,$id):null;
        if($old) abort_unless($old['version']===$v['version'],409,'This record changed on another device. Reload first.');
        $id??=$v['id'];
        abort_unless($id===$v['id'],422,'Record ID does not match.');
        if(!$old) abort_if(DB::table($resource)->where('id',$id)->exists(),409,'This record already exists.');
        if($resource==='purchase_suppliers') {
            abort_if(Records::query($resource,$tenant)->whereRaw('LOWER(name)=?',[mb_strtolower(trim($v['name']))])->where('id','!=',$id)->exists(),422,'Supplier already exists.');
        }
        $bills=$this->rows('purchase_bills',$tenant); $events=$this->rows('purchase_events',$tenant);
        if($resource==='purchase_bills') {
            abort_if($old && in_array($old['status'],['received','cancelled']),409,'Posted or cancelled purchases cannot be edited. Record a return instead.');
            abort_if($old && $old['status']==='ordered' && $v['status']==='draft',422,'An ordered purchase cannot return to draft.');
            $v['supplier_name']=Records::get('purchase_suppliers',$tenant,$v['supplier_id'])['name'];
            $subtotal=$discount=$tax=0; $seen=[];
            foreach($v['lines'] as &$line) {
                $item=Records::get('purchase_items',$tenant,$line['purchase_item_id']);
                $line['item_name']=$item['name']; $key=$line['purchase_item_id'].'|'.$line['unit'];
                abort_if(isset($seen[$key]),422,'Combine repeated items in the same unit.'); $seen[$key]=true;
                $gross=$this->rounded($line['quantity_milli']*$line['unit_price_minor'],1000);
                abort_if($line['discount_minor']>$gross,422,'Item discount exceeds its amount.');
                $gst=$this->rounded(($gross-$line['discount_minor'])*$line['tax_basis_points'],10000);
                $line=array_replace($line,['subtotal_minor'=>$gross,'tax_minor'=>$gst,'total_minor'=>$gross-$line['discount_minor']+$gst]);
                $subtotal+=$gross; $discount+=$line['discount_minor']; $tax+=$gst;
            } unset($line);
            $v+=['subtotal_minor'=>$subtotal,'discount_minor'=>$discount,'tax_minor'=>$tax,'total_minor'=>$subtotal-$discount+$tax+$v['freight_minor']];
            abort_if($v['total_minor']>100000000 || $v['paid_minor']>$v['total_minor'],422,'Check purchase total and paid amount.');
            abort_if(($v['status']!=='received' || $v['payment_mode']==='credit') && $v['paid_minor']!==0,422,'Only a received purchase may have an initial payment.');
            if(!empty($v['invoice_number']) && $v['status']!=='cancelled') foreach($bills as $bill) {
                abort_if($bill['id']!==$id && $bill['status']!=='cancelled' && $bill['supplier_id']===$v['supplier_id'] && mb_strtolower(trim($bill['invoice_number']??''))===mb_strtolower(trim($v['invoice_number'])),422,'This supplier invoice is already recorded.');
            }
        }
        if($resource==='purchase_events') {
            abort_if($old,405,'Ledger actions are immutable.');
            $kind=$v['kind']; $bill=null;
            if(in_array($kind,['payment','refund','return'])) {
                abort_unless(!empty($v['bill_id']),422,'Choose a purchase bill.');
                $bill=Records::get('purchase_bills',$tenant,$v['bill_id']);
                abort_unless($bill['status']==='received',422,'Receive the purchase first.');
                abort_if($v['date']<$bill['purchase_date'],422,'Action date cannot be before the purchase date.');
            } else $v['bill_id']=null;
            if(in_array($kind,['payment','refund'])) {
                $balance=$bill['total_minor']-$bill['paid_minor'];
                foreach($events as $event) if(($event['bill_id']??null)===$bill['id']) {
                    $balance+=match($event['kind']) {'payment','return'=>-$event['amount_minor'],'refund'=>$event['amount_minor'],default=>0};
                }
                $available=$kind==='payment'?max(0,$balance):max(0,-$balance);
                abort_if($v['amount_minor']<=0 || $v['amount_minor']>$available || empty($v['payment_mode']),422,'Payment/refund exceeds the available balance.');
                $v['lines']=[];
            } else {
                abort_if(empty($v['lines']) || trim($v['note']??'')==='',422,'Enter stock quantities and a reason.');
                $credit=0; $seen=[];
                foreach($v['lines'] as &$line) {
                    if($kind==='return') {
                        $original=collect($bill['lines'])->firstWhere('id',$line['line_id']??null);
                        abort_unless($original,422,'Original purchase line was not found.');
                        $line['purchase_item_id']=$original['purchase_item_id']; $line['item_name']=$original['item_name']; $line['unit']=$original['unit'];
                        $prior=0;
                        foreach($events as $event) if($event['kind']==='return' && $event['bill_id']===$bill['id']) foreach($event['lines'] as $returned) {
                            if($returned['line_id']===$line['line_id']) $prior+=$returned['quantity_milli'];
                        }
                        abort_if($prior+$line['quantity_milli']>$original['quantity_milli'],422,'Return exceeds purchased quantity.');
                        $credit+=$this->rounded(($prior+$line['quantity_milli'])*$original['total_minor'],$original['quantity_milli'])-$this->rounded($prior*$original['total_minor'],$original['quantity_milli']);
                    }
                    $key=$line['purchase_item_id'].'|'.$line['unit'];
                    abort_if(isset($seen[$key]),422,'Combine repeated items.'); $seen[$key]=true;
                    abort_if($kind!=='opening' && $line['quantity_milli']>$this->stock($line['purchase_item_id'],$line['unit'],$bills,$events,$v['date']),422,'Not enough material stock on this or a later ledger date.');
                } unset($line);
                $v['amount_minor']=$credit;
            }
        }
        unset($v['version']);
        $row=['name'=>$v['name'],'status'=>$v['status']??null,'data'=>json_encode($v),'updated_at'=>now()];
        if($old) DB::table($resource)->where('id',$id)->where('user_id',$tenant)->update($row+['version'=>$old['version']+1]);
        else DB::table($resource)->insert($row+['id'=>$id,'user_id'=>$tenant,'created_at'=>now()]);
        Records::emit($resource,$tenant,$id);
        return response()->json(Records::get($resource,$tenant,$id),$old?200:201);
    }
}
