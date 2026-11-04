<?php
// Bugsink management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('bugsink');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path      = dirname(__DIR__);
$apps_path     = dirname($app_path);
$data_path     = $apps_path.'/_bugsink';
$settings_file = $data_path.'/settings';
$password_file = $data_path.'/password';
$ctl           = $app_path.'/bugsink_ctl.sh';
$target        = 'http://127.0.0.1:8000';

/**
 * Where Bugsink listens: local - only through the Nginx app; all - on the network too.
 *
 * @param string $file The settings file (KEY=value lines, also read by the app's control script)
 *
 * @return 'all'|'local' The setting
 */
function bugsink_listen(string $file): string
{
    return preg_match('/^LISTEN=all$/m', (string)@file_get_contents($file)) ? 'all' : 'local';
}

/**
 * Restarts Bugsink with its control script (stop, then start), failing the request if it doesn't start.
 *
 * @param string $ctl The app's control script
 *
 * @return void
 */
function bugsink_restart(string $ctl): void
{
    manage_run(['/bin/sh', $ctl, 'stop']);

    list($code, $output) = manage_run(['/bin/sh', $ctl, 'start']);

    if ($code !== 0) {
        manage_fail(500, 'Bugsink could not be started: '.$output);
    }
}

$action = isset($_GET['action']) ? $_GET['action'] : 'status';

if ($action === 'status') {
    $running = manage_pid_running('/var/run/bugsink.pid');

    // Its login page, which it shows to anyone
    list($code, $body) = $running ? manage_http_get($target.'/accounts/login/', 5) : [0, ''];

    $dist = glob($app_path.'/binaries/python/lib/python3*/site-packages/bugsink-*.dist-info') ?: [];
    $conf = (string)@file_get_contents($data_path.'/conf/bugsink_conf.py');
    $log  = @file($data_path.'/bugsink.log', FILE_IGNORE_NEW_LINES) ?: [];

    manage_json([
        'running'   => $running,
        // Its background worker, which turns the events it takes in into issues
        'worker'    => manage_pid_running('/var/run/bugsink-snappea.pid'),
        'answering' => $code === 200 && strpos($body, 'Bugsink') !== false,
        'version'   => $dist && preg_match('/bugsink-([^\/]+)\.dist-info$/', $dist[0], $m) ? $m[1] : '',
        'listen'    => bugsink_listen($settings_file),
        'site'      => manage_nginx_site($apps_path, $target),
        // The address it's using (in the DSNs it gives other programs): set at its last start
        'base_url'  => preg_match('/"BASE_URL": "([^"]*)"/', $conf, $m) ? $m[1] : '',
        // Its warnings and errors
        'log'       => array_values(array_slice(preg_grep('/\b(WARNING|ERROR|CRITICAL|Traceback)\b/', $log), -20)),
    ]);
}

manage_require_action('bugsink');

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

    manage_json(['password' => $new]);
}

if ($action === 'listen') {
    $listen = isset($_POST['listen']) && $_POST['listen'] === 'all' ? 'all' : 'local';
    $text   = preg_replace('/^LISTEN=.*\n?/m', '', (string)@file_get_contents($settings_file));

    if (!manage_write_file($settings_file, rtrim($text, "\n").($text !== '' ? "\n" : '').'LISTEN='.$listen."\n")) {
        manage_fail(500, 'The setting could not be saved');
    }

    bugsink_restart($ctl);
    manage_json();
}

if ($action === 'restart') {
    bugsink_restart($ctl);
    manage_json();
}

manage_fail(400, 'Unknown action');
