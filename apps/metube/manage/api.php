<?php
// MeTube management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('metube');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path      = dirname(__DIR__);
$apps_path     = dirname($app_path);
$data_path     = $apps_path.'/_metube';
$settings_file = $data_path.'/settings.json';
$users_file    = $data_path.'/users.json';
$ctl           = $app_path.'/metube_ctl.sh';

require $app_path.'/lib/metube.php';

/**
 * Restarts MeTube and the Watch page with the app's control script, failing the request if they don't start.
 *
 * @param string $ctl The app's control script
 *
 * @return void
 */
function metube_restart(string $ctl): void
{
    manage_run(['/bin/sh', $ctl, 'stop']);

    list($code, $output) = manage_run(['/bin/sh', $ctl, 'start']);

    if ($code !== 0) {
        manage_fail(500, 'MeTube could not be started: '.$output);
    }
}

/**
 * A number of days from the request (0-3650), failing the request if it isn't one.
 *
 * @param string $key The field
 *
 * @return int The days
 */
function metube_days(string $key): int
{
    $value = isset($_POST[$key]) ? trim((string)$_POST[$key]) : '';

    if (!preg_match('/^\d{1,4}$/', $value) || (int)$value > 3650) {
        manage_fail(400, 'Days are 0 (never) to 3650');
    }

    return (int)$value;
}

$action   = isset($_GET['action']) ? $_GET['action'] : 'status';
$settings = metube_settings($settings_file);
$users    = metube_read_json($users_file)['users'] ?? [];

if (!is_array($users)) {
    $users = [];
}

if ($action === 'status') {
    $running = manage_pid_running('/var/run/metube.pid');
    $watch   = manage_pid_running('/var/run/metube-watch.pid');

    list($code) = $running ? manage_http_get('http://127.0.0.1:8085/version', 5) : [0];
    list($watch_code, $watch_body) = $watch ? manage_http_get(METUBE_WATCH_TARGET.'/health', 5) : [0, ''];

    $download = $settings['download_dir'];
    $people   = [];

    foreach (array_keys($users) as $name) {
        $people[] = ['name' => (string)$name, 'videos' => $download !== '' ? metube_count_media($download.'/'.$name) : 0];
    }

    $server = $settings['media_server'];
    $log    = array_merge(@file($data_path.'/metube.log', FILE_IGNORE_NEW_LINES) ?: [], @file($data_path.'/watch.log', FILE_IGNORE_NEW_LINES) ?: []);

    manage_json([
        'running'        => $running,
        'answering'      => $code === 200,
        'watch'          => $watch && $watch_code === 200 && strpos($watch_body, 'watch') !== false,
        'version'        => trim((string)@file_get_contents($app_path.'/binaries/version')),
        'ytdlp'          => metube_ytdlp_version($data_path, $app_path),
        'ytdlp_status'   => trim((string)@file_get_contents($data_path.'/ytdlp.status')),
        'ytdlp_update'   => (bool)$settings['ytdlp_update'],
        'listen'         => $settings['listen'] === 'all' ? 'all' : 'local',
        'site'           => manage_nginx_site($apps_path, METUBE_WATCH_TARGET),
        'download_dir'   => $download,
        'folder_ok'      => $download !== '' && is_dir($download),
        'watched_days'   => (int)$settings['watched_days'],
        'unwatched_days' => (int)$settings['unwatched_days'],
        'users'          => $people,
        'media_server'   => [
            'type'      => (string)($server['type'] ?? ''),
            'url'       => (string)($server['url'] ?? ''),
            'token_set' => ($server['token'] ?? '') !== '',
            'path_from' => (string)($server['path_from'] ?? ''),
            'path_to'   => (string)($server['path_to'] ?? ''),
        ],
        // Warnings and errors from both logs
        'log'            => array_values(array_slice(preg_grep('/(WARNING|ERROR|CRITICAL|Traceback)/', $log), -20)),
    ]);
}

manage_require_action('metube');

$name = isset($_POST['name']) ? trim((string)$_POST['name']) : '';

if ($action === 'add_user' || $action === 'new_password') {
    if ($action === 'add_user') {
        if (!preg_match('/^[a-z0-9][a-z0-9._-]{0,31}$/', $name)) {
            manage_fail(400, 'Names are up to 32 lower-case letters, digits, dots, dashes and underscores (starting with a letter or digit)');
        }

        if (isset($users[$name])) {
            manage_fail(400, 'There\'s already a user called '.$name);
        }
    } elseif (!isset($users[$name])) {
        manage_fail(404, 'No such user: '.$name);
    }

    $password = manage_new_password(isset($_POST['password']) ? (string)$_POST['password'] : '', 8);

    // Only its hash is kept: the page shows the password this once
    $users[$name] = ['hash' => metube_hash($password)];

    metube_write_json($users_file, ['users' => $users]);
    manage_json(['name' => $name, 'password' => $password]);
}

