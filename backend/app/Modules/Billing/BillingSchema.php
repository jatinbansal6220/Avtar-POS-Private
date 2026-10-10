<?php
namespace App\Modules\Billing;
use Illuminate\Database\Schema\Blueprint;
final class BillingSchema {
    public static function columns(Blueprint $t): void {
        $t->foreignUuid('order_id')->unique()->constrained('orders')->restrictOnDelete();
                        $t->string('bill_number'); $t->uuid('table_id')->nullable(); $t->string('table_number',40);
                        $t->unsignedBigInteger('subtotal_minor'); $t->unsignedBigInteger('discount_minor');
                        $t->unsignedBigInteger('tax_minor'); $t->unsignedBigInteger('total_minor');
                        $t->unsignedInteger('tax_basis_points'); $t->unsignedInteger('discount_basis_points');
                        $t->string('payment_method'); $t->uuid('bank_account_id')->nullable();
        // MariaDB 10.4 rejects a later non-null TIMESTAMP here when Laravel's
        // timestamps() columns already exist. A DATETIME preserves the same
        // application value without MySQL/MariaDB TIMESTAMP default semantics.
        $t->json('receipt'); $t->dateTime('generated_at');
                        $t->unique(['user_id','bill_number']); $t->index(['user_id','generated_at','id']);
    }
}
