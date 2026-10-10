<?php
namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Crypt;

final class DeveloperAccess {
    public function handle(Request $request, Closure $next) {
        try {
            $grant = json_decode(Crypt::decryptString((string) $request->header('X-Developer-Token')), true, 512, JSON_THROW_ON_ERROR);
            $hash = (string) config('developer.password_hash');
            $valid = $hash !== '' && $grant['user'] === $request->user()->id
                && $grant['token'] === (string) $request->user()->currentAccessToken()?->getKey()
                && $grant['expires'] > now()->timestamp
                && hash_equals(hash('sha256', $hash), $grant['credential']);
        } catch (\Throwable $error) { $valid = false; }
        abort_unless($valid, 403, 'Developer verification expired. Verify again.');
        return $next($request);
    }
}
