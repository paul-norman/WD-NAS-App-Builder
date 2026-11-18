<?php
// Radicale management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('radicale');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path      = dirname(__DIR__);
$apps_path     = dirname($app_path);
$data_path     = $apps_path.'/_radicale';
$settings_file = $data_path.'/settings';
$users_file    = $data_path.'/users';
$ctl           = $app_path.'/radicale_ctl.sh';
$target        = 'http://127.0.0.1:5232';

/**
 * Where Radicale listens: local - only through the Nginx app; all - on the network too.
 *
 * @param string $file The settings file (KEY=value lines, also read by the app's control script)
 *
 * @return 'all'|'local' The setting
 */
function radicale_listen(string $file): string
{
    return preg_match('/^LISTEN=all$/m', (string)@file_get_contents($file)) ? 'all' : 'local';
}

/**
 * Radicale's users, from its users file (name:hash lines).
 *
 * @param string $file The users file
 *
 * @return array<string, string> Each user's password hash, by name, in the file's order
 */
function radicale_users(string $file): array
{
    $users = [];

    foreach (@file($file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [] as $line) {
        $parts = explode(':', $line, 2);

        if (count($parts) === 2 && $parts[0] !== '') {
            $users[$parts[0]] = $parts[1];
        }
    }

    return $users;
}

/**
 * Writes Radicale's users file (which Radicale reads again by itself), readable by Radicale's group, then has the app
 * give new users their folders and the Family links - failing the request if it can't.
 *
 * @param string                $file  The users file
 * @param array<string, string> $users Each user's password hash, by name
 * @param string                $ctl   The app's control script
 *
 * @return void
 */
function radicale_save_users(string $file, array $users, string $ctl): void
{
    $text = '';

    foreach ($users as $name => $hash) {
        $text .= $name.':'.$hash."\n";
    }

    if (!manage_write_file($file, $text) || !@chgrp($file, 'radicale') || !@chmod($file, 0640)) {
        manage_fail(500, 'The users could not be saved');
    }

    list($code, $output) = manage_run(['/bin/sh', $ctl, 'users']);

    if ($code !== 0) {
        manage_fail(500, 'The users\' folders could not be prepared: '.$output);
    }
}

/**
 * A password's SHA-512 crypt hash ($6$, as Radicale's htpasswd checks - PHP's own, on both PHP 7.4 and 8.5).
 *
 * @param string $password The password
 *
 * @return string The hash
 */
function radicale_hash(string $password): string
{
    $salt = substr(strtr(base64_encode(random_bytes(12)), '+', '.'), 0, 16);
    $hash = crypt($password, '$6$rounds=5000$'.$salt.'$');

    if (strpos($hash, '$6$') !== 0) {
        manage_fail(500, 'The password could not be hashed');
    }

    return $hash;
}

/**
 * Restarts Radicale with its control script (stop, then start), failing the request if it doesn't start.
 *
 * @param string $ctl The app's control script
 *
 * @return void
 */
function radicale_restart(string $ctl): void
{
    manage_run(['/bin/sh', $ctl, 'stop']);

    list($code, $output) = manage_run(['/bin/sh', $ctl, 'start']);

    if ($code !== 0) {
        manage_fail(500, 'Radicale could not be started: '.$output);
    }
}

$action = isset($_GET['action']) ? $_GET['action'] : 'status';

if ($action === 'status') {
    $running = manage_pid_running('/var/run/radicale.pid');

    // Its web interface, which it shows to anyone (logging in there)
    list($code, $body) = $running ? manage_http_get($target.'/.web/', 5) : [0, ''];

    $log = @file($data_path.'/radicale.out', FILE_IGNORE_NEW_LINES) ?: [];

    manage_json([
        'running'   => $running,
        'answering' => $code === 200 && strpos($body, 'Radicale') !== false,
        'version'   => trim((string)@file_get_contents($app_path.'/binaries/version')),
        'listen'    => radicale_listen($settings_file),
        'site'      => manage_nginx_site($apps_path, $target),
        'users'     => array_keys(radicale_users($users_file)),
        // Its warnings and errors (it logs nothing else)
        'log'       => array_values(array_slice(preg_grep('/\[(WARNING|ERROR|CRITICAL)\]/', $log), -20)),
    ]);
}

manage_require_action('radicale');

$name  = isset($_POST['name']) ? trim((string)$_POST['name']) : '';
$users = radicale_users($users_file);

if ($action === 'add_user' || $action === 'new_password') {
    if ($action === 'add_user') {
        // (family is the shared collections' folder)
        if (!preg_match('/^[a-z0-9][a-z0-9._-]{0,31}$/', $name) || $name === 'family') {
            manage_fail(400, 'User names are up to 32 lower-case letters, digits, dots, dashes and underscores (starting with a letter or digit), and not "family"');
        }

        if (isset($users[$name])) {
            manage_fail(400, 'There\'s already a user called '.$name);
        }
    } elseif (!isset($users[$name])) {
        manage_fail(404, 'No such user: '.$name);
    }

    // Only its hash is kept: the page shows the password this once
    $password     = manage_new_password(isset($_POST['password']) ? (string)$_POST['password'] : '');
    $users[$name] = radicale_hash($password);

    radicale_save_users($users_file, $users, $ctl);
    manage_json(['name' => $name, 'password' => $password]);
}

if ($action === 'remove_user') {
    if (!isset($users[$name])) {
        manage_fail(404, 'No such user: '.$name);
    }

    // Their calendars and contacts stay (in _radicale/collections), for a user added again with the same name
    unset($users[$name]);

    radicale_save_users($users_file, $users, $ctl);
    manage_json();
}

if ($action === 'listen') {
    $listen = isset($_POST['listen']) && $_POST['listen'] === 'all' ? 'all' : 'local';
    $text   = preg_replace('/^LISTEN=.*\n?/m', '', (string)@file_get_contents($settings_file));

    if (!manage_write_file($settings_file, rtrim($text, "\n").($text !== '' ? "\n" : '').'LISTEN='.$listen."\n")) {
        manage_fail(500, 'The setting could not be saved');
    }

    radicale_restart($ctl);
    manage_json();
}

if ($action === 'restart') {
    radicale_restart($ctl);
    manage_json();
}

manage_fail(400, 'Unknown action');
