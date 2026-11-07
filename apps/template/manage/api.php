<?php
// The template app's management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('template');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path      = dirname(__DIR__);
$apps_path     = dirname($app_path);
$data_path     = $apps_path.'/_template';
$settings_file = $data_path.'/settings';
$ctl           = $app_path.'/template_ctl.sh';
// Its address on the NAS itself (also in its nginx.json, for the Nginx app)
$target        = 'http://127.0.0.1:8090';

/**
 * Where it listens: local - only through the Nginx app; all - on the network too.
 *
 * @param string $file The settings file (KEY=value lines, also read by the app's control script)
 *
 * @return 'all'|'local' The setting
 */
function template_listen(string $file): string
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
function template_save_setting(string $file, string $key, $value): bool
{
    $text = preg_replace('/^'.$key.'=.*\n?/m', '', (string)@file_get_contents($file));

    return manage_write_file($file, rtrim($text, "\n").($text !== '' ? "\n" : '').$key.'='.$value."\n");
}

/**
 * Restarts it with its control script (stop, then start), failing the request if it doesn't start.
 *
 * @param string $ctl The app's control script
 *
 * @return void
 */
function template_restart(string $ctl): void
{
    manage_run(['/bin/sh', $ctl, 'stop']);

    list($code, $output) = manage_run(['/bin/sh', $ctl, 'start']);

    if ($code !== 0) {
        manage_fail(500, 'Template could not be started: '.$output);
    }
}

$action = isset($_GET['action']) ? $_GET['action'] : 'status';

if ($action === 'status') {
    $running = manage_pid_running('/var/run/template.pid');

    list($code)      = $running ? manage_http_get($target.'/') : [0];
    list(, $version) = manage_run([$app_path.'/binaries/miniserve', '--version']);

    $log = @file($data_path.'/template.log', FILE_IGNORE_NEW_LINES) ?: [];

    manage_json([
        'running'   => $running,
        'answering' => $code === 200,
        'version'   => preg_match('/^miniserve (\S+)/', $version, $m) ? $m[1] : '',
        'listen'    => template_listen($settings_file),
        'site'      => manage_nginx_site($apps_path, $target),
        'log'       => array_slice($log, -20),
    ]);
}

// Everything else changes something: a POST with the page's CSRF token
manage_require_action('template');

if ($action === 'listen') {
    $listen = isset($_POST['listen']) && $_POST['listen'] === 'all' ? 'all' : 'local';

    if (!template_save_setting($settings_file, 'LISTEN', $listen)) {
        manage_fail(500, 'The setting could not be saved');
    }

    template_restart($ctl);
    manage_json();
}

if ($action === 'restart') {
    template_restart($ctl);
    manage_json();
}

manage_fail(400, 'Unknown action');
