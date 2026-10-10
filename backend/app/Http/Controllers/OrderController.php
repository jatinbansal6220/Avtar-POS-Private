<?php
namespace App\Http\Controllers;
use App\Services\OrderService;
use App\Services\Records;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;

final class OrderController {
    public function save(Request $r,OrderService $service,?string $id=null) {
        $v=$r->validate(['id'=>'sometimes|uuid','version'=>$id?'required|integer|min:1':'sometimes|integer',
            'table_id'=>'nullable|uuid','order_type'=>'required|in:dine_in,takeaway,online,pos','online_platform'=>'nullable|in:swiggy,zomato,direct,other','online_platform_name'=>'nullable|string|max:100',
            'customer_name'=>'nullable|string|max:160','customer_phone'=>'nullable|string|max:30','notes'=>'nullable|string|max:2000','voids'=>'sometimes|array|max:200',
            'voids.*.item_name'=>'required|string|max:160','voids.*.quantity'=>'required|integer|min:1|max:999','voids.*.price_minor'=>'required|integer|min:0',
            'voids.*.reason'=>'required|string|max:500','voids.*.voided_at'=>'required|date','voids.*.actor'=>'required|string|max:160',
            'items'=>'required|array|max:200','items.*.menu_item_id'=>'nullable|uuid','items.*.combo_id'=>'nullable|uuid',
            'items.*.quantity'=>'required|integer|min:1|max:999','items.*.notes'=>'nullable|string|max:500','items.*.source_table_number'=>'nullable|string|max:40',
            'items.*.discount_type'=>'nullable|in:percent,fixed','items.*.discount_value'=>'nullable|integer|min:0']);
        return response()->json($service->save($r->user()->tenantId(),$v,$id),$id?200:201);
    }
    public function bill(Request $r,\App\Services\BillingService $service) {
        abort_unless(in_array($r->user()->role,['owner','manager','cashier']),403,'Cashier access required.');
        $v=$r->validate(['order_id'=>'required|uuid','version'=>'required|integer|min:1','discount_basis_points'=>'required|integer|min:0|max:10000',
            // Optional only for backward compatibility with an already
            // installed terminal. New builds always send this complete set.
            'client_bill_number'=>['nullable','string','max:50','regex:/^BILL-\d{8}-\d{3,}$/'],
            'client_generated_at'=>'nullable|date','source_terminal_id'=>'nullable|uuid','source_terminal_label'=>'nullable|string|max:80',
            'discount_type'=>'nullable|in:percent,fixed,minus,charges_not_applicable','discount_display_type'=>'nullable|in:percent,fixed,minus,charges_not_applicable','discount_value'=>'nullable|integer|min:0',
            'settlement_remark'=>'nullable|string|max:500',
            'payment_schema_version'=>'nullable|integer|min:1|max:2',
            'payment_method'=>'required|in:cash,upi,online,card,mixed,complimentary','bank_account_id'=>'nullable|uuid','qr_bank_account_id'=>'nullable|uuid',
            'payments'=>'nullable|array|min:1|max:3','payments.*.method'=>'required|in:cash,upi,online,card,complimentary','payments.*.amount_minor'=>'required|integer|min:0',
            'additional_charges'=>'nullable|array|max:20','additional_charges.*.amount_minor'=>'required|integer|min:1|max:100000000','additional_charges.*.note'=>'nullable|string|max:500',
            'split_amounts'=>'nullable|array|max:50','split_amounts.*'=>'integer|min:1']);
        return response()->json($service->bill($r->user()->tenantId(),$v,$r->user()->name),201);
    }
    public function settleBill(Request $r,string $id,\App\Services\BillingService $service) {
        Records::requireManager();
        $v=$r->validate(['version'=>'required|integer|min:1','invoice_access_code_hash'=>['required','regex:/^[a-f0-9]{64}$/i'],'discount_basis_points'=>'required|integer|min:0|max:10000',
            'discount_type'=>'nullable|in:percent,fixed,minus,charges_not_applicable','discount_display_type'=>'nullable|in:percent,fixed,minus,charges_not_applicable','discount_value'=>'nullable|integer|min:0',
            'payment_schema_version'=>'nullable|integer|min:1|max:2',
            'settlement_remark'=>'required|string|max:500','payment_method'=>'required|in:cash,upi,online,card,mixed,complimentary','bank_account_id'=>'nullable|uuid','qr_bank_account_id'=>'nullable|uuid',
            'payments'=>'nullable|array|min:1|max:3','payments.*.method'=>'required|in:cash,upi,online,card,complimentary','payments.*.amount_minor'=>'required|integer|min:0',
            'additional_charges'=>'nullable|array|max:20','additional_charges.*.amount_minor'=>'required|integer|min:1|max:100000000','additional_charges.*.note'=>'nullable|string|max:500',
              'split_amounts'=>'nullable|array|max:50','split_amounts.*'=>'integer|min:1']);
          $settings=Records::query('settings',$r->user()->tenantId())->first();
          $configured=(string)($settings->invoice_delete_code_hash ?? '');
          abort_if($configured==='',422,'Set an invoice deletion/edit code before editing an invoice.');
          abort_unless(hash_equals($configured,strtolower($v['invoice_access_code_hash'])),403,'Invoice deletion/edit code is incorrect.');
          return response()->json($service->settle($r->user()->tenantId(),$id,$v,$r->user()->name));
    }
    public function status(Request $r,string $id) {
        $v=$r->validate(['version'=>'required|integer|min:1','action'=>'required|in:bill_pending,cancel']); $tenant=$r->user()->tenantId();
        $order=Records::get('orders',$tenant,$id); abort_unless($order['status']==='open' && $order['version']==$v['version'],409,'Order changed or closed.');
        if ($v['action']==='cancel') Records::requireManager();
        $tableIds=$order['merged_table_ids']??[$order['table_id']];
        if (is_string($tableIds)) $tableIds=json_decode($tableIds,true)?:[$order['table_id']];
        abort_if($v['action']==='cancel' && count($tableIds)>1,422,'Separate joined tables before cancelling an order.');
        DB::table('orders')->where('id',$id)->update(['status'=>$v['action']==='cancel'?'cancelled':'open','version'=>$order['version']+1,'updated_at'=>now()]);
        foreach($tableIds as $tableId) {
            DB::table('tables')->where('id',$tableId)->update(['status'=>$v['action']==='cancel'?'empty':'bill_pending',
                'current_order_id'=>$v['action']==='cancel'?null:$id,'version'=>DB::raw('version + 1'),'updated_at'=>now()]);
            Records::emit('tables',$tenant,$tableId);
        }
        Records::emit('orders',$tenant,$id); return response()->json(Records::get('orders',$tenant,$id));
    }
    public function transfer(Request $r,string $id,\App\Services\TableGroupService $service) {
        Records::requireManager();
        $v=$r->validate(['version'=>'required|integer|min:1','target_table_id'=>'required|uuid']);
        return response()->json($service->transfer($r->user()->tenantId(),$id,$v));
    }
    public function merge(Request $r,string $id,\App\Services\TableGroupService $service) {
        Records::requireManager();
        $v=$r->validate(['version'=>'required|integer|min:1','target_table_id'=>'required|uuid']);
        return response()->json($service->merge($r->user()->tenantId(),$id,$v));
    }
    public function unmerge(Request $r,string $id,\App\Services\TableGroupService $service) {
        Records::requireManager();
        $v=$r->validate(['version'=>'required|integer|min:1']);
        return response()->json($service->unmerge($r->user()->tenantId(),$id,$v));
    }
}
