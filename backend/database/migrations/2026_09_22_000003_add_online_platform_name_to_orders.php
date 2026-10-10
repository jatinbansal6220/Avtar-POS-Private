<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void {
        if (Schema::hasColumn('orders', 'online_platform_name')) {
            return;
        }

        Schema::table('orders', function (Blueprint $table) {
            $table->string('online_platform_name', 100)->nullable()->after('online_platform');
        });
    }

    public function down(): void {
        if (!Schema::hasColumn('orders', 'online_platform_name')) {
            return;
        }

        Schema::table('orders', function (Blueprint $table) {
            $table->dropColumn('online_platform_name');
        });
    }
};
