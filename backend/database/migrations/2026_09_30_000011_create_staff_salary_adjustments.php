<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void {
        Schema::create('staff_salary_adjustments', function (Blueprint $table) {
            $table->uuid('id')->primary();
            $table->foreignId('user_id')->constrained('users')->restrictOnDelete();
            $table->foreignUuid('staff_id')->constrained('staff')->restrictOnDelete();
            $table->date('month_start');
            $table->unsignedTinyInteger('absent_days')->default(0);
            $table->unsignedTinyInteger('half_days')->default(0);
            $table->unsignedBigInteger('deduction_minor')->default(0);
            $table->string('reason', 500);
            $table->unsignedInteger('version')->default(1);
            $table->timestamps();
            $table->softDeletes();
            $table->unique(['user_id', 'staff_id', 'month_start']);
            $table->index(['user_id', 'staff_id', 'month_start']);
        });
    }

    public function down(): void {
        Schema::dropIfExists('staff_salary_adjustments');
    }
};
