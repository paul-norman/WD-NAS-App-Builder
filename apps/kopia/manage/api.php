<?php
// Kopia management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('kopia');

// Manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path      = dirname(__DIR__);
$apps_path     = dirname($app_path);
$data_path     = $apps_path.'/_kopia';
$settings_file = $data_path.'/settings';
$password_file = $data_path.'/server_password';
$ctl           = $app_path.'/kopia_ctl.sh';

require $app_path.'/lib/kopia.php';

/**
 * Where Kopia listens: local (only through the Nginx app) or all.
 *
 * @param string $file The settings file (KEY=value lines, also read by the app's control script)
 *
 * @return 'all'|'local' The setting
 */
function kopia_listen(string $file): string
{
    return preg_match('/^LISTEN=local$/m', (string)@file_get_contents($file)) ? 'local' : 'all';
}

/**
 * Restarts Kopia with its control script (stop, then start), failing the request if it doesn't start.
 *
 * @param string $ctl The app's control script
 *
 * @return void
 */
function kopia_restart(string $ctl): void
{
    manage_run(['/bin/sh', $ctl, 'stop']);

    list($code, $output) = manage_run(['/bin/sh', $ctl, 'start']);

    if ($code !== 0) {
        manage_fail(500, 'Kopia could not be started: '.$output);
    }
}

$action = $_GET['action'] ?? 'status';

if ($action === 'status') {
    $running = manage_pid_running('/var/run/kopia.pid');

    list($code)      = $running ? manage_http_get(KOPIA_TARGET.'/') : [0];
    list(, $version) = manage_run([$app_path.'/binaries/kopia', '--version']);

    // The repository and the backup sources, from Kopia itself
    $repo    = null;
    $sources = [];

    if ($code === 401) {
        $api    = kopia_api(trim((string)@file_get_contents($password_file)), ['/api/v1/repo/status', '/api/v1/sources']);
        $status = $api['/api/v1/repo/status'] ?? null;

        if (is_array($status)) {
            $repo = [
                'connected'   => !empty($status['connected']),
                'description' => $status['description'] ?? '',
                'storage'     => $status['storage'] ?? '',
            ];
        }

        $list = $api['/api/v1/sources']['sources'] ?? [];

        foreach ($list as $source) {
            $last      = $source['lastSnapshot'] ?? null;
            $sources[] = [
                'path'   => $source['source']['path'] ?? '',
                'status' => $source['status'] ?? '',
                'last'   => $last && isset($last['endTime']) ? $last['endTime'] : '',
                'size'   => $last && isset($last['stats']['totalSize']) ? (int)$last['stats']['totalSize'] : null,
                'errors' => $last && isset($last['stats']['errorCount']) ? (int)$last['stats']['errorCount'] : 0,
                'next'   => $source['nextSnapshotTime'] ?? '',
            ];
        }
    }

    $log = @file($data_path.'/kopia.log', FILE_IGNORE_NEW_LINES) ?: [];

    manage_json([
        'running'   => $running,
        'answering' => $code === 401,
        'version'   => preg_match('/^(\S+)/', $version, $m) ? $m[1] : '',
        'listen'    => kopia_listen($settings_file),
        'site'      => manage_nginx_site($apps_path, KOPIA_TARGET),
        'repo'      => $repo,
        'sources'   => $sources,
        'log'       => array_slice($log, -20),
    ]);
}

manage_require_action('kopia');

if ($action === 'password') {
    manage_json(['password' => trim((string)@file_get_contents($password_file))]);
}

if ($action === 'new_password') {
    list($code, $output) = manage_run(['/bin/sh', $ctl, 'new-password']);

    if ($code !== 0) {
        manage_fail(500, 'A new password could not be made: '.$output);
    }

    kopia_restart($ctl);
    manage_json(['password' => trim((string)@file_get_contents($password_file))]);
}

if ($action === 'listen') {
    $listen = isset($_POST['listen']) && $_POST['listen'] === 'local' ? 'local' : 'all';

    if (!manage_write_file($settings_file, 'LISTEN='.$listen."\n")) {
        manage_fail(500, 'The setting could not be saved');
    }

    kopia_restart($ctl);
    manage_json();
}

if ($action === 'restart') {
    kopia_restart($ctl);
    manage_json();
}

manage_fail(400, 'Unknown action');
