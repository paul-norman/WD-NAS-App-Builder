<?php
// k3s management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('k3s');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path      = dirname(__DIR__);
$apps_path     = dirname($app_path);
$data_path     = $apps_path.'/_k3s';
$settings_file = $data_path.'/settings';
$ctl           = $app_path.'/k3s_ctl.sh';
$k3s           = $app_path.'/binaries/k3s';

/**
 * The app's settings, with defaults.
 *
 * @param string $file The settings file (KEY=value lines, also read by the app's control script)
 *
 * @return array{ MEMORY: string, SERVICELB: string } The settings (MEMORY '' for the default share)
 */
function k3s_settings(string $file): array
{
    $settings = [
        'MEMORY'    => '',
        'SERVICELB' => '0',
    ];

    foreach (@file($file, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
        if (preg_match('/^([A-Z_]+)=(.*)$/', $line, $m) && isset($settings[$m[1]])) {
            $settings[$m[1]] = $m[2];
        }
    }

    return $settings;
}

/**
 * The share of the NAS's memory the cluster's pods may use, in percent: the one chosen, otherwise half (a third on
 * devices with 1GB or less) - as the control script works it out.
 *
 * @param string $chosen The MEMORY setting
 * @param int    $total  The NAS's memory, in KiB
 *
 * @return int The percentage
 */
function k3s_memory_percent(string $chosen, int $total): int
{
    if (preg_match('/^\d+$/', $chosen) && (int)$chosen >= 25 && (int)$chosen <= 90) {
        return (int)$chosen;
    }

    return $total > 1048576 ? 50 : 33;
}

/**
 * Runs kubectl (k3s's own) as the cluster's admin, for JSON.
 *
 * @param string       $k3s  The k3s program
 * @param list<string> $args kubectl's arguments (-o json is added)
 *
 * @return array<string, mixed>|null What it printed, or null if it failed (e.g. k3s isn't ready)
 */
function k3s_kubectl(string $k3s, array $args): ?array
{
    list($code, $output) = manage_run(array_merge([$k3s, 'kubectl', '--request-timeout=5s'], $args, ['-o', 'json']));

    $data = $code === 0 ? json_decode($output, true) : null;

    return is_array($data) ? $data : null;
}

/**
 * A pod's state as kubectl shows it: its phase, or why a container is waiting or ended (e.g. CrashLoopBackOff).
 *
 * @param array<string, mixed> $pod The pod (from kubectl's JSON)
 *
 * @return array{ state: string, ready: string, restarts: int } Its state, ready containers (1/2) and restarts
 */
function k3s_pod_state(array $pod): array
{
    $state    = ($pod['metadata']['deletionTimestamp'] ?? '') !== '' ? 'Terminating' : ($pod['status']['phase'] ?? 'Unknown');
    $ready    = 0;
    $restarts = 0;
    $statuses = $pod['status']['containerStatuses'] ?? [];

    foreach ($statuses as $status) {
        $ready    += empty($status['ready']) ? 0 : 1;
        $restarts += (int)($status['restartCount'] ?? 0);

        if (isset($status['state']['waiting']['reason'])) {
            $state = $status['state']['waiting']['reason'];
        } elseif (isset($status['state']['terminated']['reason']) && $state === 'Running') {
            $state = $status['state']['terminated']['reason'];
        }
    }

    return ['state' => $state, 'ready' => $ready.'/'.count($statuses), 'restarts' => $restarts];
}

/**
 * Restarts k3s itself (its pods keep running), failing the request if it doesn't start.
 *
 * @param string $ctl The app's control script
 *
 * @return void
 */
function k3s_restart(string $ctl): void
{
    list($code, $output) = manage_run(['/bin/sh', $ctl, 'restart']);

    if ($code !== 0) {
        manage_fail(500, 'k3s could not be started: '.$output);
    }
}

$settings = k3s_settings($settings_file);
$action   = $_GET['action'] ?? 'status';

if ($action === 'status') {
    $running = manage_pid_running('/var/run/k3s.pid');
    $nodes   = $running ? k3s_kubectl($k3s, ['get', 'nodes']) : null;
    $pods    = $running ? k3s_kubectl($k3s, ['get', 'pods', '--all-namespaces']) : null;

    list(, $version) = manage_run([$k3s, '--version']);

    $node = $nodes['items'][0] ?? null;
    $list = [];

    foreach ($pods['items'] ?? [] as $pod) {
        $list[] = [
            'namespace' => $pod['metadata']['namespace'] ?? '',
            'name'      => $pod['metadata']['name'] ?? '',
        ] + k3s_pod_state($pod);
    }

    $ready = false;

    foreach ($node['status']['conditions'] ?? [] as $condition) {
        if (($condition['type'] ?? '') === 'Ready') {
            $ready = ($condition['status'] ?? '') === 'True';
        }
    }

    // The NAS's memory, and the share the pods may use
    $meminfo = (string)@file_get_contents('/proc/meminfo');
    $total   = preg_match('/^MemTotal:\s+(\d+)/m', $meminfo, $m) ? (int)$m[1] : 0;
    $kernel  = array_values(array_filter(@file($data_path.'/kernel', FILE_IGNORE_NEW_LINES) ?: []));
    $log     = @file($data_path.'/k3s.log', FILE_IGNORE_NEW_LINES) ?: [];

    manage_json([
        'running'    => $running,
        'answering'  => $nodes !== null,
        'ready'      => $ready,
        'version'    => preg_match('/k3s version (v\S+)/', $version, $m) ? $m[1] : '',
        'node'       => $node['metadata']['name'] ?? '',
        'kubernetes' => $node['status']['nodeInfo']['kubeletVersion'] ?? '',
        'kernel'     => $kernel,
        'overlay'    => strpos((string)@file_get_contents('/proc/filesystems'), "\toverlay") !== false,
        'memory'     => [
            'total_mb' => intdiv($total, 1024),
            'percent'  => k3s_memory_percent($settings['MEMORY'], $total),
            'chosen'   => $settings['MEMORY'] !== '',
        ],
        'servicelb'  => $settings['SERVICELB'] === '1',
        'pods'       => $list,
        'log'        => array_slice($log, -30),
    ]);
}

manage_require_action('k3s');

if ($action === 'kubeconfig') {
    list($code, $output) = manage_run(['/bin/sh', $ctl, 'kubeconfig']);

    if ($code !== 0 || $output === '') {
        manage_fail(500, 'There is no kubeconfig yet: k3s writes it once it has started');
    }

    manage_json(['kubeconfig' => $output."\n"]);
}

if ($action === 'settings') {
    $memory = isset($_POST['memory']) ? (string)$_POST['memory'] : '';

    if ($memory !== '' && (!preg_match('/^\d+$/', $memory) || (int)$memory < 25 || (int)$memory > 90)) {
        manage_fail(400, 'The memory share is 25% to 90%');
    }

    $text = 'MEMORY='.$memory."\n"
        .'SERVICELB='.(empty($_POST['servicelb']) ? 0 : 1)."\n";

    if (!manage_write_file($settings_file, $text)) {
        manage_fail(500, 'The settings could not be saved');
    }

    k3s_restart($ctl);
    manage_json();
}

if ($action === 'restart') {
    k3s_restart($ctl);
    manage_json();
}

manage_fail(400, 'Unknown action');
