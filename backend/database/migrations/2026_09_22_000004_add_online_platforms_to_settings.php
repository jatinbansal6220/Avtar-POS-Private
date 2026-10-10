<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void {
        if (Schema::hasColumn('settings', 'online_platforms')) {
            return;
        }

        Schema::table('settings', function (Blueprint $table) {
            $table->json('online_platforms')->nullable()->after('timezone');
        });
    }

    public function down(): void {
        if (!Schema::hasColumn('settings', 'online_platforms')) {
            return;
        }

        Schema::table('settings', function (Blueprint $table) {
            $table->dropColumn('online_platforms');
        });
    }
};
