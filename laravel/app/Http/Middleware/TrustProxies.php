<?php

namespace App\Http\Middleware;

use Illuminate\Http\Middleware\TrustProxies as Middleware;
use Illuminate\Http\Request;

class TrustProxies extends Middleware
{
    protected $headers = Request::HEADER_X_FORWARDED_FOR | Request::HEADER_X_FORWARDED_PROTO;

    /** @return list<string> */
    protected function proxies(): array
    {
        $host = config('app.trusted_proxy_host');

        // Docker DNS se consulta en cada petición; Octane no conserva IPs obsoletas.
        return is_string($host) && $host !== '' ? (gethostbynamel($host) ?: []) : [];
    }
}
