<?php
namespace App\Modules\Tables;
use Illuminate\Validation\Rule;
final class TablesRules {
    public static function forTenant(int $tenant): array {
        $money='required|integer|min:0|max:100000000'; $text='required|string|max:160'; $optional='nullable|string|max:2000';
        $ref=fn($table)=>['nullable','uuid',Rule::exists($table,'id')->where('user_id',$tenant)->whereNull('deleted_at')];
        return ['table_number'=>'required|string|max:40','section'=>'required|string|max:80','capacity'=>'required|integer|min:1|max:100'];
    }
}
