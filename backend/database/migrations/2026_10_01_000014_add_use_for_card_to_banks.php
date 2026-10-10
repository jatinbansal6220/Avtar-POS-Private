<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void {
        if (Schema::hasColumn('banks', 'use_for_card')) return;
        Schema::table('banks', function (Blueprint $table): void {
            // Keep all legacy dedicated Card accounts available while giving
            // UPI accounts an explicit owner-controlled Card switch.
            $table->boolean('use_for_card')->default(false)->after('is_default');
        });
        DB::table('banks')->whereIn('account_type', ['card','current','savings','cash_drawer'])
            ->update(['use_for_card'=>true]);
    }

    public function down(): void {
        if (Schema::hasColumn('banks', 'use_for_card')) {
            Schema::table('banks', function (Blueprint $table): void {
                $table->dropColumn('use_for_card');
            });
        }
    }
};
