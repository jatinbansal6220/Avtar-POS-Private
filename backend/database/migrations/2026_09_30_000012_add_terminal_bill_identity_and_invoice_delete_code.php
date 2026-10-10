<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void {
        Schema::table('settings', function (Blueprint $table): void {
            // This is a SHA-256 verification value, never the owner's actual
            // deletion code. It can be synced to an authenticated terminal so
            // the UI can reject a wrong code before a destructive request.
            if (!Schema::hasColumn('settings', 'invoice_delete_code_hash')) {
                $table->string('invoice_delete_code_hash', 64)->nullable()->after('online_platforms');
            }
        });

        Schema::table('bills', function (Blueprint $table): void {
            // A terminal continues its own daily counter while offline. The
            // pair (terminal, local bill number) is unique even when a phone
            // and a desktop both create BILL-YYYYMMDD-001 without a network.
            if (!Schema::hasColumn('bills', 'source_terminal_id')) {
                $table->uuid('source_terminal_id')->nullable()->after('bill_number');
            }
            if (!Schema::hasColumn('bills', 'source_terminal_label')) {
                $table->string('source_terminal_label', 80)->nullable()->after('source_terminal_id');
            }
        });

        Schema::table('bills', function (Blueprint $table): void {
            $table->dropUnique(['user_id', 'bill_number']);
            $table->unique(
                ['user_id', 'source_terminal_id', 'bill_number'],
                'bills_user_terminal_bill_unique',
            );
        });
    }

    public function down(): void {
        Schema::table('bills', function (Blueprint $table): void {
            $table->dropUnique('bills_user_terminal_bill_unique');
            $table->unique(['user_id', 'bill_number']);
            $table->dropColumn(['source_terminal_id', 'source_terminal_label']);
        });
        Schema::table('settings', function (Blueprint $table): void {
            $table->dropColumn('invoice_delete_code_hash');
        });
    }
};
