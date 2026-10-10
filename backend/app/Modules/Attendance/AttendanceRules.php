<?php
namespace App\Modules\Attendance;
use Illuminate\Validation\Rule;
final class AttendanceRules {
    public static function forTenant(int $tenant): array {
        $money='required|integer|min:0|max:100000000'; $text='required|string|max:160'; $optional='nullable|string|max:2000';
        $ref=fn($table)=>['nullable','uuid',Rule::exists($table,'id')->where('user_id',$tenant)->whereNull('deleted_at')];
        return ['staff_id'=>['required',...array_slice($ref('staff'),1)],'date'=>'required|date_format:Y-m-d','status'=>'required|in:present,absent,half_day,leave','notes'=>$optional];
    }
}
