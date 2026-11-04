<?php
// Headlamp management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('headlamp');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path      = dirname(__DIR__);
$apps_path     = dirname($app_path);
$data_path     = $apps_path.'/_headlamp';
$settings_file = $data_path.'/settings';
$ctl           = $app_path.'/headlamp_ctl.sh';
$target        = 'http://127.0.0.1:4466';

/**
 * The app's settings, with defaults.
 *
 * @param string $file The settings file (KEY=value lines, also read by the app's control script)
 *
 * @return array{ LISTEN: string } The settings
 */
function headlamp_settings(string $file): array
{
    $settings = ['LISTEN' => 'all'];

    foreach (@file($file, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
        if (preg_match('/^([A-Z_]+)=(.*)$/', $line, $m) && isset($settings[$m[1]])) {
            $settings[$m[1]] = $m[2];
        }
    }

    return $settings;
}

/**
 * Restarts Headlamp with its control script, failing the request if it doesn't start.
 *
 * @param string $ctl The app's control script
 *
 * @return void
 */
function headlamp_restart(string $ctl): void
{
    list($code, $output) = manage_run(['/bin/sh', $ctl, 'restart']);

    if ($code !== 0) {
        manage_fail(500, 'Headlamp could not be started: '.$output);
    }
}

$settings = headlamp_settings($settings_file);
$action   = $_GET['action'] ?? 'status';

if ($action === 'status') {
    $running = manage_pid_running('/var/run/headlamp.pid');

    // Headlamp's own configuration lists the clusters it found in its kubeconfig
    list($code, $config) = $running ? manage_http_get($target.'/config') : [0, ''];

    // The NAS's address on the local network (BusyBox's ip, as the NAS has it)
    $config  = json_decode($config, true);
    $address = preg_match('/ src (\S+)/', manage_run(['ip', '-4', 'route', 'get', '1.1.1.1'])[1], $m) ? $m[1] : '';
    $log     = @file($data_path.'/headlamp.log', FILE_IGNORE_NEW_LINES) ?: [];

    manage_json([
        'running'   => $running,
        'answering' => $code === 200,
        'cluster'   => is_array($config) && !empty($config['clusters']),
        'k3s'       => manage_pid_running('/var/run/k3s.pid'),
        'k3s_found' => is_file($apps_path.'/_k3s/data/server/tls/server-ca.crt'),
        'address'   => $address !== '' ? 'http://'.$address.':4466' : '',
        'site'      => manage_nginx_site($apps_path, $target),
        'listen'    => $settings['LISTEN'] === 'local' ? 'local' : 'all',
        'log'       => array_slice($log, -20),
    ]);
}

manage_require_action('headlamp');

if ($action === 'token') {
    list($code, $output) = manage_run(['/bin/sh', $ctl, 'token']);

    if ($code !== 0 || $output === '') {
        manage_fail(500, 'The token could not be read: is the k3s app running?');
    }

    manage_json(['token' => $output]);
}

if ($action === 'new_token') {
    list($code, $output) = manage_run(['/bin/sh', $ctl, 'new-token']);

    if ($code !== 0) {
        manage_fail(500, 'A new token could not be made (is the k3s app running?): '.$output);
    }

    list(, $token) = manage_run(['/bin/sh', $ctl, 'token']);

    manage_json(['token' => $token]);
}

if ($action === 'settings') {
    $text = 'LISTEN='.(isset($_POST['listen']) && $_POST['listen'] === 'local' ? 'local' : 'all')."\n";

    if (!manage_write_file($settings_file, $text)) {
        manage_fail(500, 'The settings could not be saved');
    }

    headlamp_restart($ctl);
    manage_json();
}

if ($action === 'restart') {
    headlamp_restart($ctl);
    manage_json();
}

manage_fail(400, 'Unknown action');
