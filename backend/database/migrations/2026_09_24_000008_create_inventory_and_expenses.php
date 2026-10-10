<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void {
        Schema::create('inventory_items', function (Blueprint $t) {
            $t->uuid('id')->primary();
            $t->foreignId('user_id')->constrained('users')->restrictOnDelete();
            $t->string('name',160);
            $t->string('unit',20)->default('pcs');
            $t->unsignedInteger('current_quantity')->default(0);
            $t->dateTime('last_recorded_at');
            $t->unsignedInteger('version')->default(1);
            $t->timestamps();
            $t->softDeletes();
            $t->unique(['user_id','name']);
            $t->index(['user_id','deleted_at','id']);
        });
        Schema::create('inventory_entries', function (Blueprint $t) {
            $t->uuid('id')->primary();
            $t->foreignId('user_id')->constrained('users')->restrictOnDelete();
            $t->uuid('inventory_item_id');
            $t->unsignedInteger('quantity');
            $t->dateTime('recorded_at');
            $t->text('note')->nullable();
            $t->unsignedInteger('version')->default(1);
            $t->timestamps();
            $t->softDeletes();
            $t->index(['user_id','inventory_item_id','recorded_at']);
            $t->index(['user_id','deleted_at','id']);
        });
        Schema::create('expenses', function (Blueprint $t) {
            $t->uuid('id')->primary();
            $t->foreignId('user_id')->constrained('users')->restrictOnDelete();
            $t->string('title',160);
            $t->unsignedBigInteger('amount_minor');
            $t->date('expense_date');
            $t->text('notes')->nullable();
            $t->unsignedInteger('version')->default(1);
            $t->timestamps();
            $t->softDeletes();
            $t->index(['user_id','expense_date']);
            $t->index(['user_id','deleted_at','id']);
        });
    }

    public function down(): void {
        Schema::dropIfExists('expenses');
        Schema::dropIfExists('inventory_entries');
        Schema::dropIfExists('inventory_items');
    }
};
