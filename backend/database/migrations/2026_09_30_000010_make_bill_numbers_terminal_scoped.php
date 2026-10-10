<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    /**
     * A daily bill sequence belongs to one installation, not the whole
     * restaurant. Desktop and APK can both legitimately produce BILL-...-001
     * while one device is offline. Keeping the terminal in the unique key
     * protects a retry from duplicating that terminal's invoice without
     * rejecting the other terminal's real sale.
     */
    public function up(): void {
        $indexes = collect(DB::select('SHOW INDEX FROM bills'))
            ->groupBy('Key_name')
            ->map(fn ($columns) => $columns
                ->sortBy('Seq_in_index')
                ->map(fn ($column) => $column->Column_name)
                ->values()
                ->all());
        $oldIndexName = $indexes->search(
            fn (array $columns, string $name) =>
                $name !== 'PRIMARY' && $columns === ['user_id', 'bill_number'],
        );
        $newIndexExists = $indexes->contains(
            fn (array $columns) =>
                $columns === ['user_id', 'source_terminal_id', 'bill_number'],
        );
        if ($oldIndexName !== false) {
            Schema::table('bills', fn (Blueprint $table) => $table->dropIndex($oldIndexName));
        }
        if (!$newIndexExists) {
            Schema::table('bills', fn (Blueprint $table) => $table->unique(
                ['user_id', 'source_terminal_id', 'bill_number'],
                'bills_user_terminal_bill_unique',
            ));
        }
    }

    public function down(): void {
        Schema::table('bills', function (Blueprint $table) {
            $table->dropUnique('bills_user_terminal_bill_unique');
            $table->unique(['user_id', 'bill_number']);
        });
    }
};
