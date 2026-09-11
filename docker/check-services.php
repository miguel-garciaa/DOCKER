<?php
// Se ejecuta antes de las migraciones; no imprime credenciales ni excepciones.
require '/app/vendor/autoload.php';
$app = require '/app/bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
try {
    Illuminate\Support\Facades\DB::select('select 1');
    Illuminate\Support\Facades\Redis::connection()->ping();
    fwrite(STDOUT, "PostgreSQL y Redis accesibles con las credenciales de Laravel.\n");
} catch (Throwable $exception) {
    fwrite(STDERR, "Fallo de conexion de Laravel con PostgreSQL o Redis. Revisar configuracion y logs.\n");
    exit(1);
}
