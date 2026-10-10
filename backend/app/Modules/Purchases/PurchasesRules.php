<?php
namespace App\Modules\Purchases;
use Illuminate\Validation\Rule;
final class PurchasesRules {
    public static function forTenant(int $tenant): array {
        $money='required|integer|min:0|max:100000000'; $text='required|string|max:160'; $optional='nullable|string|max:2000';
        $ref=fn($table)=>['nullable','uuid',Rule::exists($table,'id')->where('user_id',$tenant)->whereNull('deleted_at')];
        return ['item_name'=>$text,'purchase_item_id'=>$ref('purchase_items'),'category'=>'required|string|max:80','supplier_name'=>$text,'quantity'=>'required|numeric|min:0.001|max:100000','unit'=>'required|string|max:20','unit_price_minor'=>$money,'purchase_date'=>'required|date_format:Y-m-d','payment_mode'=>'required|in:cash,bank_transfer,upi,credit','bank_account_id'=>$ref('banks'),'invoice_number'=>'nullable|string|max:80','notes'=>$optional];
    }
}
