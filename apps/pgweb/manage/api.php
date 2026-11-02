<?php
// pgweb management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('pgweb');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path      = dirname(__DIR__);
$apps_path     = dirname($app_path);
$data_path     = $apps_path.'/_pgweb';
$settings_file = $data_path.'/settings';
$password_file = $data_path.'/password';
$ctl           = $app_path.'/pgweb_ctl.sh';

require $app_path.'/lib/pgweb.php';

/**
 * Where pgweb listens: local - only through the Nginx app; all - on the network too (with pgweb's own login).
 *
 * @param string $file The settings file (KEY=value lines, also read by the app's control script)
 *
 * @return 'all'|'local' The setting
 */
function pgweb_listen(string $file): string
{
    return preg_match('/^LISTEN=all$/m', (string)@file_get_contents($file)) ? 'all' : 'local';
}

/**
 * Saves one setting, keeping the others.
 *
 * @param string     $file  The settings file (KEY=value lines, also read by the app's control script)
 * @param string     $key   The setting (e.g. LISTEN)
 * @param int|string $value Its value
 *
 * @return bool Whether it was saved
 */
function pgweb_save_setting(string $file, string $key, $value): bool
{
    $text = preg_replace('/^'.$key.'=.*\n?/m', '', (string)@file_get_contents($file));

    return manage_write_file($file, rtrim($text, "\n").($text !== '' ? "\n" : '').$key.'='.$value."\n");
}

/**
 * Restarts pgweb with its control script (stop, then start), failing the request if it doesn't start.
 *
 * @param string $ctl The app's control script
 *
 * @return void
 */
function pgweb_restart(string $ctl): void
{
    manage_run(['/bin/sh', $ctl, 'stop']);

    list($code, $output) = manage_run(['/bin/sh', $ctl, 'start']);

    if ($code !== 0) {
        manage_fail(500, 'pgweb could not be started: '.$output);
    }
}

$action = isset($_GET['action']) ? $_GET['action'] : 'status';

if ($action === 'status') {
    $running = manage_pid_running('/var/run/pgweb.pid');

    // pgweb asks for its own login when it's on the network: 401 is pgweb answering too
    list($code) = $running ? manage_http_get(PGWEB_TARGET.'/api/info') : [0];
    list(, $version) = manage_run([$app_path.'/binaries/pgweb', '--version']);

    $log = @file($data_path.'/pgweb.log', FILE_IGNORE_NEW_LINES) ?: [];

    manage_json([
        'running'    => $running,
        'answering'  => $code === 200 || $code === 401,
        'version'    => preg_match('/^Pgweb v(\S+)/', $version, $m) ? $m[1] : '',
        'listen'     => pgweb_listen($settings_file),
        // Whether it asks for the page's password first (AUTH=0: only PostgreSQL's own login, on pgweb's form)
        'auth'       => !preg_match('/^AUTH=0$/m', (string)@file_get_contents($settings_file)),
        'readonly'   => (bool)preg_match('/^READONLY=1$/m', (string)@file_get_contents($settings_file)),
        'site'       => manage_nginx_site($apps_path, PGWEB_TARGET),
        'postgresql' => is_dir($apps_path.'/postgresql'),
        'log'        => array_slice($log, -20),
    ]);
}

manage_require_action('pgweb');

if ($action === 'password') {
    manage_json(['password' => trim((string)@file_get_contents($password_file))]);
}

if ($action === 'set_password') {
    // A new password: the one given (letters, digits and . _ ~ - only, like the other apps), or a random one. Nginx
    // reads the new htpasswd file on the next request; pgweb's own login (on the network) needs a restart
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

    if (pgweb_listen($settings_file) === 'all') {
        pgweb_restart($ctl);
    }

    manage_json(['password' => $new]);
}

if ($action === 'readonly') {
    $readonly = !empty($_POST['readonly']);

    if (!pgweb_save_setting($settings_file, 'READONLY', $readonly ? 1 : 0)) {
        manage_fail(500, 'The setting could not be saved');
    }

    pgweb_restart($ctl);
    manage_json();
}

if ($action === 'auth') {
    $auth = !empty($_POST['auth']);

    if (!pgweb_save_setting($settings_file, 'AUTH', $auth ? 1 : 0)) {
        manage_fail(500, 'The setting could not be saved');
    }

    // Its site in the Nginx app follows (its nginx.json rewritten), and pgweb's own login on the network
    manage_run(['/bin/sh', $ctl, 'nginx']);

    if (pgweb_listen($settings_file) === 'all') {
        pgweb_restart($ctl);
    }

    manage_json();
}

if ($action === 'listen') {
    $listen = isset($_POST['listen']) && $_POST['listen'] === 'all' ? 'all' : 'local';

    if (!pgweb_save_setting($settings_file, 'LISTEN', $listen)) {
        manage_fail(500, 'The setting could not be saved');
    }

    pgweb_restart($ctl);
    manage_json();
}

if ($action === 'restart') {
    pgweb_restart($ctl);
    manage_json();
}

manage_fail(400, 'Unknown action');
