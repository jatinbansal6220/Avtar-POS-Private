<?php
namespace App\Modules\Banks;
use Illuminate\Validation\Rule;
final class BanksRules {
    public static function forTenant(int $tenant): array {
        $money='required|integer|min:0|max:100000000'; $text='required|string|max:160'; $optional='nullable|string|max:2000';
        $ref=fn($table)=>['nullable','uuid',Rule::exists($table,'id')->where('user_id',$tenant)->whereNull('deleted_at')];
        return ['account_name'=>$text,'bank_name'=>$text,'account_type'=>'required|in:upi,card,current,savings,cash_drawer,upi_merchant','account_number'=>'nullable|string|max:40','ifsc_code'=>'nullable|string|max:20','qr_image_base64'=>'nullable|string|max:200000','initial_balance_minor'=>'required|integer|min:-100000000|max:100000000','is_default'=>'sometimes|boolean','use_for_card'=>'required|boolean','is_default_qr'=>'sometimes|boolean','is_active'=>'required|boolean'];
    }
}
