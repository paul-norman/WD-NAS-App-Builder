<?php
// Audiobookshelf management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('audiobookshelf');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path      = dirname(__DIR__);
$apps_path     = dirname($app_path);
$data_path     = $apps_path.'/_audiobookshelf';
$settings_file = $data_path.'/settings';
$token_file    = $data_path.'/page_token';
$ctl           = $app_path.'/abs_ctl.sh';

require $app_path.'/lib/abs.php';

/**
 * The app's settings, with defaults.
 *
 * @param string $file The settings file (KEY=value lines, also read by the app's control script)
 *
 * @return array{ LISTEN: string, LOCAL_FEEDS: string } The settings
 */
function abs_settings(string $file): array
{
    $settings = [
        'LISTEN'      => 'all',
        'LOCAL_FEEDS' => '',
    ];

    foreach (@file($file, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
        if (preg_match('/^([A-Z_]+)=(.*)$/', $line, $m) && isset($settings[$m[1]])) {
            $settings[$m[1]] = $m[2];
        }
    }

    return $settings;
}

/**
 * Audiobookshelf's root user's password, as the app made it.
 *
 * @param string $data_path The app's data folder
 *
 * @return string The password, or ''
 */
function abs_password(string $data_path): string
{
    return trim((string)@file_get_contents($data_path.'/root_password'));
}

/**
 * Restarts Audiobookshelf with its control script (stop, then start), failing the request if it doesn't start.
 *
 * @param string $ctl The app's control script
 *
 * @return void
 */
function abs_restart(string $ctl): void
{
    manage_run(['/bin/sh', $ctl, 'stop']);

    list($code, $output) = manage_run(['/bin/sh', $ctl, 'start']);

    if ($code !== 0) {
        manage_fail(500, 'Audiobookshelf could not be started: '.$output);
    }
}

/**
 * Audiobookshelf's own API, as the root user. Its access token is kept (root only) and reused until it expires - logins
 * are rate limited, and each is logged.
 *
 * @param string $data_path  The app's data folder
 * @param string $token_file Where the access token is kept
 * @param string $path       The API's path
 *
 * @return mixed The response's data, or null
 */
function abs_api(string $data_path, string $token_file, string $path)
{
    for ($attempt = 0; $attempt < 2; $attempt++) {
        $token = trim((string)@file_get_contents($token_file));

        if ($token === '' || $attempt === 1) {
            $password = abs_password($data_path);

            if ($password === '') {
                return null;
            }

            list($code, $body) = manage_http_request('POST', ABS_TARGET.'/login', json_encode(['username' => 'root', 'password' => $password]));

            $login = $code === 200 ? json_decode($body, true) : null;

            if (!isset($login['user']['accessToken'])) {
                return null;
            }

            $token = $login['user']['accessToken'];
            $old   = umask(077);

            file_put_contents($token_file, $token);
            umask($old);
        }

        list($code, $body) = manage_http_request('GET', ABS_TARGET.$path, null, 5, ['Authorization: Bearer '.$token]);

        if ($code === 200) {
            return json_decode($body, true);
        }

        if ($code !== 401) {
            return null;
        }
    }

    return null;
}

$settings = abs_settings($settings_file);
$action   = $_GET['action'] ?? 'status';

if ($action === 'status') {
    $running = manage_pid_running('/var/run/audiobookshelf.pid');

    list($code, $body) = $running ? manage_http_get(ABS_TARGET.'/status') : [0, ''];

    $status = $code === 200 ? json_decode($body, true) : null;
    $host   = isset($_SERVER['HTTP_HOST']) ? preg_replace('/:\d+$/', '', $_SERVER['HTTP_HOST']) : '';

    // Its libraries: their folders (and whether its user can use them) and how many items each has
    $libraries = null;

    if ($status) {
        $list = abs_api($data_path, $token_file, '/api/libraries');

        if (isset($list['libraries'])) {
            $libraries = [];

            foreach ($list['libraries'] as $library) {
                $items   = abs_api($data_path, $token_file, '/api/libraries/'.rawurlencode($library['id']).'/items?limit=1');
                $folders = [];

                foreach ($library['folders'] as $folder) {
                    list($can) = manage_run(['/bin/sh', $ctl, 'check-folder', $folder['fullPath']]);

                    $folders[] = ['path' => $folder['fullPath'], 'can' => $can === 0 ? 'write' : ($can === 1 ? 'read' : 'none')];
                }

                $libraries[] = [
                    'name'    => $library['name'],
                    'type'    => $library['mediaType'],
                    'folders' => $folders,
                    'items'   => isset($items['total']) ? (int)$items['total'] : null,
                ];
            }
        }
    }

    $log = array_values(array_filter(@file($data_path.'/audiobookshelf.log', FILE_IGNORE_NEW_LINES) ?: [], function (string $line) {
        return preg_match('/\] (WARN|ERROR|FATAL):/', $line);
    }));

    manage_json([
        'running'        => $running,
        'answering'      => $status !== null,
        'version'        => $status['serverVersion'] ?? '',
        'site'           => manage_nginx_site($apps_path, ABS_TARGET),
        'local_url'      => $host !== '' ? 'http://'.$host.':13378/' : '',
        'listen'         => $settings['LISTEN'] === 'local' ? 'local' : 'all',
        'local_feeds'    => str_replace(',', ', ', $settings['LOCAL_FEEDS']),
        'password_known' => abs_password($data_path) !== '',
        // null when the page can't log in (e.g. root's password was changed in Audiobookshelf)
        'libraries'      => $libraries,
        'log'            => array_slice($log, -20),
    ]);
}

manage_require_action('audiobookshelf');

if ($action === 'password') {
    manage_json(['password' => abs_password($data_path)]);
}

if ($action === 'new_password') {
    list($code, $output) = manage_run(['/bin/sh', $ctl, 'new-password']);

    if ($code !== 0) {
        manage_fail(500, 'A new password could not be set: '.$output);
    }

    @unlink($token_file);

    manage_json(['password' => abs_password($data_path)]);
}

if ($action === 'settings') {
    $feeds = isset($_POST['local_feeds']) ? strtolower(preg_replace('/\s*,\s*/', ',', trim((string)$_POST['local_feeds']))) : '';

    foreach ($feeds === '' ? [] : explode(',', $feeds) as $host) {
        if (!preg_match('/^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$/', $host)) {
            manage_fail(400, 'Podcast feeds on your own network: host names or IP addresses, separated by commas (e.g. 192.168.1.20)');
        }
    }

    $text = 'LISTEN='.(isset($_POST['listen']) && $_POST['listen'] === 'local' ? 'local' : 'all')."\n".'LOCAL_FEEDS='.$feeds."\n";

    if (!manage_write_file($settings_file, $text)) {
        manage_fail(500, 'The settings could not be saved');
    }

    abs_restart($ctl);
    manage_json();
}

if ($action === 'restart') {
    abs_restart($ctl);
    manage_json();
}

manage_fail(400, 'Unknown action');
