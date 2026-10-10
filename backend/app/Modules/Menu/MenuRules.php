<?php
namespace App\Modules\Menu;
use Illuminate\Validation\Rule;
final class MenuRules {
    public static function forTenant(int $tenant): array {
        $money='required|integer|min:0|max:100000000'; $text='required|string|max:160'; $optional='nullable|string|max:2000';
        $ref=fn($table)=>['nullable','uuid',Rule::exists($table,'id')->where('user_id',$tenant)->whereNull('deleted_at')];
        return ['name'=>$text,'price_minor'=>$money,'category'=>'required|string|max:80','is_active'=>'required|boolean','is_veg'=>'required|boolean','short_code'=>'nullable|string|max:30','description'=>$optional,'image_url'=>'nullable|url:https|max:1000'];
    }
}
