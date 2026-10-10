<?php
namespace App\Modules\Settings;
use Illuminate\Database\Schema\Blueprint;
final class SettingsSchema {
    public static function columns(Blueprint $t): void {
        $t->unique('user_id'); $t->string('restaurant_name',160); $t->text('restaurant_address')->nullable();
                        $t->string('restaurant_phone',30)->nullable(); $t->string('gstin',30)->nullable();
                        $t->string('fssai_lic',30)->nullable(); $t->string('tagline',160)->nullable();
                        $t->string('printer_ip',45)->nullable(); $t->unsignedSmallInteger('printer_port')->default(9100);
                        $t->string('printer_paper_width')->default('80mm'); $t->boolean('is_tax_enabled')->default(false);
                        $t->unsignedInteger('tax_basis_points')->default(0);
                        $t->unsignedInteger('default_discount_basis_points')->default(0);
                        $t->string('timezone')->default('Asia/Kolkata'); $t->json('online_platforms')->nullable();
    }
}
