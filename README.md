# Avtar Cooks POS — developer handoff

This repository contains the source required to continue Avtar Cooks / AvtarPOS development. It deliberately excludes customer builds, local SQLite data, production credentials, Laravel `vendor/`, Flutter build output, and logs.

**New developer / AI account:** Start with [00_START_HERE_AI_PROMPT.txt](00_START_HERE_AI_PROMPT.txt) for a copy-ready safety prompt and localhost demo commands.

## Layout

- `frontend/` — Flutter application for Windows, Android, and web.
- `backend/` — Laravel API. Its `public/` directory is the Nginx document root.

## Product behaviour to preserve

- Offline-first: each device saves locally before attempting server sync. Do not make order/bill saving wait for the API.
- Each logged-in owner account is isolated. A new device/account must not use another account's local SQLite data.
- Live API: `https://avtarpos.duckdns.org/api`. It can be overridden with `--dart-define=API_BASE_URL=...`.
- Indian time is used for bills, analytics, and reports (`Asia/Kolkata`).
- Flutter sends queued local changes through its outbox; the Laravel API must remain backwards-compatible with that payload contract.

## First setup

For a Windows localhost demo, extract the **AvtarPOS-Localhost-Windows.zip** package from [GitHub Releases](https://github.com/jatinbansal6220/Avtar-POS-Private/releases/tag/localhost-v20261014), then double-click `START_APP_LOCALHOST.bat`. The package includes the built demo and portable Python: no Flutter/Python installation, administrator access or ChatGPT is needed. It opens `http://127.0.0.1:8080/` and starts the server in the background. After restarting the PC, double-click the same BAT again. Keep the extracted folders together.

From a fresh **source ZIP**, the same BAT downloads and verifies this package on its first run; internet is required once. Later runs reuse the downloaded package. After editing source, rebuild using `00_START_HERE_AI_PROMPT.txt`. This localhost package is a **demo**; it does not sign in or sync with the production server. Browser data stays on that PC at the same localhost origin.

1. Read `frontend/README.md` for Flutter run/build instructions.
2. Read `backend/README.md` for VPS deployment, migrations, and environment setup.
3. Never commit `.env`, release EXEs/APKs, SQLite files, `vendor/`, `build/`, or customer data.

## Main functional areas

Tables and table transfer/merge, menu & POS, takeaway/online orders, KOT, checkout/receipts, invoice history, staff/attendance, purchases/inventory, bank/UPI QR settings, analytics/day report, and offline sync are present in the Flutter feature folders. The Laravel `app/Modules` folders mirror the API domains.

## Safe change workflow

Make schema changes through new Laravel migrations only. Keep bill/order identifiers idempotent and preserve server-side conflict handling. Test a feature in web/desktop before publishing a release. For backend deployment: pull, `composer install --no-dev --optimize-autoloader`, migrate with `--force`, then rebuild Laravel caches as documented in `backend/README.md`.

## Client releases and in-app updates

The stable update channel uses the public assets-only repository [`ISanjuAi2/avtar-cooks-releases`](https://github.com/ISanjuAi2/avtar-cooks-releases). This source repository remains private. Firebase is not part of this update flow and the `codex/firebase-serverless` branch must not be merged into `main` for the Windows client.

- Release Windows and Android apps check `latest.json` about 15 seconds after launch, then every five minutes while running. New EXE/APK releases download automatically over HTTPS and are SHA-256 verified before installation.
- **Settings → App updates** provides Check for updates, Download update, and (Windows only) Install & restart.
- Windows automatically installs and restarts only on a login/locked screen, with no running sync, pending outbox entries, conflicts or saved drafts. Active billing is never automatically interrupted. A banner and Settings also allow an explicit Install & restart; durable SQLite, drafts and outbox remain outside the installer payload. Automatic installation refuses to kill another running AvtarPOS window.
- Android downloads and verifies the APK in private cache. A banner on every screen offers Install update. Android then requires the owner's installation approval and, on first use, permission to install from this app. Existing devices require the same Android signing key and a higher build number; there is no silent APK installation on ordinary devices.
- Debug and `DEMO_MODE=true` builds deliberately disable the updater.

To publish a real public release from a Windows machine with GitHub CLI access:

```powershell
cd "D:\Milk Software\Avtar-all-code-backend-frontend-main"
gh auth login
.\tools\release\publish_github_release.ps1 -Version 1.2.3 -BuildNumber 123 -FlutterPath "D:\CodexTemp\AvtarPOS\flutter\bin\flutter.bat" -Notes "Describe the changes"
```

The script builds the Windows runtime and self-installing EXE, builds the APK, calculates SHA-256 values, creates GitHub Release `v<version>`, and uploads exactly `AvtarPOS-Client-Setup-<version>.exe`, `AvtarCook-<version>.apk`, and `latest.json`. Never upload only an EXE manually: clients require the matching manifest and SHA-256 hash. Do not commit release EXEs/APKs, keystores, `key.properties`, `local.properties`, `.env`, or GitHub tokens.

Deploying Laravel alone updates API behavior, not installed Flutter binaries. For client UI/code changes, publish a new signed client release after deploying any required backwards-compatible API changes. Clients must be online and running to discover it; closed apps check on their next launch. Existing manual-updater clients need this updater release installed once before future automatic downloads become available. Publishing remains an explicit developer operation; source edits do not deploy or publish anything.

### Developer controls

`Ctrl+Shift+F12` (Windows/web) or Settings → Developer controls (Android) opens online developer verification. Global and restaurant policies cover app access and 29 module/action switches. Server policies and audit changes are encrypted; the developer password hash is provisioned privately on the server, never embedded in clients. See [developer setup, rollout and offline behavior](docs/developer-controls.md). Existing bills/database encryption is outside this feature.
