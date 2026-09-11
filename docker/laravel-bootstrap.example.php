<?php
// REFERENCIA para fusionar con bootstrap/app.php; no reemplazarlo a ciegas.
use Illuminate\Foundation\Application;
use Illuminate\Foundation\Configuration\Exceptions;
use Illuminate\Foundation\Configuration\Middleware;
use Illuminate\Http\Request;

return Application::configure(basePath: dirname(__DIR__))
    ->withRouting(
        web: __DIR__.'/../routes/web.php',
        commands: __DIR__.'/../routes/console.php',
        health: '/up',
    )
    ->withMiddleware(function (Middleware $middleware): void {
        // IP del conector cloudflared en la red Docker dedicada.
        // No confiar en '*' ni aceptar X-Forwarded-Host enviado por el cliente.
        $middleware->trustProxies(
            at: ['172.30.91.2'],
            headers: Request::HEADER_X_FORWARDED_FOR | Request::HEADER_X_FORWARDED_PROTO,
        );
    })
    ->withExceptions(function (Exceptions $exceptions): void {
        // Conservar la configuracion propia de la aplicacion.
    })->create();
