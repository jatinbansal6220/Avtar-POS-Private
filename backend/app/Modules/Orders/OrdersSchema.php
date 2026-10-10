<?php
namespace App\Modules\Orders;
use Illuminate\Database\Schema\Blueprint;
final class OrdersSchema {
    public static function columns(Blueprint $t): void {
        $t->foreignUuid('table_id')->nullable()->constrained('tables')->restrictOnDelete();
                        $t->string('table_number',40); $t->string('status')->default('open');
                        $t->string('order_type')->default('dine_in'); $t->string('online_platform')->nullable(); $t->string('online_platform_name',100)->nullable();
                        $t->string('customer_name',160)->nullable(); $t->string('customer_phone',30)->nullable();
                        $t->text('notes')->nullable(); $t->unsignedBigInteger('subtotal_minor')->default(0);
                        $t->index(['user_id','status','id']); $t->index(['user_id','created_at']);
    }
}
