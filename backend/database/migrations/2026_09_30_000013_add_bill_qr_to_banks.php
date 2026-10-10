<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void {
        Schema::table('banks', function (Blueprint $table): void {
            // A compressed 320px PNG is kept with the private bank record so
            // every authenticated terminal can print the same owner-supplied
            // payment QR while offline.
            if (!Schema::hasColumn('banks', 'qr_image_base64')) {
                $table->mediumText('qr_image_base64')->nullable()->after('ifsc_code');
            }
            if (!Schema::hasColumn('banks', 'is_default_qr')) {
                $table->boolean('is_default_qr')->default(false)->after('is_default');
            }
        });
    }

    public function down(): void {
        Schema::table('banks', function (Blueprint $table): void {
            $columns=array_filter(['qr_image_base64','is_default_qr'],fn(string $column): bool => Schema::hasColumn('banks',$column));
            if ($columns) $table->dropColumn($columns);
        });
    }
};
