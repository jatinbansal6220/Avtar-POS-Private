<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void {
        Schema::create('developer_controls', function (Blueprint $table) {
            $table->string('scope', 80)->primary();
            $table->text('encrypted_policy');
            $table->unsignedInteger('revision')->default(0);
            $table->unsignedBigInteger('updated_by')->nullable();
            $table->timestamps();
        });
        Schema::create('developer_control_audits', function (Blueprint $table) {
            $table->id();
            $table->string('scope', 80);
            $table->unsignedBigInteger('actor_id');
            $table->text('encrypted_change');
            $table->timestamp('created_at');
        });
    }
    public function down(): void {
        Schema::dropIfExists('developer_control_audits');
        Schema::dropIfExists('developer_controls');
    }
};
