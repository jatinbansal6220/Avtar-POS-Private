<?php

namespace App\Console\Commands;

use App\Models\User;
use App\Services\RestaurantDefaults;
use Illuminate\Console\Command;

final class InstallRestaurantDefaults extends Command
{
    protected $signature = 'restaurant:install-defaults {owner_email : Existing owner email address}';

    protected $description = 'Add missing default menu items and 16 Ground Floor tables without overwriting owner data';

    public function handle(): int
    {
        $owner = User::query()
            ->where('email', $this->argument('owner_email'))
            ->whereNull('owner_id')
            ->first();

        if ($owner === null) {
            $this->error('Owner account not found.');

            return self::FAILURE;
        }

        RestaurantDefaults::installFor($owner);
        $this->info('Default 16 Ground Floor tables and menu catalog are ready.');

        return self::SUCCESS;
    }
}
