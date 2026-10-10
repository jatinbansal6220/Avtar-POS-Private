<?php
namespace App\Modules\Staff;
use Illuminate\Database\Schema\Blueprint;
final class StaffSchema {
    public static function columns(Blueprint $t): void {
        $t->string('name',160); $t->string('phone',30); $t->string('role',30);
                        $t->date('joining_date'); $t->unsignedBigInteger('monthly_salary_minor');
                        $t->boolean('is_active')->default(true);
    }
}
