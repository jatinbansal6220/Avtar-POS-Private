<?php
namespace App\Modules\Combos;
use Illuminate\Database\Schema\Blueprint;
final class CombosSchema {
    public static function columns(Blueprint $t): void {
        $t->string('name',160); $t->unsignedBigInteger('price_minor');
                        $t->boolean('is_active')->default(true); $t->text('description')->nullable();
    }
}
