<?php
namespace App\Modules\Combos;
use Illuminate\Validation\Rule;
final class CombosRules {
    public static function forTenant(int $tenant): array {
        $money='required|integer|min:0|max:100000000'; $text='required|string|max:160'; $optional='nullable|string|max:2000';
        $ref=fn($table)=>['nullable','uuid',Rule::exists($table,'id')->where('user_id',$tenant)->whereNull('deleted_at')];
        return ['name'=>$text,'price_minor'=>$money,'is_active'=>'required|boolean','description'=>$optional,'items'=>'required|array|min:1|max:100','items.*.menu_item_id'=>['required','uuid','distinct',Rule::exists('menu_items','id')->where('user_id',$tenant)->whereNull('deleted_at')],'items.*.quantity'=>'required|integer|min:1|max:100'];
    }
}
