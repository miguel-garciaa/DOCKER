import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { createServer, request } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const caddy = process.argv[2];
assert(caddy, 'Uso: node laravel/tests/Infrastructure/proxy.mjs /ruta/a/caddy');
const directory = await mkdtemp(join(tmpdir(), 'laravel-proxy-test-'));
const servers = [];
let proxy;
let logs = '';
const listen = async (name) => {
    const server = createServer((req, res) => {
        res.setHeader('Content-Type', 'application/json');
        res.setHeader('Set-Cookie', 'session=secret-for-test');
        res.end(JSON.stringify({ name, headers: req.headers }));
    });
    server.listen(0, '127.0.0.1');
    await once(server, 'listening');
    servers.push(server);
    return server.address().port;
};
const reservePort = async () => {
    const server = createServer().listen(0, '127.0.0.1');
    await once(server, 'listening');
    const port = server.address().port;
    await new Promise((resolve) => server.close(resolve));
    return port;
};
try {
    const app1 = await listen('app-1');
    const app2 = await listen('app-2');
    const metrics = await listen('prometheus');
    const publicPort = await reservePort();
    const internalPort = await reservePort();
    const source = await readFile(new URL('../../../docker/Caddyfile', import.meta.url), 'utf8');
    const config = source.replaceAll('app-1:8000', '127.0.0.1:' + app1)
        .replaceAll('app-2:8000', '127.0.0.1:' + app2)
        .replaceAll('prometheus:9090', '127.0.0.1:' + metrics)
        .replace('auto_https off', 'auto_https off\n\tdefault_bind 127.0.0.1')
        .replace('http://:8000', 'http://:' + publicPort)
        .replace('http://:9101', 'http://:' + internalPort);
    const file = join(directory, 'Caddyfile');
    await writeFile(file, config);
    const hash = execFileSync('php', ['-r', 'echo password_hash("test-only-password", PASSWORD_BCRYPT);'], { encoding: 'utf8' });
    proxy = spawn(caddy, ['run', '--config', file, '--adapter', 'caddyfile'], {
        windowsHide: true,
        env: { ...process.env, APP_DOMAIN: 'app.example.com', METRICS_DOMAIN: 'metrics.example.com',
            CLOUDFLARED_IPS: '127.0.0.1', METRICS_USERNAME: 'grafana', METRICS_PASSWORD_HASH: hash,
            BLOCKED_IPS: '198.51.100.5', XDG_CONFIG_HOME: directory, XDG_DATA_HOME: directory },
        stdio: ['ignore', 'pipe', 'pipe'],
    });
    proxy.stdout.on('data', (chunk) => { logs += chunk; });
    proxy.stderr.on('data', (chunk) => { logs += chunk; });
    let ready = false;
    for (let attempt = 0; attempt < 100; attempt++) {
        try {
            ready = (await fetch('http://127.0.0.1:' + internalPort + '/health')).ok;
            if (ready) break;
        } catch { /* Arranque acotado. */ }
        await new Promise((resolve) => setTimeout(resolve, 50));
    }
    assert(ready, logs);
    const send = (path = '/', headers = {}, localAddress = '127.0.0.1') => new Promise((resolve, reject) => {
        const req = request({ host: '127.0.0.1', port: publicPort, path, localAddress,
            headers: { Host: 'app.example.com', 'X-Forwarded-Proto': 'https',
                'CF-Connecting-IP': '203.0.113.10', ...headers } }, (res) => {
            let body = '';
            res.on('data', (chunk) => { body += chunk; });
            res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body }));
        });
        req.on('error', reject);
        req.end();
    });
    const forwarded = await send('/', { 'X-Forwarded-For': '1.2.3.4' });
    assert.equal(forwarded.status, 200);
    assert.equal(JSON.parse(forwarded.body).headers['x-forwarded-for'], '203.0.113.10');
    assert.equal(JSON.parse(forwarded.body).headers['cf-connecting-ip'], undefined);
    assert.equal((await send('/', { 'CF-Connecting-IP': '198.51.100.5' })).status, 403);
    assert.equal((await send('/', {}, '127.0.0.2')).status, 403);
    assert.equal((await send('/internal/metrics')).status, 404);
    assert.equal((await send('/', { Host: 'unknown.example.com' })).status, 421);
    assert.equal((await send('/', { 'X-Forwarded-Proto': 'http' })).status, 308);
    assert.equal((await send('/', { Host: 'metrics.example.com' })).status, 401);
    assert.equal((await send('/', { Host: 'metrics.example.com', Authorization: 'Basic bad' })).status, 401);
    assert.equal((await send('/', { Host: 'metrics.example.com', 'X-Forwarded-Proto': 'http' })).status, 403);
    const authenticated = await send('/', { Host: 'metrics.example.com',
        Authorization: 'Basic ' + Buffer.from('grafana:test-only-password').toString('base64') });
    assert.equal(authenticated.status, 200);
    assert.equal(JSON.parse(authenticated.body).name, 'prometheus');
    // Parar una replica: tras el siguiente healthcheck todo el trafico usa la otra.
    await new Promise((resolve) => servers[0].close(resolve));
    servers[0].closeAllConnections();
    await new Promise((resolve) => setTimeout(resolve, 11000));
    for (let i = 0; i < 5; i++) {
        const response = await send();
        assert.equal(response.status, 200);
        assert.equal(JSON.parse(response.body).name, 'app-2');
    }
    assert(!logs.includes('secret-for-test'), 'Los logs no deben contener cookies de respuesta');
    console.log('PASS: IP real, bloqueo de IP/peer, rutas internas, HTTPS, Basic Auth, replica caida y logs sin cookies.');
} catch (error) {
    console.error(logs);
    throw error;
} finally {
    if (proxy && proxy.exitCode === null) {
        const exited = once(proxy, 'exit');
        proxy.kill();
        await exited;
    }
    for (const server of servers) {
        server.closeAllConnections();
        await new Promise((resolve) => server.close(resolve));
    }
    assert(directory.startsWith(join(tmpdir(), 'laravel-proxy-test-')));
    await rm(directory, { recursive: true, force: true });
}
