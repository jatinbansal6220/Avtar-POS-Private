<?php
namespace App\Console\Commands;

use Illuminate\Console\Command;

final class DeveloperPasswordHash extends Command {
    protected $signature = 'developer:password-hash';
    protected $description = 'Generate a developer password hash for the private server environment';
    public function handle(): int {
        $password = $this->secret('Developer password (not stored by this command)');
        if (!is_string($password) || strlen($password) < 8 || strlen($password) > 72) {
            $this->error('Use a password between 8 and 72 bytes.');
            return self::FAILURE;
        }
        $this->line('DEVELOPER_PASSWORD_HASH='.password_hash($password, PASSWORD_BCRYPT));
        $this->info('Store this only in the server .env, then rebuild the configuration cache.');
        return self::SUCCESS;
    }
}
