<?php
namespace App\Modules\Tables;
use Illuminate\Database\Schema\Blueprint;
final class TablesSchema {
    public static function columns(Blueprint $t): void {
        $t->string('table_number',40); $t->string('section',80)->default('Main floor');
                        $t->unsignedSmallInteger('capacity')->default(4); $t->string('status')->default('empty');
                        $t->uuid('current_order_id')->nullable(); $t->unique(['user_id','table_number']);
    }
}
