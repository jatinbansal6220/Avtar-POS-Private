<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void {
        Schema::table('users', function (Blueprint $t) {
            $t->string('restaurant_name')->default('');
            $t->foreignId('owner_id')->nullable()->constrained('users')->restrictOnDelete();
            $t->string('role')->default('owner');
            $t->unsignedBigInteger('sync_version')->default(0);
        });
        foreach (['tables','menu_items','combos','orders','bills','staff','attendance','payments','settings','banks','purchases'] as $name) {
            Schema::create($name, function (Blueprint $t) use ($name) {
                $t->uuid('id')->primary();
                $t->foreignId('user_id')->constrained('users')->restrictOnDelete();
                $t->unsignedInteger('version')->default(1);
                $t->timestamps();
                $t->softDeletes();
                $t->index(['user_id','deleted_at','id']);
                match ($name) {
                    'tables' => \App\Modules\Tables\TablesSchema::columns($t),
                    'menu_items' => \App\Modules\Menu\MenuSchema::columns($t),
                    'combos' => \App\Modules\Combos\CombosSchema::columns($t),
                    'staff' => \App\Modules\Staff\StaffSchema::columns($t),
                    'attendance' => \App\Modules\Attendance\AttendanceSchema::columns($t),
                    'payments' => \App\Modules\Payments\PaymentsSchema::columns($t),
                    'banks' => \App\Modules\Banks\BanksSchema::columns($t),
                    'purchases' => \App\Modules\Purchases\PurchasesSchema::columns($t),
                    'settings' => \App\Modules\Settings\SettingsSchema::columns($t),
                    'orders' => \App\Modules\Orders\OrdersSchema::columns($t),
                    'bills' => \App\Modules\Billing\BillingSchema::columns($t),
                };
            });
        }
        Schema::create('combo_items', function (Blueprint $t) {
            $t->id(); $t->foreignUuid('combo_id')->constrained('combos')->cascadeOnDelete();
            $t->foreignUuid('menu_item_id')->constrained('menu_items')->restrictOnDelete();
            $t->unsignedInteger('quantity'); $t->unique(['combo_id','menu_item_id']);
        });
        Schema::create('order_items', function (Blueprint $t) {
            $t->uuid('id')->primary(); $t->foreignUuid('order_id')->constrained('orders')->restrictOnDelete();
            $t->foreignUuid('menu_item_id')->nullable()->constrained('menu_items')->restrictOnDelete();
            $t->foreignUuid('combo_id')->nullable()->constrained('combos')->restrictOnDelete();
            $t->string('item_name',160); $t->unsignedInteger('quantity'); $t->unsignedBigInteger('price_minor');
            $t->string('notes',500)->nullable(); $t->json('components')->nullable();
        });
        Schema::create('changes', function (Blueprint $t) {
            $t->id(); $t->foreignId('user_id')->constrained('users'); $t->unsignedBigInteger('sequence');
            $t->string('resource',30); $t->uuid('entity_id'); $t->string('operation',10); $t->json('payload');
            $t->timestamp('created_at'); $t->unique(['user_id','sequence']);
        });
        Schema::create('mutation_receipts', function (Blueprint $t) {
            $t->id(); $t->foreignId('user_id')->constrained('users'); $t->uuid('key'); $t->string('fingerprint',64);
            $t->json('response'); $t->unsignedSmallInteger('status'); $t->timestamp('created_at');
            $t->unique(['user_id','key']);
        });
    }
    public function down(): void {
        foreach (['mutation_receipts','changes','order_items','combo_items','purchases','banks','settings','payments','attendance','staff','bills','orders','combos','menu_items','tables'] as $name) Schema::dropIfExists($name);
        Schema::table('users', function (Blueprint $t) {
            $t->dropForeign(['owner_id']); $t->dropColumn(['restaurant_name','owner_id','role','sync_version']);
        });
    }
};
