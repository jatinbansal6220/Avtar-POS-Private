<?php
namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;

final class AtomicMutation {
    public function handle(Request $request, Closure $next) {
        $key = $request->header('Idempotency-Key');
        abort_unless($key && Str::isUuid($key), 422, 'A UUID Idempotency-Key is required.');
        $tenant = $request->user()->tenantId();
        return DB::transaction(function () use ($request, $next, $key, $tenant) {
            // Tenant lock makes mutation commits and change cursors strictly ordered.
            DB::table('users')->where('id',$tenant)->lockForUpdate()->first();
            $fingerprint = hash('sha256', $request->user()->id.'|'.$request->method().'|'.$request->path().'|'.$request->getContent());
            $previous = DB::table('mutation_receipts')->where(['user_id'=>$tenant,'key'=>$key])->first();
            if ($previous) {
                abort_unless(hash_equals($previous->fingerprint,$fingerprint),409,'Idempotency key already used for another request.');
                return response()->json(json_decode($previous->response,true),$previous->status);
            }
            $response = $next($request);
            if ($response->getStatusCode() >= 400) {
                // Do not commit any write performed before a handled validation failure.
                throw new \Illuminate\Http\Exceptions\HttpResponseException($response);
            }
            DB::table('mutation_receipts')->insert(['user_id'=>$tenant,'key'=>$key,'fingerprint'=>$fingerprint,
                'response'=>$response->getContent(),'status'=>$response->getStatusCode(),'created_at'=>now()]);
            return $response;
        }, 3);
    }
}
