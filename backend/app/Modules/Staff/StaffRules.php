<?php
namespace App\Modules\Staff;
use Illuminate\Validation\Rule;
final class StaffRules {
    public static function forTenant(int $tenant): array {
        $money='required|integer|min:0|max:100000000'; $text='required|string|max:160'; $optional='nullable|string|max:2000';
        $ref=fn($table)=>['nullable','uuid',Rule::exists($table,'id')->where('user_id',$tenant)->whereNull('deleted_at')];
        return ['name'=>$text,'phone'=>'required|string|max:30','role'=>'required|in:manager,waiter,chef,cashier,cleaner','joining_date'=>'required|date_format:Y-m-d','monthly_salary_minor'=>$money,'is_active'=>'required|boolean'];
    }
}
