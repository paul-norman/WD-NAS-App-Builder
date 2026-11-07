<?php
// rclone management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('rclone');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path      = dirname(__DIR__);
$apps_path     = dirname($app_path);
$data_path     = $apps_path.'/_rclone';
$settings_file = $data_path.'/settings';
$ctl           = $app_path.'/rclone_ctl.sh';

require $app_path.'/lib/rclone.php';

$target = 'http://127.0.0.1:'.RCLONE_PORT;

/**
 * Restarts rclone's web interface with its control script, failing the request if it doesn't start.
 *
 * @param string $ctl The app's control script
 *
 * @return void
 */
function rclone_restart(string $ctl): void
{
    list($code, $output) = manage_run(['/bin/sh', $ctl, 'restart']);

    if ($code !== 0) {
        manage_fail(500, 'rclone could not be started: '.$output);
    }
}

/**
 * A job's ID from the request, if it's one of the jobs.
 *
 * @param string $data_path The app's data folder
 *
 * @return string The ID (the request fails if it isn't a job's)
 */
function rclone_requested_job(string $data_path): string
{
    $id = isset($_POST['id']) ? (string)$_POST['id'] : '';

    foreach (rclone_jobs($data_path) as $job) {
        if ($job['id'] === $id) {
            return $id;
        }
    }

    manage_fail(404, 'No such job');
}

$action = $_GET['action'] ?? 'status';

if ($action === 'status') {
    $running  = manage_pid_running('/var/run/rclone.pid');
    $password = trim((string)@file_get_contents($data_path.'/password'));
    $version  = $running ? manage_http_request('POST', $target.'/core/version', '{}', 3, ['Authorization: Basic '.base64_encode('admin:'.$password)]) : [0, ''];
    $about    = $version[0] === 200 ? json_decode($version[1], true) : null;
    $address  = preg_match('/ src (\S+)/', manage_run(['ip', '-4', 'route', 'get', '1.1.1.1'])[1], $a) ? $a[1] : '';
    $listen   = (string)(parse_ini_string((string)@file_get_contents($settings_file))['LISTEN'] ?? 'all');
    $log      = @file($data_path.'/rclone.log', FILE_IGNORE_NEW_LINES) ?: [];
    $jobs     = [];

    foreach (rclone_jobs($data_path) as $job) {
        $status = rclone_job_status($data_path, $job['id']);

        // A run that never finished (the NAS restarted, or it was stopped) has no lock any more
        if (($status['state'] ?? '') === 'running' && !is_dir('/var/run/rclone-job-'.$job['id'])) {
            $status['state'] = 'interrupted';
        }

        $jobs[] = $job + ['status' => $status];
    }

    manage_json([
        'running'   => $running,
        'answering' => is_array($about),
        'version'   => ltrim((string)($about['version'] ?? ''), 'v'),
        'address'   => $address !== '' ? 'http://'.$address.':'.RCLONE_PORT.'/' : '',
        'site'      => manage_nginx_site($apps_path, $target),
        'listen'    => $listen === 'local' ? 'local' : 'all',
        'remotes'   => rclone_remotes($data_path),
        'jobs'      => $jobs,
        'log'       => array_slice($log, -20),
    ]);
}

manage_require_action('rclone');

if ($action === 'password') {
    manage_json(['password' => trim((string)@file_get_contents($data_path.'/password'))]);
}

if ($action === 'new_password') {
    list($code, $output) = manage_run(['/bin/sh', $ctl, 'new-password']);

    if ($code !== 0) {
        manage_fail(500, 'A new password could not be made: '.$output);
    }

    rclone_restart($ctl);
    manage_json(['password' => trim((string)@file_get_contents($data_path.'/password'))]);
}

if ($action === 'settings') {
    if (!manage_write_file($settings_file, 'LISTEN='.(isset($_POST['listen']) && $_POST['listen'] === 'local' ? 'local' : 'all')."\n")) {
        manage_fail(500, 'The settings could not be saved');
    }

    rclone_restart($ctl);
    manage_json();
}

if ($action === 'restart') {
    rclone_restart($ctl);
    manage_json();
}

if ($action === 'add_job') {
    $error = rclone_add_job($data_path, $_POST);

    if ($error !== '') {
        manage_fail(400, $error);
    }

    manage_json();
}

if ($action === 'delete_job') {
    $id   = rclone_requested_job($data_path);
    $jobs = array_values(array_filter(rclone_jobs($data_path), function (array $job) use ($id): bool {
        return $job['id'] !== $id;
    }));

    if (!rclone_save_jobs($data_path, $jobs)) {
        manage_fail(500, 'The job could not be removed');
    }

    @unlink($data_path.'/status/'.$id.'.json');
    @unlink($data_path.'/status/'.$id.'.log');
    manage_json();
}

if ($action === 'run_job') {
    $id = rclone_requested_job($data_path);

    if (is_dir('/var/run/rclone-job-'.$id)) {
        manage_fail(409, 'That job is already running');
    }

    // In the background: a job can take hours (its state and log show how it went)
    manage_run(['/bin/sh', '-c', 'nohup /bin/sh "$0" run "$1" > /dev/null 2>&1 &', $ctl, $id]);
    manage_json();
}

if ($action === 'job_log') {
    $id  = rclone_requested_job($data_path);
    $log = @file($data_path.'/status/'.$id.'.log', FILE_IGNORE_NEW_LINES) ?: [];

    manage_json(['log' => array_slice($log, -100)]);
}

manage_fail(400, 'Unknown action');
