<?php
// RetroAssembly management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('retroassembly');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path      = dirname(__DIR__);
$apps_path     = dirname($app_path);
$data_path     = $apps_path.'/_retroassembly';
$settings_file = $data_path.'/settings';
$ctl           = $app_path.'/retroassembly_ctl.sh';

require $app_path.'/lib/retroassembly.php';

/**
 * The app's settings, with defaults.
 *
 * @param string $file The settings file (KEY=value lines, also read by the app's control script)
 *
 * @return array{ LISTEN: string, SIGNUPS: string, BACKUP_KEEP: string } The settings
 */
function retroassembly_settings(string $file): array
{
    $settings = [
        'LISTEN'      => 'local',
        'SIGNUPS'     => 'off',
        'BACKUP_KEEP' => '14',
    ];

    foreach (@file($file, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
        if (preg_match('/^([A-Z_]+)=(.*)$/', $line, $m) && isset($settings[$m[1]])) {
            $settings[$m[1]] = $m[2];
        }
    }

    return $settings;
}

/**
 * Restarts RetroAssembly with its control script (stop, then start), failing the request if it doesn't start.
 *
 * @param string $ctl The app's control script
 *
 * @return void
 */
function retroassembly_restart(string $ctl): void
{
    manage_run(['/bin/sh', $ctl, 'stop']);

    list($code, $output) = manage_run(['/bin/sh', $ctl, 'start']);

    if ($code !== 0) {
        manage_fail(500, 'RetroAssembly could not be started: '.$output);
    }
}

/**
 * The backups in Nas_Prog/_retroassembly/backups, newest first.
 *
 * @param string $data_path The app's data folder
 *
 * @return list<array{ name: string, size: int, time: int }> Each backup's file name, size (bytes) and time (seconds
 *                                                           since 1970)
 */
function retroassembly_backups(string $data_path): array
{
    $list = [];

    foreach (glob($data_path.'/backups/retroassembly-*.tar.gz') ?: [] as $file) {
        $list[] = ['name' => basename($file), 'size' => (int)filesize($file), 'time' => (int)filemtime($file)];
    }

    usort($list, function (array $a, array $b): int {
        return strcmp($b['name'], $a['name']);
    });

    return $list;
}

/**
 * The last line of a command's output (its message, without what came before it).
 *
 * @param string $output The output
 *
 * @return string The line
 */
function retroassembly_last_line(string $output): string
{
    $lines = preg_split('/\R/', trim($output)) ?: [];

    return (string)end($lines);
}

$settings = retroassembly_settings($settings_file);
$action   = $_GET['action'] ?? 'status';

if ($action === 'status') {
    $running = manage_pid_running('/var/run/retroassembly.pid');

    list($code, $body) = $running ? manage_http_get(RETROASSEMBLY_TARGET.'/login') : [0, ''];

    // Its version: the app's (RetroAssembly reports none of its own), without the app's packaging revision
    $rc      = (string)@file_get_contents($app_path.'/apkg.rc');
    $version = preg_match('/^Version:\s*(\S+)/m', $rc, $m) ? (string)preg_replace('/-[0-9]+$/', '', $m[1]) : '';
    $log     = @file($data_path.'/retroassembly.log', FILE_IGNORE_NEW_LINES) ?: [];

    manage_json([
        'running'     => $running,
        'answering'   => $code === 200 && strpos($body, 'RetroAssembly') !== false,
        'version'     => $version,
        'site'        => manage_nginx_site($apps_path, RETROASSEMBLY_TARGET),
        'admin'       => 'admin',
        'listen'      => $settings['LISTEN'] === 'all' ? 'all' : 'local',
        'signups'     => $settings['SIGNUPS'] === 'on',
        'backup_keep' => (int)$settings['BACKUP_KEEP'],
        'backups'     => array_slice(retroassembly_backups($data_path), 0, 5),
        // (Without its terminal colours)
        'log'         => array_map(function (string $line): string {
            return (string)preg_replace('/\e\[[0-9;]*m/', '', $line);
        }, array_slice($log, -20)),
    ]);
}

manage_require_action('retroassembly');

if ($action === 'password') {
    manage_json(['password' => trim((string)@file_get_contents($data_path.'/admin_password'))]);
}

if ($action === 'new_password') {
    list($code, $output) = manage_run(['/bin/sh', $ctl, 'new-password']);

    if ($code !== 0) {
        manage_fail(500, 'A new password could not be set: '.retroassembly_last_line($output));
    }

    manage_json(['password' => trim((string)@file_get_contents($data_path.'/admin_password'))]);
}

if ($action === 'settings') {
    $keep = isset($_POST['backup_keep']) ? (string)$_POST['backup_keep'] : '';

    if (!preg_match('/^[0-9]{1,2}$/', $keep) || (int)$keep < 1) {
        manage_fail(400, 'Keep 1 to 99 backups');
    }

    $text = 'LISTEN='.(isset($_POST['listen']) && $_POST['listen'] === 'all' ? 'all' : 'local')."\n"
        .'SIGNUPS='.(isset($_POST['signups']) && $_POST['signups'] === 'on' ? 'on' : 'off')."\n"
        .'BACKUP_KEEP='.(int)$keep."\n";

    if (!manage_write_file($settings_file, $text)) {
        manage_fail(500, 'The settings could not be saved');
    }

    retroassembly_restart($ctl);
    manage_json();
}

if ($action === 'backup') {
    list($code, $output) = manage_run(['/bin/sh', $ctl, 'backup']);

    if ($code !== 0) {
        manage_fail(500, 'The backup failed: '.retroassembly_last_line($output));
    }

    manage_json(['backups' => array_slice(retroassembly_backups($data_path), 0, 5)]);
}

if ($action === 'restart') {
    retroassembly_restart($ctl);
    manage_json();
}

manage_fail(400, 'Unknown action');
