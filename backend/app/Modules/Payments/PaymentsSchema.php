<?php
namespace App\Modules\Payments;
use Illuminate\Database\Schema\Blueprint;
final class PaymentsSchema {
    public static function columns(Blueprint $t): void {
        $t->foreignUuid('staff_id')->constrained('staff')->restrictOnDelete();
                        $t->unsignedBigInteger('amount_minor'); $t->date('date'); $t->text('note')->nullable();
                        $t->string('payment_mode'); $t->uuid('bank_account_id')->nullable();
                        $t->index(['user_id','staff_id','date']);
    }
}
