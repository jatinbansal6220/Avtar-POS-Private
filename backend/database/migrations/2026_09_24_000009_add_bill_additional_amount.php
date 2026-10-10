<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void {
        Schema::table('bills', function (Blueprint $table) {
            $table->unsignedBigInteger('additional_amount_minor')->default(0)->after('bill_discount_minor');
        });
    }

    public function down(): void {
        Schema::table('bills', function (Blueprint $table) {
            $table->dropColumn('additional_amount_minor');
        });
    }
};
