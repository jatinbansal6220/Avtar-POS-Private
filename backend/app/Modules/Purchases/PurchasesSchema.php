<?php
namespace App\Modules\Purchases;
use Illuminate\Database\Schema\Blueprint;
final class PurchasesSchema {
    public static function columns(Blueprint $t): void {
        $t->string('item_name',160); $t->string('category',80); $t->string('supplier_name',160);
                        $t->decimal('quantity',12,3); $t->string('unit',20); $t->unsignedBigInteger('unit_price_minor');
                        $t->unsignedBigInteger('total_minor'); $t->date('purchase_date'); $t->string('payment_mode');
                        $t->uuid('bank_account_id')->nullable(); $t->string('invoice_number',80)->nullable();
                        $t->text('notes')->nullable(); $t->index(['user_id','purchase_date']);
    }
}
