<?php
// linkding management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('linkding');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path      = dirname(__DIR__);
$apps_path     = dirname($app_path);
$data_path     = $apps_path.'/_linkding';
$settings_file = $data_path.'/settings';
$password_file = $data_path.'/password';
$ctl           = $app_path.'/linkding_ctl.sh';

require $app_path.'/lib/linkding.php';

/**
 * The app's settings, with defaults.
 *
 * @param string $file The settings file (KEY=value lines, also read by the app's control script)
 *
 * @return array{ LISTEN: string, BACKUP_KEEP: string } The settings
 */
function linkding_settings(string $file): array
{
    $settings = [
        'LISTEN'      => 'local',
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
 * Restarts linkding with its control script (stop, then start), failing the request if it doesn't start.
 *
 * @param string $ctl The app's control script
 *
 * @return void
 */
function linkding_restart(string $ctl): void
{
    manage_run(['/bin/sh', $ctl, 'stop']);

    list($code, $output) = manage_run(['/bin/sh', $ctl, 'start']);

    if ($code !== 0) {
        manage_fail(500, 'linkding could not be started: '.$output);
    }
}

/**
 * The backups in Nas_Prog/_linkding/backups, newest first.
 *
 * @param string $data_path The app's data folder
 *
 * @return list<array{ name: string, size: int, time: int }> Each backup's file name, size (bytes) and time (seconds
 *                                                           since 1970)
 */
function linkding_backups(string $data_path): array
{
    $list = [];

    foreach (glob($data_path.'/backups/linkding-*.zip') ?: [] as $file) {
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
function linkding_last_line(string $output): string
{
    $lines = preg_split('/\R/', trim($output)) ?: [];

    return (string)end($lines);
}

$settings = linkding_settings($settings_file);
$action   = $_GET['action'] ?? 'status';

if ($action === 'status') {
    $running = manage_pid_running('/var/run/linkding.pid');

    // Its login page, which it shows to anyone
    list($code, $body) = $running ? manage_http_get(LINKDING_TARGET.'/login/', 5) : [0, ''];

    $version = trim((string)@file_get_contents($app_path.'/binaries/linkding/version.txt'));
    $log     = @file($data_path.'/linkding.log', FILE_IGNORE_NEW_LINES) ?: [];

    manage_json([
        'running'     => $running,
        // Its background worker: favicons, previews, Wayback Machine snapshots
        'worker'      => manage_pid_running('/var/run/linkding-tasks.pid'),
        'answering'   => $code === 200 && stripos($body, 'linkding') !== false,
        'version'     => $version,
        'site'        => manage_nginx_site($apps_path, LINKDING_TARGET),
        'listen'      => $settings['LISTEN'] === 'all' ? 'all' : 'local',
        'backup_keep' => (int)$settings['BACKUP_KEEP'],
        'backups'     => array_slice(linkding_backups($data_path), 0, 5),
        // Its warnings and errors (not every request it serves)
        'log'         => array_values(array_slice(
            preg_grep('/\b(WARNING|ERROR|CRITICAL|Traceback)\b|!!!/', $log) ?: [],
            -20
        )),
    ]);
}

manage_require_action('linkding');

if ($action === 'password') {
    manage_json(['password' => trim((string)@file_get_contents($password_file))]);
}

if ($action === 'set_password') {
    // A new password: the one given (any visible characters, spaces and symbols included), or a random one - in use
    // at once
    $new = manage_new_password(isset($_POST['password']) ? (string)$_POST['password'] : '');

    list($code, $output) = manage_run(['/bin/sh', $ctl, 'set-password'], [], $new."\n");

    if ($code !== 0) {
        manage_fail(500, 'The password could not be saved: '.linkding_last_line($output));
    }

    manage_json(['password' => $new]);
}

if ($action === 'settings') {
    $keep = isset($_POST['backup_keep']) ? (string)$_POST['backup_keep'] : '';

    if (!preg_match('/^[0-9]{1,2}$/', $keep) || (int)$keep < 1) {
        manage_fail(400, 'Keep 1 to 99 backups');
    }

    $text = 'LISTEN='.(isset($_POST['listen']) && $_POST['listen'] === 'all' ? 'all' : 'local')."\n"
        .'BACKUP_KEEP='.(int)$keep."\n";

    if (!manage_write_file($settings_file, $text)) {
        manage_fail(500, 'The settings could not be saved');
    }

    linkding_restart($ctl);
    manage_json();
}

if ($action === 'backup') {
    list($code, $output) = manage_run(['/bin/sh', $ctl, 'backup']);

    if ($code !== 0) {
        manage_fail(500, 'The backup failed: '.linkding_last_line($output));
    }

    manage_json(['backups' => array_slice(linkding_backups($data_path), 0, 5)]);
}

if ($action === 'restart') {
    linkding_restart($ctl);
    manage_json();
}

manage_fail(400, 'Unknown action');
