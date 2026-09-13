<?php

namespace App\Providers;

use Carbon\CarbonImmutable;
use Illuminate\Cache\RateLimiting\Limit;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Date;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\RateLimiter;
use Illuminate\Support\ServiceProvider;
use Illuminate\Validation\Rules\Password;
use Symfony\Component\HttpFoundation\IpUtils;

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
        $this->configureDefaults();
    }

    /**
     * Configure default behaviors for production-ready applications.
     */
    protected function configureDefaults(): void
    {
        Date::use(CarbonImmutable::class);

        RateLimiter::for('web', function (Request $request) {
            $ip = $request->ip();

            if (IpUtils::checkIp($ip, config('app.blocked_ips'))) {
                return response()->noContent(403);
            }

            $limits = [
                Limit::perMinute((int) config('app.rate_limit_per_minute'))->by("global|{$ip}"),
            ];

            $routeName = $request->route()?->getName();

            if (in_array($routeName, [
                'password.email',
                'password.update',
                'register.store',
            ], true)) {
                $limits[] = Limit::perMinute(5)->by("sensitive|{$routeName}|{$ip}");
            }

            return $limits;
        });

        DB::prohibitDestructiveCommands(
            app()->isProduction(),
        );

        Password::defaults(fn (): ?Password => app()->isProduction()
            ? Password::min(12)
                ->mixedCase()
                ->letters()
                ->numbers()
                ->symbols()
                ->uncompromised()
            : null,
        );
    }
}
