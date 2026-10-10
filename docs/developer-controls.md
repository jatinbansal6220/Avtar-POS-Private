# Developer controls

Open with **Ctrl+Shift+F12** on Windows/web, or **Settings → Developer controls** on Android. A paused app also exposes **Developer access**. A normal authenticated restaurant session and online developer password verification are required. Existing staff/owner API permissions continue to apply; this panel does not replace account authentication or registration activation.

The panel supports a global policy for all restaurants and a policy for each restaurant. Global and restaurant flags are combined with AND: a restaurant cannot enable something disabled globally. The developer can pause app access, set the pause message, and manage the 29 module/action switches listed in `backend/config/developer.php` and `frontend/lib/core/feature_policy.dart`.

Changes require an explicit confirmation identifying the target. Updates use a revision check; a stale panel must reload instead of overwriting someone else's change. The server records the actor and encrypted before/after values.

## Private server setup

Deploy backend source using the existing server checkout and retain its current `.env` and `APP_KEY`. From the Laravel `backend/` directory:

```sh
composer install --no-dev --optimize-autoloader
php artisan migrate --force
php artisan developer:password-hash
```

The last command prompts privately for the intended developer password and prints a bcrypt hash assignment. Put that assignment in the server `.env` as `DEVELOPER_PASSWORD_HASH`, then run:

```sh
php artisan config:cache
php artisan route:cache
```

Do not put the actual password or its configured hash in Git, build definitions, release assets or client code. The example environment has an empty value; developer access returns 503 until privately provisioned. Changing the hash invalidates existing developer grants. Do not rotate the existing Laravel `APP_KEY`: encrypted policies and audit entries depend on it. Preserve that key with the server's private backup.

The new migration adds only `developer_controls` and `developer_control_audits`. Existing business tables/migrations are unchanged. Backend tests run against a disposable in-memory SQLite database and exclude the existing MySQL-only terminal-number migration; they do not migrate the live database.

## Client rollout and offline behavior

Publish a new EXE/APK release through the existing updater, using the original Android signing key. Old clients do not understand these controls; a backend deploy alone cannot remotely pause or change an older executable.

Updated signed-in clients refresh policy every 30 seconds, including while app access or sync is paused. Offline terminals retain their last accepted restaurant policy; newly provisioned terminals with no policy can work offline until the first successful fetch. These are operational feature controls, not a replacement for server role/tenant authorization or tamper-resistant licensing.

App pause prevents new normal UI actions and local mutation services from accepting new work. Existing screens stay mounted to preserve unsaved editors and already-started local writes. Automatic sync may finish/upload previously saved work while app access is paused. Turning the separate **Online sync** flag off stops subsequent sync passes; it preserves SQLite records and the durable outbox, then resumes queued uploads when enabled. An already-started pass/action is allowed to finish safely.

Disabling **New discounts** preserves historical item discounts and receipts. Disabled payment methods are rejected when creating/editing payment. Printing guards run before new KOT acknowledgements are recorded. Existing completed print jobs are not recalled.

## Security boundary

The developer password is verified with bcrypt only on the server over the existing HTTPS API. Attempts have a dedicated rate limit. A developer grant is encrypted/authenticated by Laravel, bound to the signed-in user and their exact API token, and expires after 10 minutes. It is kept only in the panel's memory, never in SQLite, preferences or the outbox.

Server policies and audit changes are encrypted/authenticated using Laravel's `Crypt` and current server `APP_KEY`. Clients necessarily receive effective feature flags and the visible pause message; these non-secret operational values are cached in local preferences for offline continuity. The client cache is not an encrypted database or an authorization boundary. Bills, existing session storage and business data encryption are explicitly outside this change.

The new policy/developer routes precede existing generic resource routes. Existing mutation and sync APIs continue accepting previously queued work, including work from old clients, so disabling a feature does not strand production bills as sync conflicts.

## Verification

```sh
php vendor/phpunit/phpunit/phpunit --filter DeveloperControlsTest
flutter test --no-pub test/developer_controls_test.dart
```

The regression suite also covers normal dining saves, table-floor query costs, local/offline sync, KOT persistence, payment/UPI and existing updater behavior. Native printer hardware, customer rollout and VPS deployment require their actual environment.
