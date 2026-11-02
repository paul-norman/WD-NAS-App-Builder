<?php
// kvweb management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('kvweb');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path      = dirname(__DIR__);
$apps_path     = dirname($app_path);
$data_path     = $apps_path.'/_kvweb';
$settings_file = $data_path.'/settings';
$password_file = $data_path.'/password';
$ctl           = $app_path.'/kvweb_ctl.sh';

require $app_path.'/lib/kvweb.php';

/**
 * Restarts kvweb with its control script (stop, then start), failing the request if it doesn't start.
 *
 * @param string $ctl The app's control script
 *
 * @return void
 */
function kvweb_restart(string $ctl): void
{
    manage_run(['/bin/sh', $ctl, 'stop']);

    list($code, $output) = manage_run(['/bin/sh', $ctl, 'start']);

    if ($code !== 0) {
        manage_fail(500, 'kvweb could not be started: '.$output);
    }
}

$action = isset($_GET['action']) ? $_GET['action'] : 'status';

if ($action === 'status') {
    $running = manage_pid_running('/var/run/kvweb.pid');

    // Its health check also says whether it's connected to ValKey
    list($code, $body) = $running ? manage_http_get(KVWEB_TARGET.'/api/health') : [0, ''];

    $health = json_decode($body, true);

    list(, $version) = manage_run([$app_path.'/binaries/kvweb', '-version']);

    $log = @file($data_path.'/kvweb.log', FILE_IGNORE_NEW_LINES) ?: [];

    manage_json([
        'running'   => $running,
        'answering' => $code === 200 && isset($health['database']),
        'connected' => !empty($health['database']),
        'version'   => preg_match('/^kvweb (\S+)/', $version, $m) ? $m[1] : '',
        'readonly'  => (bool)preg_match('/^READONLY=1$/m', (string)@file_get_contents($settings_file)),
        'site'      => manage_nginx_site($apps_path, KVWEB_TARGET),
        'valkey'    => is_dir($apps_path.'/valkey'),
        'log'       => array_slice($log, -20),
    ]);
}

manage_require_action('kvweb');

if ($action === 'password') {
    manage_json(['password' => trim((string)@file_get_contents($password_file))]);
}

if ($action === 'set_password') {
    // A new password: the one given (letters, digits and . _ ~ - only, like the other apps), or a random one. Nginx
    // reads the new htpasswd file on the next request, so nothing restarts
    $new = isset($_POST['password']) ? trim((string)$_POST['password']) : '';

    if ($new === '') {
        $new = substr(str_replace(['+', '/', '='], '', base64_encode(random_bytes(48))), 0, 20);
    } elseif (!preg_match('/^[A-Za-z0-9._~-]{12,128}$/', $new)) {
        manage_fail(400, 'Passwords must be 12-128 characters: letters, digits and . _ ~ -');
    }

    list($code, $output) = manage_run(['/bin/sh', $ctl, 'set-password'], [], $new."\n");

    if ($code !== 0) {
        manage_fail(500, 'The password could not be saved: '.$output);
    }

    manage_json(['password' => $new]);
}

if ($action === 'readonly') {
    $readonly = !empty($_POST['readonly']);

    if (!manage_write_file($settings_file, 'READONLY='.($readonly ? 1 : 0)."\n")) {
        manage_fail(500, 'The setting could not be saved');
    }

    kvweb_restart($ctl);
    manage_json();
}

if ($action === 'restart') {
    kvweb_restart($ctl);
    manage_json();
}

manage_fail(400, 'Unknown action');
