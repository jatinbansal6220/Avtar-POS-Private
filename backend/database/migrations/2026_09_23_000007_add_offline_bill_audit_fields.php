<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void {
        Schema::table('orders', function (Blueprint $table) {
            $table->json('voids')->nullable()->after('notes');
        });
        Schema::table('order_items', function (Blueprint $table) {
            $table->string('discount_type', 10)->default('percent')->after('notes');
            $table->unsignedInteger('discount_value')->default(0)->after('discount_type');
        });
        Schema::table('bills', function (Blueprint $table) {
            $table->unsignedBigInteger('item_discount_minor')->default(0)->after('subtotal_minor');
            $table->unsignedBigInteger('bill_discount_minor')->default(0)->after('item_discount_minor');
            $table->json('payments')->nullable()->after('payment_method');
            $table->json('split_amounts')->nullable()->after('payments');
        });
    }

    public function down(): void {
        Schema::table('bills', function (Blueprint $table) {
            $table->dropColumn(['item_discount_minor', 'bill_discount_minor', 'payments', 'split_amounts']);
        });
        Schema::table('order_items', function (Blueprint $table) {
            $table->dropColumn(['discount_type', 'discount_value']);
        });
        Schema::table('orders', function (Blueprint $table) {
            $table->dropColumn('voids');
        });
    }
};
