<?php
namespace App\Modules\Attendance;
use Illuminate\Database\Schema\Blueprint;
final class AttendanceSchema {
    public static function columns(Blueprint $t): void {
        $t->foreignUuid('staff_id')->constrained('staff')->restrictOnDelete();
                        $t->date('date'); $t->string('status'); $t->text('notes')->nullable();
                        $t->unique(['staff_id','date']); $t->index(['user_id','date']);
    }
}
