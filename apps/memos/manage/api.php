<?php
// Memos management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('memos');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path      = dirname(__DIR__);
$apps_path     = dirname($app_path);
$data_path     = $apps_path.'/_memos';
$settings_file = $data_path.'/settings';
$ctl           = $app_path.'/memos_ctl.sh';

require $app_path.'/lib/memos.php';

/**
 * The app's settings, with defaults.
 *
 * @param string $file The settings file (KEY=value lines, also read by the app's control script)
 *
 * @return array{ LISTEN: string, BACKUP_KEEP: string } The settings
 */
function memos_settings(string $file): array
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
 * Restarts Memos with its control script (stop, then start), failing the request if it doesn't start.
 *
 * @param string $ctl The app's control script
 *
 * @return void
 */
function memos_restart(string $ctl): void
{
    manage_run(['/bin/sh', $ctl, 'stop']);

    list($code, $output) = manage_run(['/bin/sh', $ctl, 'start']);

    if ($code !== 0) {
        manage_fail(500, 'Memos could not be started: '.$output);
    }
}

/**
 * The backups in Nas_Prog/_memos/backups, newest first.
 *
 * @param string $data_path The app's data folder
 *
 * @return list<array{ name: string, size: int, time: int }> Each backup's file name, size (bytes) and time (seconds
 *                                                           since 1970)
 */
function memos_backups(string $data_path): array
{
    $list = [];

    foreach (glob($data_path.'/backups/memos-*.tar.gz') ?: [] as $file) {
        $list[] = ['name' => basename($file), 'size' => (int)filesize($file), 'time' => (int)filemtime($file)];
    }

    usort($list, function (array $a, array $b): int {
        return strcmp($b['name'], $a['name']);
    });

    return $list;
}

$settings = memos_settings($settings_file);
$action   = $_GET['action'] ?? 'status';

if ($action === 'status') {
    $running = manage_pid_running('/var/run/memos.pid');

    list($code, $body) = $running ? manage_http_get(MEMOS_TARGET.'/api/instance/profile') : [0, ''];

    // Its version and the address it runs with (set when it started - its links use it)
    $profile = $code === 200 ? json_decode($body, true) : null;
    $address = is_array($profile) ? (string)($profile['instanceUrl'] ?? '') : '';
    $site    = manage_nginx_site($apps_path, MEMOS_TARGET);
    $log     = @file($data_path.'/memos.log', FILE_IGNORE_NEW_LINES) ?: [];

    manage_json([
        'running'        => $running,
        'answering'      => is_array($profile),
        'version'        => is_array($profile) ? (string)($profile['version'] ?? '') : '',
        'address'        => $address,
        'site'           => $site,
        // The Nginx app's address changed since Memos started (it uses it for its links)
        'restart_needed' => $address !== '' && $site['url'] !== '' && rtrim($site['url'], '/') !== rtrim($address, '/'),
        'listen'         => $settings['LISTEN'] === 'all' ? 'all' : 'local',
        'backup_keep'    => (int)$settings['BACKUP_KEEP'],
        'backups'        => array_slice(memos_backups($data_path), 0, 5),
        'log'            => array_slice($log, -20),
    ]);
}

manage_require_action('memos');

if ($action === 'password') {
    manage_json(['password' => trim((string)@file_get_contents($data_path.'/admin_password'))]);
}

if ($action === 'new_password') {
    list($code, $output) = manage_run(['/bin/sh', $ctl, 'new-password']);

    if ($code !== 0) {
        manage_fail(500, 'A new password could not be made: '.$output);
    }

    memos_restart($ctl);
    manage_json(['password' => trim((string)@file_get_contents($data_path.'/admin_password'))]);
}

if ($action === 'settings') {
    $keep = isset($_POST['backup_keep']) ? (string)$_POST['backup_keep'] : '';

    if (!preg_match('/^[0-9]{1,2}$/', $keep) || (int)$keep < 1) {
        manage_fail(400, 'Keep 1 to 99 backups');
    }

    $text = 'LISTEN='.(isset($_POST['listen']) && $_POST['listen'] === 'all' ? 'all' : 'local')."\n".'BACKUP_KEEP='.(int)$keep."\n";

    if (!manage_write_file($settings_file, $text)) {
        manage_fail(500, 'The settings could not be saved');
    }

    memos_restart($ctl);
    manage_json();
}

if ($action === 'backup') {
    list($code, $output) = manage_run(['/bin/sh', $ctl, 'backup']);

    if ($code !== 0) {
        manage_fail(500, 'The backup failed: '.$output);
    }

    manage_json(['backups' => array_slice(memos_backups($data_path), 0, 5)]);
}

if ($action === 'restart') {
    memos_restart($ctl);
    manage_json();
}

manage_fail(400, 'Unknown action');
