<?php
// ntfy management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('ntfy');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path      = dirname(__DIR__);
$apps_path     = dirname($app_path);
$data_path     = $apps_path.'/_ntfy';
$settings_file = $data_path.'/settings';
$ctl           = $app_path.'/ntfy_ctl.sh';

require $app_path.'/lib/ntfy.php';

/**
 * The app's settings, with defaults.
 *
 * @param string $file The settings file (KEY=value lines, also read by the app's control script)
 *
 * @return array{ LISTEN: string, IOS_PUSH: string } The settings
 */
function ntfy_settings(string $file): array
{
    $settings = [
        'LISTEN'   => 'all',
        'IOS_PUSH' => '0',
    ];

    foreach (@file($file, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
        if (preg_match('/^([A-Z_]+)=(.*)$/', $line, $m) && isset($settings[$m[1]])) {
            $settings[$m[1]] = $m[2];
        }
    }

    return $settings;
}

/**
 * One of the secrets ntfy's app keeps (root only) in its data folder.
 *
 * @param string $data_path The app's data folder
 * @param string $name      The secret's file (e.g. page_token)
 *
 * @return string It, or ''
 */
function ntfy_secret(string $data_path, string $name): string
{
    return trim((string)@file_get_contents($data_path.'/'.$name));
}

/**
 * Restarts ntfy with its control script (stop, then start), failing the request if it doesn't start.
 *
 * @param string $ctl The app's control script
 *
 * @return void
 */
function ntfy_restart(string $ctl): void
{
    manage_run(['/bin/sh', $ctl, 'stop']);

    list($code, $output) = manage_run(['/bin/sh', $ctl, 'start']);

    if ($code !== 0) {
        manage_fail(500, 'ntfy could not be started: '.$output);
    }
}

$settings = ntfy_settings($settings_file);
$action   = $_GET['action'] ?? 'status';

if ($action === 'status') {
    $running = manage_pid_running('/var/run/ntfy.pid');

    list($code, $health) = $running ? manage_http_get(NTFY_TARGET.'/v1/health') : [0, ''];
    list(, $help)        = manage_run([$app_path.'/binaries/ntfy', '--help']);

    // The address ntfy runs with (set when it started - phones and links use it)
    $config = (string)@file_get_contents($data_path.'/data/server.yml');
    $base   = preg_match('/^base-url: "([^"]*)"/m', $config, $m) ? $m[1] : '';
    $site   = manage_nginx_site($apps_path, NTFY_TARGET);
    $log    = @file($data_path.'/ntfy.log', FILE_IGNORE_NEW_LINES) ?: [];

    manage_json([
        'running'        => $running,
        'answering'      => $code === 200 && strpos($health, '"healthy":true') !== false,
        'version'        => preg_match('/VERSION:\s+(\S+)/', $help, $m) ? $m[1] : '',
        'base_url'       => $base,
        'site'           => $site,
        // The Nginx app's address changed since ntfy started (it uses it for its links and the phone apps' address)
        'restart_needed' => $running && $site['url'] !== '' && rtrim($site['url'], '/') !== $base,
        'listen'         => $settings['LISTEN'] === 'local' ? 'local' : 'all',
        'ios_push'       => $settings['IOS_PUSH'] === '1',
        'log'            => array_slice($log, -20),
    ]);
}

manage_require_action('ntfy');

if ($action === 'password') {
    manage_json(['password' => ntfy_secret($data_path, 'admin_password')]);
}

if ($action === 'token') {
    manage_json(['token' => ntfy_secret($data_path, 'token')]);
}

if ($action === 'new_password' || $action === 'new_token') {
    $what = $action === 'new_password' ? 'password' : 'token';

    list($code, $output) = manage_run(['/bin/sh', $ctl, 'new-'.$what]);

    if ($code !== 0) {
        manage_fail(500, 'A new '.$what.' could not be made: '.$output);
    }

    ntfy_restart($ctl);
    manage_json([$what => ntfy_secret($data_path, $what === 'password' ? 'admin_password' : 'token')]);
}

if ($action === 'settings') {
    $text = 'LISTEN='.(isset($_POST['listen']) && $_POST['listen'] === 'local' ? 'local' : 'all')."\n"
       .'IOS_PUSH='.(empty($_POST['ios_push']) ? 0 : 1)."\n";

    if (!manage_write_file($settings_file, $text)) {
        manage_fail(500, 'The settings could not be saved');
    }

    ntfy_restart($ctl);
    manage_json();
}

if ($action === 'test') {
    // A test notification, sent with the apps' token (as the NAS's apps and scripts send theirs)
    $topic = isset($_POST['topic']) ? trim((string)$_POST['topic']) : '';

    if (!preg_match('/^[A-Za-z0-9_-]{1,64}$/', $topic)) {
        manage_fail(400, 'Topics are 1-64 letters, digits, _ and -');
    }

    list($code, $body) = manage_http_request(
        'POST',
        NTFY_TARGET.'/'.$topic,
        'Test notification from the NAS\'s ntfy app',
        5,
        ['Authorization: Bearer '.ntfy_secret($data_path, 'token'), 'Title: Hello from the NAS', 'Tags: white_check_mark']
    );

    if ($code !== 200) {
        manage_fail(500, 'ntfy did not accept the notification ('.$code.'): '.$body);
    }

    manage_json();
}

if ($action === 'restart') {
    ntfy_restart($ctl);
    manage_json();
}

manage_fail(400, 'Unknown action');
