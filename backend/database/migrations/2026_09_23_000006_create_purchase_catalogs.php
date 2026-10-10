<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void {
        Schema::create('purchase_categories', function (Blueprint $t) {
            $t->uuid('id')->primary();
            $t->foreignId('user_id')->constrained('users')->restrictOnDelete();
            $t->string('name',80);
            $t->unsignedInteger('version')->default(1);
            $t->timestamps();
            $t->softDeletes();
            $t->unique(['user_id','name']);
            $t->index(['user_id','deleted_at','id']);
        });
        Schema::create('purchase_items', function (Blueprint $t) {
            $t->uuid('id')->primary();
            $t->foreignId('user_id')->constrained('users')->restrictOnDelete();
            $t->uuid('category_id');
            $t->string('category_name',80);
            $t->string('name',160);
            $t->boolean('is_active')->default(true);
            $t->unsignedInteger('version')->default(1);
            $t->timestamps();
            $t->softDeletes();
            $t->unique(['user_id','category_id','name']);
            $t->index(['user_id','category_id','deleted_at','id']);
        });
        Schema::table('purchases', function (Blueprint $t) {
            $t->uuid('purchase_item_id')->nullable()->after('item_name');
            $t->index(['user_id','purchase_item_id','purchase_date']);
        });
    }

    public function down(): void {
        Schema::table('purchases', function (Blueprint $t) {
            $t->dropIndex(['user_id','purchase_item_id','purchase_date']);
            $t->dropColumn('purchase_item_id');
        });
        Schema::dropIfExists('purchase_items');
        Schema::dropIfExists('purchase_categories');
    }
};
