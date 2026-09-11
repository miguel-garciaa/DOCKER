<?php

$port = filter_var(getenv('REVERB_SERVER_PORT'), FILTER_VALIDATE_INT) ?: 8080;
$socket = @fsockopen('127.0.0.1', $port, $errorCode, $errorMessage, 2);

if (is_resource($socket)) {
    fclose($socket);

    exit(0);
}

exit(1);
