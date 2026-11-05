<?php
// Transmission management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('transmission');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path      = dirname(__DIR__);
$apps_path     = dirname($app_path);
$data_path     = $apps_path.'/_transmission';
$settings_file = $data_path.'/settings';
$ctl           = $app_path.'/tr_ctl.sh';
$target        = 'http://127.0.0.1:9091';

/**
 * The app's settings, with defaults.
 *
 * @param string $file The settings file (KEY=value lines, also read by the app's control script)
 *
 * @return array{ DOWNLOAD_DIR: string, LISTEN: string, PEER_PORT: string, DOWN_LIMIT: string, UP_LIMIT: string }
 */
function tr_settings(string $file): array
{
    $settings = [
        'DOWNLOAD_DIR' => '',
        'LISTEN'       => 'all',
        'PEER_PORT'    => '51413',
        'DOWN_LIMIT'   => '0',
        'UP_LIMIT'     => '0',
    ];

    foreach (@file($file, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
        if (preg_match('/^([A-Z_]+)=(.*)$/', $line, $m) && isset($settings[$m[1]])) {
            $settings[$m[1]] = $m[2];
        }
    }

    return $settings;
}

/**
 * Whether a folder can hold the downloads: one on the NAS's volumes, not the apps' folder (Nas_Prog: apps' data,
 * passwords included) or the volumes' system folders.
 *
 * @param mixed $path The folder
 *
 * @return string '' or the error
 */
function tr_check_path($path): string
{
    if (!is_string($path) || !preg_match('#^/mnt/(HD/HD_[a-z][0-9]+|USB/[^/]+)(/[^\x00-\x1f]*)?$#', $path) || preg_match('#/\.\.?(/|$)#', $path)) {
        return 'The folder must be on the NAS\'s volumes, e.g. /mnt/HD/HD_a2/Public/Downloads';
    }

    if (!is_dir($path)) {
        return 'No such folder: '.$path;
    }

    // Where it really is, symbolic links followed
    $real = realpath($path);

    if ($real === false || !preg_match('#^/mnt/(HD/HD_[a-z][0-9]+|USB/[^/]+)/#', $real)) {
        return 'The folder must be inside one of the NAS\'s shares, e.g. /mnt/HD/HD_a2/Public/Downloads';
    }

    if (preg_match('#^/mnt/HD/HD_[a-z][0-9]+/(Nas_Prog|lost\+found|otaclient|restsdk-data|restsdk-info|\.[^/]*)(/|$)#', $real)) {
        return 'That folder holds the NAS\'s or its apps\' own files';
    }

    return '';
}

/**
 * Runs transmission-remote against the running Transmission, logged in with the app's password (given in its
 * environment, not on its command line).
 *
 * @param string       $app_path  The app's folder
 * @param string       $data_path The app's data folder
 * @param list<string> $args      Its arguments (e.g. -si)
 *
 * @return array{ 0: int, 1: string } [exit code, output]
 */
function tr_remote(string $app_path, string $data_path, array $args): array
{
    $password = trim((string)@file_get_contents($data_path.'/password'));

    return manage_run(
        array_merge([$app_path.'/binaries/bin/transmission-remote', '127.0.0.1:9091', '--authenv'], $args),
        ['TR_AUTH' => 'admin:'.$password]
    );
}

/**
 * Restarts Transmission with its control script, failing the request if it doesn't start.
 *
 * @param string $ctl The app's control script
 *
 * @return void
 */
function tr_restart(string $ctl): void
{
    list($code, $output) = manage_run(['/bin/sh', $ctl, 'restart']);

    if ($code !== 0) {
        manage_fail(500, 'Transmission could not be started: '.$output);
    }
}

$settings = tr_settings($settings_file);
$action   = $_GET['action'] ?? 'status';

if ($action === 'status') {
    $running = manage_pid_running('/var/run/transmission.pid');

    list($code, $info) = $running ? tr_remote($app_path, $data_path, ['-si']) : [1, ''];
    list(, $list)      = $code === 0 ? tr_remote($app_path, $data_path, ['-l']) : [1, ''];

    // The list's rows (ID, done, have, ETA, up, down, ratio, status, name), then its Sum line
    $torrents = max(0, count(array_filter(explode("\n", $list), function ($line) {
        return preg_match('/^\s*\d+\*?\s/', $line) === 1;
    })));
    $sum     = preg_match('/^Sum:\s+\S+(?:\s+\S+)?\s+([\d.]+)\s+([\d.]+)\s*$/m', $list, $m) ? [$m[1], $m[2]] : ['0', '0'];
    $address = preg_match('/ src (\S+)/', manage_run(['ip', '-4', 'route', 'get', '1.1.1.1'])[1], $a) ? $a[1] : '';
    $log     = @file($data_path.'/transmission.log', FILE_IGNORE_NEW_LINES) ?: [];

    manage_json([
        'running'      => $running,
        'answering'    => $code === 0,
        'version'      => preg_match('/Daemon version:\s*(\S+)/', $info, $v) ? $v[1] : '',
        'torrents'     => $torrents,
        'upload'       => $sum[0],
        'download'     => $sum[1],
        'address'      => $address !== '' ? 'http://'.$address.':9091/transmission/web/' : '',
        'site'         => manage_nginx_site($apps_path, $target),
        'download_dir' => $settings['DOWNLOAD_DIR'],
        'listen'       => $settings['LISTEN'] === 'local' ? 'local' : 'all',
        'peer_port'    => (int)$settings['PEER_PORT'],
        'down_limit'   => (int)$settings['DOWN_LIMIT'],
        'up_limit'     => (int)$settings['UP_LIMIT'],
        'log'          => array_slice($log, -20),
    ]);
}

manage_require_action('transmission');

if ($action === 'password') {
    manage_json(['password' => trim((string)@file_get_contents($data_path.'/password'))]);
}

if ($action === 'new_password') {
    list($code, $output) = manage_run(['/bin/sh', $ctl, 'new-password']);

    if ($code !== 0) {
        manage_fail(500, 'A new password could not be made: '.$output);
    }

    tr_restart($ctl);
    manage_json(['password' => trim((string)@file_get_contents($data_path.'/password'))]);
}

if ($action === 'settings') {
    $folder = isset($_POST['download_dir']) ? rtrim(trim((string)$_POST['download_dir']), '/') : '';
    $error  = tr_check_path($folder);

    if ($error !== '') {
        manage_fail(400, $error);
    }

    $port = isset($_POST['peer_port']) ? (string)$_POST['peer_port'] : '';

    if (!preg_match('/^\d{4,5}$/', $port) || (int)$port < 1024 || (int)$port > 65535 || (int)$port === 9091) {
        manage_fail(400, 'The peer port is 1024-65535 (not 9091, the web interface\'s)');
    }

    $limits = [];

    foreach (['down_limit', 'up_limit'] as $name) {
        $value = isset($_POST[$name]) && $_POST[$name] !== '' ? (string)$_POST[$name] : '0';

        if (!preg_match('/^\d{1,7}$/', $value)) {
            manage_fail(400, 'Speed limits are whole numbers of KB/s (0 for none)');
        }

        $limits[$name] = (int)$value;
    }

    $text = 'DOWNLOAD_DIR='.$folder."\n"
        .'LISTEN='.(isset($_POST['listen']) && $_POST['listen'] === 'local' ? 'local' : 'all')."\n"
        .'PEER_PORT='.(int)$port."\n"
        .'DOWN_LIMIT='.$limits['down_limit']."\n"
        .'UP_LIMIT='.$limits['up_limit']."\n";

    if (!manage_write_file($settings_file, $text)) {
        manage_fail(500, 'The settings could not be saved');
    }

    tr_restart($ctl);
    manage_json();
}

if ($action === 'restart') {
    tr_restart($ctl);
    manage_json();
}

manage_fail(400, 'Unknown action');
