<?php
// Scrutiny management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('scrutiny');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path      = dirname(__DIR__);
$apps_path     = dirname($app_path);
$data_path     = $apps_path.'/_scrutiny';
$settings_file = $data_path.'/settings';
$ctl           = $app_path.'/scrutiny_ctl.sh';
$target        = 'http://127.0.0.1:8091';

/**
 * Restarts Scrutiny (and InfluxDB) with its control script, failing the request if it doesn't start.
 *
 * @param string $ctl The app's control script
 *
 * @return void
 */
function scrutiny_restart(string $ctl): void
{
    list($code, $output) = manage_run(['/bin/sh', $ctl, 'restart']);

    if ($code !== 0) {
        manage_fail(500, 'Scrutiny could not be started: '.$output);
    }
}

/**
 * The disks Scrutiny knows, from its summary: each one's name, model, serial number, size, health, temperature and when
 * its SMART data was last read.
 *
 * @param string $target Scrutiny's address
 *
 * @return list<array{ name: string, model: string, serial: string, capacity: int, status: string, temperature: int, read: string }>|null
 *         The disks, or null if Scrutiny didn't answer
 */
function scrutiny_disks(string $target): ?array
{
    list($status, $body) = manage_http_get($target.'/api/summary', 5);
    $summary             = $status === 200 ? json_decode($body, true) : null;

    if (!is_array($summary) || !is_array($summary['data']['summary'] ?? null)) {
        return null;
    }

    $disks = [];

    foreach ($summary['data']['summary'] as $entry) {
        $device = is_array($entry['device'] ?? null) ? $entry['device'] : [];
        $smart  = is_array($entry['smart'] ?? null) ? $entry['smart'] : [];
        // Its status: a bit for smartctl's verdict (1) and one for Scrutiny's own, from failure rates (2)
        $flags  = (int)($device['device_status'] ?? 0);

        $disks[] = [
            'name'        => (string)($device['device_name'] ?? ''),
            'model'       => (string)($device['model_name'] ?? ''),
            'serial'      => (string)($device['serial_number'] ?? ''),
            'capacity'    => (int)($device['capacity'] ?? 0),
            'status'      => $flags === 0 ? 'passed' : (($flags & 1) !== 0 ? 'failed (SMART)' : 'failed (Scrutiny)'),
            'temperature' => (int)($smart['temp'] ?? 0),
            'read'        => (string)($smart['collector_date'] ?? ''),
        ];
    }

    usort($disks, function (array $a, array $b): int {
        return strcmp($a['name'], $b['name']);
    });

    return $disks;
}

$settings = (string)(@parse_ini_string((string)@file_get_contents($settings_file))['NTFY_TOPIC'] ?? '');
$action   = $_GET['action'] ?? 'status';

if ($action === 'status') {
    $running = manage_pid_running('/var/run/scrutiny.pid') && manage_pid_running('/var/run/scrutiny-influxd.pid');
    $disks   = $running ? scrutiny_disks($target) : null;
    $last    = @file($data_path.'/last_collect', FILE_IGNORE_NEW_LINES) ?: [];
    $log     = @file($data_path.'/collector.log', FILE_IGNORE_NEW_LINES) ?: [];
    $version = preg_match('/^Version:\s*(\S+)/m', (string)@file_get_contents($app_path.'/apkg.rc'), $v) ? $v[1] : '';

    manage_json([
        'running'      => $running,
        'answering'    => $disks !== null,
        'version'      => preg_replace('/-\d+$/', '', $version),
        'site'         => manage_nginx_site($apps_path, $target),
        'disks'        => $disks ?? [],
        'last_collect' => isset($last[0]) ? (int)$last[0] : 0,
        'collect_ok'   => ($last[1] ?? '') === '0',
        'collecting'   => is_dir('/var/run/scrutiny-collect'),
        'ntfy_topic'   => $settings,
        'ntfy'         => is_dir($apps_path.'/ntfy'),
        'log'          => array_slice($log, -20),
    ]);
}

manage_require_action('scrutiny');

if ($action === 'password') {
    manage_json(['password' => trim((string)@file_get_contents($data_path.'/password'))]);
}

if ($action === 'new_password') {
    // (Nginx reads the site's password file at every request: nothing to restart)
    list($code, $output) = manage_run(['/bin/sh', $ctl, 'new-password']);

    if ($code !== 0) {
        manage_fail(500, 'A new password could not be made: '.$output);
    }

    manage_json(['password' => trim((string)@file_get_contents($data_path.'/password'))]);
}

if ($action === 'collect') {
    if (is_dir('/var/run/scrutiny-collect')) {
        manage_fail(409, 'The disks are already being read');
    }

    // In the background: it takes a few seconds for each disk
    manage_run(['/bin/sh', '-c', 'nohup /bin/sh "$0" collect > /dev/null 2>&1 &', $ctl]);
    manage_json();
}

if ($action === 'settings') {
    $topic = isset($_POST['ntfy_topic']) ? trim((string)$_POST['ntfy_topic']) : '';

    if ($topic !== '' && !preg_match('/^[A-Za-z0-9_-]{1,64}$/', $topic)) {
        manage_fail(400, 'An ntfy topic is 1-64 letters, digits, _ and - (or nothing, for no alerts)');
    }

    if (!manage_write_file($settings_file, 'NTFY_TOPIC='.$topic."\n")) {
        manage_fail(500, 'The settings could not be saved');
    }

    scrutiny_restart($ctl);
    manage_json();
}

if ($action === 'test_alert') {
    list($status, $body) = manage_http_request('POST', $target.'/api/health/notify', '{}', 30);
    $result              = json_decode($body, true);

    if ($status !== 200 || !is_array($result) || ($result['success'] ?? false) !== true) {
        manage_fail(502, 'The test alert was not sent: '.(is_array($result) ? (string)json_encode($result['errors'] ?? $result) : 'Scrutiny did not answer'));
    }

    manage_json();
}

if ($action === 'restart') {
    scrutiny_restart($ctl);
    manage_json();
}

manage_fail(400, 'Unknown action');
