<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void {
        Schema::create('table_bookings', function (Blueprint $t) {
            $t->uuid('id')->primary();
            $t->foreignId('user_id')->constrained('users')->restrictOnDelete();
            $t->uuid('table_id');
            $t->string('table_number',40);
            $t->dateTime('start_at');
            $t->dateTime('end_at');
            $t->string('customer_name',160)->nullable();
            $t->string('customer_phone',30)->nullable();
            $t->unsignedInteger('version')->default(1);
            $t->timestamps();
            $t->softDeletes();
            $t->index(['user_id','table_id','start_at','end_at']);
            $t->index(['user_id','deleted_at','id']);
        });
    }

    public function down(): void {
        Schema::dropIfExists('table_bookings');
    }
};
