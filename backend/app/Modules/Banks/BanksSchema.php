<?php
namespace App\Modules\Banks;
use Illuminate\Database\Schema\Blueprint;
final class BanksSchema {
    public static function columns(Blueprint $t): void {
        $t->string('account_name',160); $t->string('bank_name',160); $t->string('account_type');
                        $t->string('account_number',40)->nullable(); $t->string('ifsc_code',20)->nullable();
                        $t->bigInteger('initial_balance_minor')->default(0); $t->boolean('is_default')->default(false); $t->boolean('use_for_card')->default(false);
                        $t->boolean('is_active')->default(true);
    }
}
