<?php

use Illuminate\Contracts\Console\Kernel;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Redis;

// Se ejecuta antes de las migraciones; no imprime credenciales ni excepciones.
require '/app/vendor/autoload.php';
$app = require '/app/bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();
try {
    DB::select('select 1');
    Redis::connection()->ping();
    fwrite(STDOUT, "PostgreSQL y Redis accesibles con las credenciales de Laravel.\n");
} catch (Throwable $exception) {
    fwrite(STDERR, "Fallo de conexion de Laravel con PostgreSQL o Redis. Revisar configuracion y logs.\n");
    exit(1);
}
