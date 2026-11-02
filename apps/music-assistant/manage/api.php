<?php
// Music Assistant management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('music-assistant');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path   = dirname(__DIR__);
$apps_path  = dirname($app_path);
$data_path  = $apps_path.'/_music-assistant';
$backup_dir = $data_path.'/backups';
$ctl        = $app_path.'/ma_ctl.sh';

require $app_path.'/lib/ma.php';

/**
 * One of the secrets Music Assistant's app keeps (root only) in its data folder.
 *
 * @param string $data_path The app's data folder
 * @param string $name      The secret's file (e.g. page_token)
 *
 * @return string It, or ''
 */
function ma_secret(string $data_path, string $name): string
{
    return trim((string)@file_get_contents($data_path.'/'.$name));
}

/**
 * Restarts Music Assistant with its control script (stop, then start), failing the request if it doesn't start.
 *
 * @param string $ctl The app's control script
 *
 * @return void
 */
function ma_restart(string $ctl): void
{
    manage_run(['/bin/sh', $ctl, 'stop']);

    list($code, $output) = manage_run(['/bin/sh', $ctl, 'start']);

    if ($code !== 0) {
        manage_fail(500, 'Music Assistant could not be started: '.$output);
    }
}

/**
 * A command on Music Assistant's API, with the page's own token.
 *
 * @param string               $data_path The app's data folder
 * @param string               $command   The command (e.g. players/all)
 * @param array<string, mixed> $args      Its arguments
 *
 * @return mixed Its result, or null
 */
function ma_command(string $data_path, string $command, array $args = [])
{
    $token = ma_secret($data_path, 'page_token');

    if ($token === '') {
        return null;
    }

    list($code, $body) = manage_http_request(
        'POST',
        MA_TARGET.'/api',
        json_encode(['message_id' => 'page', 'command' => $command, 'args' => (object)$args]),
        5,
        ['Authorization: Bearer '.$token]
    );

    return $code === 200 ? json_decode($body, true) : null;
}

$action = $_GET['action'] ?? 'status';

if ($action === 'status') {
    $running = manage_pid_running('/var/run/music-assistant.pid');

    list($code, $body) = $running ? manage_http_get(MA_TARGET.'/info') : [0, ''];

    $info    = $code === 200 ? json_decode($body, true) : null;
    $players = is_array($info) ? ma_command($data_path, 'players/all') : null;
    $host    = isset($_SERVER['HTTP_HOST']) ? preg_replace('/:\d+$/', '', $_SERVER['HTTP_HOST']) : '';
    $backups = [];

    foreach (glob($backup_dir.'/music-assistant-*.tar.gz') ?: [] as $file) {
        $backups[] = ['name' => basename($file), 'size' => filesize($file), 'time' => filemtime($file)];
    }

    usort($backups, function (array $a, array $b): int {
        return strcmp($b['name'], $a['name']);
    });

    // Its warnings and errors (Music Assistant's own log also has information lines)
    $log = array_values(array_filter(@file($data_path.'/data/musicassistant.log', FILE_IGNORE_NEW_LINES) ?: [],
        function (string $line) { return preg_match('/^\S+ \S+ (WARNING|ERROR|CRITICAL) /', $line); }));

    manage_json([
        'running'   => $running,
        'answering' => is_array($info),
        'version'   => is_array($info) && isset($info['server_version']) ? $info['server_version'] : '',
        'site'      => manage_nginx_site($apps_path, MA_TARGET),
        'local_url' => $host !== '' ? 'http://'.$host.':8095/' : '',
        'has_admin' => ma_secret($data_path, 'admin_password') !== '',
        // null when the page can't use its token (e.g. Music Assistant is starting)
        'players'   => is_array($players) ? array_map(function ($player) {
            return [
                'name'      => $player['display_name'] ?? ($player['name'] ?? '?'),
                'provider'  => $player['provider'] ?? '',
                'available' => !empty($player['available']),
                'state'     => $player['playback_state'] ?? ($player['state'] ?? ''),
            ];
        }, $players) : null,
        'backup_dir' => $backup_dir,
        'backups'    => array_slice($backups, 0, 30),
        'log'        => array_slice($log, -20),
    ]);
}

manage_require_action('music-assistant');

if ($action === 'password') {
    manage_json(['password' => ma_secret($data_path, 'admin_password')]);
}

if ($action === 'new_password') {
    list($code, $output) = manage_run(['/bin/sh', $ctl, 'new-password']);

    if ($code !== 0) {
        manage_fail(500, 'A new password could not be set: '.$output);
    }

    manage_json(['password' => ma_secret($data_path, 'admin_password')]);
}

if ($action === 'backup') {
    list($code, $output) = manage_run(['/bin/sh', $ctl, 'backup']);

    if ($code !== 0) {
        manage_fail(500, 'The backup failed: '.$output);
    }

    manage_json();
}

if ($action === 'restart') {
    ma_restart($ctl);
    manage_json();
}

manage_fail(400, 'Unknown action');
