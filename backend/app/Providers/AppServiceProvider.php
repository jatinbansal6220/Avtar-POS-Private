<?php

namespace App\Providers;

use Illuminate\Support\ServiceProvider;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Facades\RateLimiter;
use Illuminate\Cache\RateLimiting\Limit;
use Illuminate\Http\Request;

class AppServiceProvider extends ServiceProvider
{
    /**
     * Register any application services.
     */
    public function register(): void
    {
        //
    }

    /**
     * Bootstrap any application services.
     */
    public function boot(): void
    {
        // Supports MySQL installations with conservative indexed-key limits.
        Schema::defaultStringLength(191);
        RateLimiter::for('developer-unlock', fn(Request $request) => Limit::perMinute(5)->by($request->user()->id.'|'.$request->ip()));
        RateLimiter::for('developer-controls', fn(Request $request) => Limit::perMinute(30)->by((string) $request->user()->id));
    }
}