if ($action === 'remove_user') {
    if (!isset($users[$name])) {
        manage_fail(404, 'No such user: '.$name);
    }

    unset($users[$name]);
    metube_write_json($users_file, ['users' => $users]);
    @unlink($data_path.'/watch/'.$name.'.json');

    // Their videos too, if asked (else they stay in their folder, for a user added again with the same name)
    if (!empty($_POST['delete_videos']) && $settings['download_dir'] !== '') {
        $folder = $settings['download_dir'].'/'.$name;

        if (is_dir($folder) && realpath(dirname($folder)) === realpath($settings['download_dir'])) {
            manage_run(['/bin/rm', '-rf', '--', $folder]);
        }
    }

    manage_json();
}

if ($action === 'folder') {
    $folder = isset($_POST['folder']) ? rtrim(trim((string)$_POST['folder']), '/') : '';
    $error  = metube_check_folder($folder);

    if ($error !== '') {
        manage_fail(400, $error);
    }

    $settings['download_dir'] = $folder;
    metube_write_json($settings_file, $settings);
    metube_restart($ctl);
    manage_json();
}

if ($action === 'cleanup') {
    $settings['watched_days']   = metube_days('watched_days');
    $settings['unwatched_days'] = metube_days('unwatched_days');
    metube_write_json($settings_file, $settings);
    manage_json();
}

if ($action === 'media_server' || $action === 'media_test') {
    $type   = isset($_POST['type']) ? (string)$_POST['type'] : '';
    $server = [
        'type'      => in_array($type, METUBE_MEDIA_SERVERS, true) ? $type : '',
        'url'       => isset($_POST['url']) ? rtrim(trim((string)$_POST['url']), '/') : '',
        'token'     => isset($_POST['token']) ? trim((string)$_POST['token']) : '',
        'path_from' => isset($_POST['path_from']) ? rtrim(trim((string)$_POST['path_from']), '/') : '',
        'path_to'   => isset($_POST['path_to']) ? rtrim(trim((string)$_POST['path_to']), '/') : '',
    ];

    // An empty token keeps the one saved (the page never shows it)
    if ($server['token'] === '') {
        $server['token'] = (string)($settings['media_server']['token'] ?? '');
    }

    if ($server['type'] !== '') {
        if (!preg_match('#^https?://[^\s/]+(/[^\s]*)?$#', $server['url'])) {
            manage_fail(400, 'The media server\'s address is like http://127.0.0.1:32400 (Plex) or http://127.0.0.1:8096 (Jellyfin / Emby)');
        }

        if (!preg_match('/^[A-Za-z0-9._~-]{8,200}$/', $server['token'])) {
            manage_fail(400, 'Give the media server\'s token (Plex) or API key (Jellyfin / Emby)');
        }
    }

    if ($action === 'media_test') {
        if ($server['type'] === '') {
            manage_fail(400, 'Choose a media server first');
        }

        $result = metube_test_media_server($server, $settings['download_dir']);

        if (!$result['ok']) {
            manage_fail(502, $result['message']);
        }

        manage_json(['message' => $result['message']]);
    }

    $settings['media_server'] = $server['type'] === '' ? [] : $server;
    metube_write_json($settings_file, $settings);
    manage_json();
}

if ($action === 'ytdlp_setting') {
    $settings['ytdlp_update'] = !empty($_POST['update']);
    metube_write_json($settings_file, $settings);
    manage_json();
}

if ($action === 'ytdlp_update') {
    list($code, $output) = manage_run(['/bin/sh', $ctl, 'ytdlp', 'force']);

    if ($code !== 0) {
        manage_fail(500, 'yt-dlp could not be updated: '.$output);
    }

    manage_json(['ytdlp' => metube_ytdlp_version($data_path, $app_path)]);
}

if ($action === 'listen') {
    $settings['listen'] = isset($_POST['listen']) && $_POST['listen'] === 'all' ? 'all' : 'local';
    metube_write_json($settings_file, $settings);
    metube_restart($ctl);
    manage_json();
}

if ($action === 'restart') {
    metube_restart($ctl);
    manage_json();
}

manage_fail(400, 'Unknown action');
