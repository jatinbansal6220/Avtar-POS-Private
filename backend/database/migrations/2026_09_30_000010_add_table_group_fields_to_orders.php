<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void {
        Schema::table('orders', function (Blueprint $table): void {
            if (!Schema::hasColumn('orders', 'merged_table_ids')) {
                $table->json('merged_table_ids')->nullable()->after('table_number');
            }
            if (!Schema::hasColumn('orders', 'merged_table_numbers')) {
                $table->json('merged_table_numbers')->nullable()->after('merged_table_ids');
            }
            if (!Schema::hasColumn('orders', 'merged_order_ids')) {
                $table->json('merged_order_ids')->nullable()->after('merged_table_numbers');
            }
            if (!Schema::hasColumn('orders', 'merged_into_order_id')) {
                $table->uuid('merged_into_order_id')->nullable()->index()->after('merged_order_ids');
            }
        });
        Schema::table('order_items', function (Blueprint $table): void {
            if (!Schema::hasColumn('order_items', 'source_table_number')) {
                $table->string('source_table_number', 40)->nullable()->after('item_name');
            }
        });
    }

    public function down(): void {
        Schema::table('order_items', function (Blueprint $table): void {
            if (Schema::hasColumn('order_items', 'source_table_number')) {
                $table->dropColumn('source_table_number');
            }
        });
        Schema::table('orders', function (Blueprint $table): void {
            if (Schema::hasColumn('orders', 'merged_into_order_id')) {
                $table->dropIndex(['merged_into_order_id']);
                $table->dropColumn('merged_into_order_id');
            }
            $columns = array_filter(
                ['merged_table_ids', 'merged_table_numbers', 'merged_order_ids'],
                fn (string $column): bool => Schema::hasColumn('orders', $column),
            );
            if ($columns) $table->dropColumn($columns);
        });
    }
};
