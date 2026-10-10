<?php
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void {
        foreach (['purchase_suppliers','purchase_bills','purchase_events'] as $table) {
            Schema::create($table, function (Blueprint $t) {
                $t->uuid('id')->primary();
                $t->foreignId('user_id')->constrained('users')->restrictOnDelete();
                $t->string('name',160);
                $t->string('status',20)->nullable();
                $t->json('data');
                $t->unsignedInteger('version')->default(1);
                $t->timestamps();
                $t->softDeletes();
                $t->index(['user_id','deleted_at','id']);
            });
        }
        Schema::table('purchase_items', fn(Blueprint $t) => $t->json('reorder_levels')->nullable());
    }
    public function down(): void {
        Schema::table('purchase_items', fn(Blueprint $t) => $t->dropColumn('reorder_levels'));
        foreach (['purchase_events','purchase_bills','purchase_suppliers'] as $table) Schema::dropIfExists($table);
    }
};
