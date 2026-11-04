<?php
// The Postgres Exporter app's management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('postgres_exporter');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path  = dirname(__DIR__);
$apps_path = dirname($app_path);
$data_path = $apps_path.'/_postgres_exporter';
$ctl       = $app_path.'/exporter_ctl.sh';

$action = $_GET['action'] ?? 'status';

/**
 * How setting up the exporter's login last went: login.status holds "ok <time>" or "failed <time> <why>".
 *
 * @param string $file login.status
 *
 * @return array{ state: 'ok'|'failed'|'none', time: string, message: string } The state, when, and why it failed
 */
function exporter_login_status(string $file): array
{
    $line = trim((string)@file_get_contents($file));

    if (!preg_match('/^(ok|failed) (\S+) ?(.*)$/', $line, $m)) {
        return ['state' => 'none', 'time' => '', 'message' => ''];
    }

    return ['state' => $m[1], 'time' => $m[2], 'message' => $m[3]];
}

/**
 * Whether the Prometheus app collects the exporter's metrics: its scrape job's target, from Prometheus' own API.
 *
 * @param string $apps_path Nas_Prog
 *
 * @return array{ installed: bool, health: string, error: string } health is up, down or unknown ('' when Prometheus
 *         doesn't list the job - e.g. not running)
 */
function exporter_prometheus(string $apps_path): array
{
    if (!is_dir($apps_path.'/prometheus')) {
        return ['installed' => false, 'health' => '', 'error' => ''];
    }

    list($status, $body) = manage_http_get('http://127.0.0.1:9090/api/v1/targets?scrapePool=postgres');

    $data   = $status === 200 ? json_decode($body, true) : null;
    $target = is_array($data) && isset($data['data']['activeTargets'][0]) ? $data['data']['activeTargets'][0] : [];

    return [
        'installed' => true,
        'health'    => isset($target['health']) ? (string)$target['health'] : '',
        'error'     => isset($target['lastError']) ? (string)$target['lastError'] : '',
    ];
}

/**
 * Where the exporter's dashboard is in the Grafana app: through the Nginx app when it serves Grafana, else on Grafana's
 * own port (unless Grafana only listens on the NAS itself).
 *
 * @param string $apps_path Nas_Prog
 *
 * @return array{ installed: bool, url: string, path: string, port: int } url is its full address through Nginx (or
 *         ''); otherwise path on port (0 when it can't be reached that way)
 */
function exporter_grafana(string $apps_path): array
{
    if (!is_dir($apps_path.'/grafana')) {
        return ['installed' => false, 'url' => '', 'path' => '', 'port' => 0];
    }

    $site  = manage_nginx_site($apps_path, 'http://127.0.0.1:3000');
    $local = preg_match('/^LISTEN=local$/m', (string)@file_get_contents($apps_path.'/_grafana/settings')) === 1;

    return [
        'installed' => true,
        'url'       => $site['state'] === 'ok' ? $site['url'].'d/wGgaPlciz' : '',
        'path'      => '/d/wGgaPlciz',
        'port'      => $local ? 0 : 3000,
    ];
}

if ($action === 'status') {
    $running = manage_pid_running('/var/run/postgres_exporter.pid');

    list($status, $metrics) = $running ? manage_http_get('http://127.0.0.1:9187/metrics', 10) : [0, ''];

    $rc  = (string)@file_get_contents($app_path.'/apkg.rc');
    $log = array_slice(array_filter(explode("\n", (string)@file_get_contents($data_path.'/postgres_exporter.log')), 'strlen'), -3);

    manage_json([
        'running'    => $running,
        'answering'  => $status === 200,
        // Its own metric saying whether it reached PostgreSQL at the last scrape
        'connected'  => preg_match('/^pg_up 1$/m', $metrics) === 1,
        'version'    => preg_match('/^Version:[ \t]*(\S+)/m', $rc, $m) ? $m[1] : '',
        'database'   => is_dir($apps_path.'/postgresql'),
        'login'      => exporter_login_status($data_path.'/login.status'),
        'prometheus' => exporter_prometheus($apps_path),
        'grafana'    => exporter_grafana($apps_path),
        'log'        => array_values($log),
    ]);
}

manage_require_action('postgres_exporter');

if ($action === 'restart') {
    list($code, $output) = manage_run(['/bin/sh', $ctl, 'restart']);

    if ($code !== 0) {
        manage_fail(500, 'Postgres Exporter could not be started: '.$output);
    }

    manage_json();
}

if ($action === 'login') {
    // Its login set up again (a new password), then the exporter restarted (waits up to 2 minutes for PostgreSQL)
    list($code, $output) = manage_run(['/bin/sh', $ctl, 'login']);

    if ($code !== 0) {
        $status = exporter_login_status($data_path.'/login.status');

        manage_fail(500, $status['state'] === 'failed' && $status['message'] !== '' ? $status['message'] : 'It failed: '.$output);
    }

    manage_json();
}

manage_fail(400, 'Unknown action');
