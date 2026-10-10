<?php
namespace App\Modules\Settings;
use Illuminate\Validation\Rule;
final class SettingsRules {
    public static function forTenant(int $tenant): array {
        $money='required|integer|min:0|max:100000000'; $text='required|string|max:160'; $optional='nullable|string|max:2000';
        $ref=fn($table)=>['nullable','uuid',Rule::exists($table,'id')->where('user_id',$tenant)->whereNull('deleted_at')];
        return ['restaurant_name'=>$text,'restaurant_address'=>$optional,'restaurant_phone'=>'nullable|string|max:30','tagline'=>'nullable|string|max:160','gstin'=>'nullable|string|max:30','fssai_lic'=>'nullable|string|max:30','printer_ip'=>'nullable|ip','printer_port'=>'required|integer|min:1|max:65535','printer_paper_width'=>'required|in:58mm,80mm','is_tax_enabled'=>'required|boolean','tax_basis_points'=>'required|integer|min:0|max:10000','default_discount_basis_points'=>'required|integer|min:0|max:10000','timezone'=>'required|timezone','online_platforms'=>'nullable|array|max:50','online_platforms.*'=>'string|max:100'];
    }
}
