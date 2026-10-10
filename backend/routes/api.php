<?php
use Illuminate\Support\Facades\Route;
use Illuminate\Support\Facades\DB;
use App\Http\Controllers\{AuthController,ResourceController,OrderController,SyncController,AnalyticsController};

$health = function () {
    try {
        DB::connection()->getPdo();

        return response()->json([
            'status' => 'ok',
            'database' => 'connected',
            'timestamp' => now()->toIso8601String(),
        ]);
    } catch (\Throwable $exception) {
        report($exception);

        return response()->json(['status' => 'unavailable'], 503);
    }
};

// The mobile/desktop app stores this as its API base URL. Returning a small
// health response here prevents a misleading 404 when that address is opened
// directly in a browser or verified by a network monitor.
Route::get('/', $health);
Route::get('health', $health);

Route::post('auth/login',[AuthController::class,'login'])->middleware('throttle:10,1');
Route::post('auth/register',[AuthController::class,'register'])->middleware('throttle:5,1');
Route::middleware(['auth:sanctum','throttle:600,1'])->group(function () {
    Route::get('control-policy', [\App\Http\Controllers\DeveloperController::class, 'policy']);
    Route::post('developer/unlock', [\App\Http\Controllers\DeveloperController::class, 'unlock'])->middleware('throttle:developer-unlock');
    Route::middleware([\App\Http\Middleware\DeveloperAccess::class, 'throttle:developer-controls'])->group(function () {
        Route::get('developer/controls', [\App\Http\Controllers\DeveloperController::class, 'index']);
        Route::put('developer/controls/{scope}', [\App\Http\Controllers\DeveloperController::class, 'save']);
    });
    Route::get('auth/me',[AuthController::class,'me']);
    Route::post('auth/logout',[AuthController::class,'logout']);
    Route::get('updates',[SyncController::class,'updates']);
    Route::get('sync/cursor',[SyncController::class,'cursor']);
    Route::get('analytics',[AnalyticsController::class,'index']);
    Route::middleware('mutation')->group(function () {
        Route::post('orders',[OrderController::class,'save']);
        Route::put('orders/{id}',[OrderController::class,'save']);
        Route::post('orders/{id}/status',[OrderController::class,'status']);
        Route::post('orders/{id}/transfer',[OrderController::class,'transfer']);
        Route::post('orders/{id}/merge',[OrderController::class,'merge']);
        Route::post('orders/{id}/unmerge',[OrderController::class,'unmerge']);
        Route::post('bills/generate',[OrderController::class,'bill']);
        Route::post('bills/{id}/settlement',[OrderController::class,'settleBill']);
        Route::post('bills/delete-code',[ResourceController::class,'setBillDeleteCode']);
        Route::post('{resource}',[ResourceController::class,'save']);
        Route::put('{resource}/{id}',[ResourceController::class,'save']);
        Route::delete('{resource}/{id}',[ResourceController::class,'delete']);
    });
    Route::get('{resource}',[ResourceController::class,'index']);
    Route::get('{resource}/{id}',[ResourceController::class,'show']);
});
