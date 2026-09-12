<?php

// Solo comprueba el arranque HTTP. El deploy comprueba BD/Redis por separado.
$url = getenv('HEALTH_URL') ?: 'http://127.0.0.1:8000/up';
$curl = curl_init($url);
curl_setopt_array($curl, [
    CURLOPT_HTTPHEADER => ['Host: '.getenv('APP_DOMAIN')],
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_TIMEOUT => 3,
]);
$body = curl_exec($curl);
$status = curl_getinfo($curl, CURLINFO_RESPONSE_CODE);
curl_close($curl);
exit($body !== false && $status === 200 ? 0 : 1);
