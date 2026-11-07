<?php
// qBittorrent management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('qbittorrent');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path      = dirname(__DIR__);
$apps_path     = dirname($app_path);
$data_path     = $apps_path.'/_qbittorrent';
$settings_file = $data_path.'/settings';
$ctl           = $app_path.'/qbt_ctl.sh';

require $app_path.'/lib/qbt.php';

$target = 'http://127.0.0.1:'.QBT_PORT;

/**
 * Whether a folder can hold the downloads: one on the NAS's volumes, not the apps' folder (Nas_Prog: apps' data,
 * passwords included) or the volumes' system folders.
 *
 * @param mixed $path The folder
 *
 * @return string '' or the error
 */
function qbt_check_path($path): string
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
 * Restarts qBittorrent with its control script, failing the request if it doesn't start.
 *
 * @param string $ctl The app's control script
 *
 * @return void
 */
function qbt_restart(string $ctl): void
{
    list($code, $output) = manage_run(['/bin/sh', $ctl, 'restart']);

    if ($code !== 0) {
        manage_fail(500, 'qBittorrent could not be started: '.$output);
    }
}

$settings = qbt_settings($settings_file);
$action   = $_GET['action'] ?? 'status';

if ($action === 'status') {
    $running  = manage_pid_running('/var/run/qbittorrent.pid');
    $version  = $running ? qbt_api($data_path, 'app/version') : [0, ''];
    $transfer = $version[0] === 200 ? json_decode(qbt_api($data_path, 'transfer/info')[1], true) : null;
    $torrents = $version[0] === 200 ? json_decode(qbt_api($data_path, 'torrents/info')[1], true) : null;
    $address  = preg_match('/ src (\S+)/', manage_run(['ip', '-4', 'route', 'get', '1.1.1.1'])[1], $a) ? $a[1] : '';
    $log      = @file($data_path.'/logs/qbittorrent.log', FILE_IGNORE_NEW_LINES) ?: [];

    // Speeds in kB/s (1000 bytes)
    $speed = function (string $key) use ($transfer): string {
        return (string)round((int)($transfer[$key] ?? 0) / 1000, 1);
    };

    manage_json([
        'running'      => $running,
        'answering'    => $version[0] === 200,
        'version'      => ltrim(trim($version[1]), 'v'),
        'torrents'     => is_array($torrents) ? count($torrents) : 0,
        'upload'       => $speed('up_info_speed'),
        'download'     => $speed('dl_info_speed'),
        'address'      => $address !== '' ? 'http://'.$address.':'.QBT_PORT.'/' : '',
        'site'         => manage_nginx_site($apps_path, $target),
        'download_dir' => $settings['DOWNLOAD_DIR'],
        'listen'       => $settings['LISTEN'] === 'local' ? 'local' : 'all',
        'peer_port'    => (int)$settings['PEER_PORT'],
        'down_limit'   => (int)$settings['DOWN_LIMIT'],
        'up_limit'     => (int)$settings['UP_LIMIT'],
        'log'          => array_slice($log, -20),
    ]);
}

manage_require_action('qbittorrent');

if ($action === 'password') {
    manage_json(['password' => trim((string)@file_get_contents($data_path.'/password'))]);
}

if ($action === 'new_password') {
    list($code, $output) = manage_run(['/bin/sh', $ctl, 'new-password']);

    if ($code !== 0) {
        manage_fail(500, 'A new password could not be made: '.$output);
    }

    qbt_restart($ctl);
    manage_json(['password' => trim((string)@file_get_contents($data_path.'/password'))]);
}

if ($action === 'settings') {
    $folder = isset($_POST['download_dir']) ? rtrim(trim((string)$_POST['download_dir']), '/') : '';
    $error  = qbt_check_path($folder);

    if ($error !== '') {
        manage_fail(400, $error);
    }

    $port = isset($_POST['peer_port']) ? (string)$_POST['peer_port'] : '';

    if (!preg_match('/^\d{4,5}$/', $port) || (int)$port < 1024 || (int)$port > 65535 || (int)$port === QBT_PORT) {
        manage_fail(400, 'The peer port is 1024-65535 (not '.QBT_PORT.', the web interface\'s)');
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

    qbt_restart($ctl);
    manage_json();
}

if ($action === 'restart') {
    qbt_restart($ctl);
    manage_json();
}

manage_fail(400, 'Unknown action');
