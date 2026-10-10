<?php
namespace App\Modules\Menu;
use Illuminate\Database\Schema\Blueprint;
final class MenuSchema {
    public static function columns(Blueprint $t): void {
        $t->string('name',160); $t->unsignedBigInteger('price_minor'); $t->string('category',80);
                        $t->boolean('is_active')->default(true); $t->boolean('is_veg')->default(true);
                        $t->string('short_code',30)->nullable(); $t->text('description')->nullable();
                        $t->string('image_url',1000)->nullable(); $t->index(['user_id','category']);
    }
}
