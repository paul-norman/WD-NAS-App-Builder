<?php
// Prometheus management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('prometheus');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path      = dirname(__DIR__);
$data_path     = dirname($app_path).'/_prometheus';
$settings_file = $data_path.'/settings';
$ctl           = $app_path.'/prom_ctl.sh';
$prometheus    = 'http://127.0.0.1:9090';

/**
 * The app's settings, with defaults.
 *
 * @param string $file The settings file (KEY=value lines, also read by the app's control script)
 *
 * @return array{ LISTEN: string, RETENTION_DAYS: string } The settings
 */
function prom_settings(string $file): array
{
    $settings = [
        'LISTEN'         => 'local',
        'RETENTION_DAYS' => '30',
    ];

    foreach (@file($file, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
        if (preg_match('/^([A-Z_]+)=(.*)$/', $line, $m) && isset($settings[$m[1]])) {
            $settings[$m[1]] = $m[2];
        }
    }

    return $settings;
}

/**
 * One of Prometheus' own API answers.
 *
 * @param string $prometheus Prometheus' address
 * @param string $path       The API's path
 *
 * @return mixed Its data, or null
 */
function prom_api(string $prometheus, string $path)
{
    list($status, $body) = manage_http_get($prometheus.$path, 5);

    $json = $status === 200 ? json_decode($body, true) : null;

    return is_array($json) && isset($json['data']) ? $json['data'] : null;
}

$settings = prom_settings($settings_file);
$action   = $_GET['action'] ?? 'status';

if ($action === 'status') {
    $running = manage_pid_running('/var/run/prometheus.pid');

    list($ready)     = $running ? manage_http_get($prometheus.'/-/ready') : [0];
    list(, $version) = manage_run([$app_path.'/binaries/prometheus', '--version']);
    list(, $du)      = manage_run(['du', '-sk', $data_path.'/data']);

    $targets = [];
    $runtime = null;

    if ($ready === 200) {
        $runtime = prom_api($prometheus, '/api/v1/status/runtimeinfo');
        $data    = prom_api($prometheus, '/api/v1/targets?state=active');

        foreach ($data['activeTargets'] ?? [] as $target) {
            $targets[] = [
                'job'      => $target['labels']['job']      ?? '',
                'instance' => $target['labels']['instance'] ?? '',
                'url'      => $target['scrapeUrl']          ?? '',
                'health'   => $target['health']             ?? '',
                'error'    => $target['lastError']          ?? '',
            ];
        }
    }

    $log = @file($data_path.'/prometheus.log', FILE_IGNORE_NEW_LINES) ?: [];

    manage_json([
        'running'        => $running,
        'answering'      => $ready === 200,
        'version'        => preg_match('/version (\S+)/', $version, $m) ? $m[1] : '',
        'listen'         => $settings['LISTEN'] === 'all' ? 'all' : 'local',
        'retention_days' => (int)$settings['RETENTION_DAYS'],
        'storage'        => preg_match('/^(\d+)/', $du, $m) ? (int)$m[1] * 1024 : 0,
        'config_ok'      => is_array($runtime) && isset($runtime['reloadConfigSuccess']) ? (bool)$runtime['reloadConfigSuccess'] : null,
        'targets'        => $targets,
        'own_files'      => array_map('basename', array_merge(glob($data_path.'/scrape.d/*.yml') ?: [], glob($data_path.'/rules.d/*.yml') ?: [])),
        'data_path'      => $data_path,
        'log'            => array_slice($log, -40),
    ]);
}

manage_require_action('prometheus');

if ($action === 'settings') {
    $days = isset($_POST['retention_days']) ? (int)$_POST['retention_days'] : 0;

    if ($days < 1 || $days > 3650) {
        manage_fail(400, 'Keep between 1 and 3650 days of history');
    }

    $text = 'LISTEN='.(isset($_POST['listen']) && $_POST['listen'] === 'all' ? 'all' : 'local')."\nRETENTION_DAYS=".$days."\n";

    if (!manage_write_file($settings_file, $text)) {
        manage_fail(500, 'The settings could not be saved');
    }

    list($code, $output) = manage_run(['/bin/sh', $ctl, 'restart']);

    if ($code !== 0) {
        manage_fail(500, 'Prometheus could not be started: '.$output);
    }

    manage_json();
}

if ($action === 'reload') {
    manage_run(['/bin/sh', $ctl, 'reload']);

    // Prometheus keeps its current configuration if the new one has an error, and says so in its log
    sleep(2);

    $runtime = prom_api($prometheus, '/api/v1/status/runtimeinfo');

    if (is_array($runtime) && empty($runtime['reloadConfigSuccess'])) {
        $log = @file($data_path.'/prometheus.log', FILE_IGNORE_NEW_LINES) ?: [];

        manage_fail(500, 'The configuration has an error, so Prometheus kept the previous one: '.trim((string)end($log)));
    }

    manage_json();
}

if ($action === 'restart') {
    list($code, $output) = manage_run(['/bin/sh', $ctl, 'restart']);

    if ($code !== 0) {
        manage_fail(500, 'Prometheus could not be started: '.$output);
    }

    manage_json();
}

manage_fail(400, 'Unknown action');
