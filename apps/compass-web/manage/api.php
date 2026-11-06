<?php
// Compass Web management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('compass-web');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path      = dirname(__DIR__);
$apps_path     = dirname($app_path);
$data_path     = $apps_path.'/_compass-web';
$settings_file = $data_path.'/settings';
$password_file = $data_path.'/password';
$ctl           = $app_path.'/cw_ctl.sh';
$target        = 'http://127.0.0.1:8087';

/**
 * Where Compass Web listens: local - only through the Nginx app; all - on the network too.
 *
 * @param string $file The settings file (KEY=value lines, also read by the app's control script)
 *
 * @return 'all'|'local' The setting
 */
function cw_listen(string $file): string
{
    return preg_match('/^LISTEN=all$/m', (string)@file_get_contents($file)) ? 'all' : 'local';
}

/**
 * Restarts Compass Web with its control script (stop, then start), failing the request if it doesn't start.
 *
 * @param string $ctl The app's control script
 *
 * @return void
 */
function cw_restart(string $ctl): void
{
    manage_run(['/bin/sh', $ctl, 'stop']);

    list($code, $output) = manage_run(['/bin/sh', $ctl, 'start']);

    if ($code !== 0) {
        manage_fail(500, 'Compass Web could not be started: '.$output);
    }
}

$action = isset($_GET['action']) ? $_GET['action'] : 'status';

if ($action === 'status') {
    $running = manage_pid_running('/var/run/compass-web.pid');

    // Its health check, which needs no login
    list($code) = $running ? manage_http_get($target.'/healthz', 5) : [0];

    $package = json_decode((string)@file_get_contents($app_path.'/binaries/compass-web/node_modules/compass-web/package.json'), true);
    $log     = @file($data_path.'/compass-web.log', FILE_IGNORE_NEW_LINES) ?: [];

    manage_json([
        'running'   => $running,
        'answering' => $code === 200,
        'version'   => is_array($package) && isset($package['version']) ? $package['version'] : '',
        'mongodb'   => is_file($apps_path.'/_mongodb/password'),
        'listen'    => cw_listen($settings_file),
        'site'      => manage_nginx_site($apps_path, $target),
        // Its warnings and errors (its log has one JSON document per line: level 40 and above)
        'log'       => array_values(array_slice(preg_grep('/"level":(4|5|6)0/', $log), -20)),
    ]);
}

manage_require_action('compass-web');

if ($action === 'password') {
    manage_json(['password' => trim((string)@file_get_contents($password_file))]);
}

if ($action === 'set_password') {
    // A new password: the one given (letters, digits and . _ ~ - only, like the other apps), or a random one - in use
    // at once
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

    // Compass Web reads it when it starts
    cw_restart($ctl);
    manage_json(['password' => $new]);
}

if ($action === 'listen') {
    $listen = isset($_POST['listen']) && $_POST['listen'] === 'all' ? 'all' : 'local';
    $text   = preg_replace('/^LISTEN=.*\n?/m', '', (string)@file_get_contents($settings_file));

    if (!manage_write_file($settings_file, rtrim($text, "\n").($text !== '' ? "\n" : '').'LISTEN='.$listen."\n")) {
        manage_fail(500, 'The setting could not be saved');
    }

    cw_restart($ctl);
    manage_json();
}

if ($action === 'restart') {
    cw_restart($ctl);
    manage_json();
}

manage_fail(400, 'Unknown action');
