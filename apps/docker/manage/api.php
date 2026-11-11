<?php
// Docker management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('docker');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path         = dirname(__DIR__);
$docker           = $app_path.'/binaries/docker';
$docker_root      = dirname($app_path).'/_docker';
$restart_pid_file = '/var/run/docker_manage_restart.pid';
$app_modules      = ['overlay', 'iptable_raw'];
$memory_file      = $docker_root.'/memory_limit';
$memory_cgroup    = '/sys/fs/cgroup/memory/docker';

// The shares of the NAS's memory the page offers for Docker (in percent)
$memory_choices   = [25, 33, 50, 60, 70, 75, 80, 90];

/**
 * Runs a docker command that prints one JSON object per line (--format '{{json .}}').
 *
 * @param string       $docker The docker program
 * @param list<string> $args   Its arguments
 *
 * @return list<array<string, mixed>>|null The objects, or null if it failed
 */
function docker_json_lines(string $docker, array $args): ?array
{
    list($code, $output) = manage_run(array_merge([$docker], $args));

    if ($code !== 0) {
        return null;
    }

    $rows = [];

    foreach (explode("\n", $output) as $line) {
        $row = json_decode($line, true);

        if (is_array($row)) {
            $rows[] = $row;
        }
    }

    return $rows;
}

/**
 * Whether a restart started from this page is still going.
 *
 * @param string $pid_file Its PID file
 *
 * @return bool Whether it is
 *
 * @phpstan-impure
 */
function docker_restarting(string $pid_file): bool
{
    $pid = (int)@file_get_contents($pid_file);

    return $pid > 0 && file_exists('/proc/'.$pid);
}

/**
 * Why each of the app's own kernel modules is (or isn't) loaded - the same checks as daemon.sh's load_app_module.
 *
 * @param string       $app_path    The app's folder
 * @param string       $docker_root Docker's data folder
 * @param list<string> $names       The modules
 *
 * @return array{
 *     model:     string,
 *     firmware:  string,
 *     built_for: string,
 *     modules:   list<array{ name: string, state: string, marker: bool }>,
 * } The NAS, the firmware the modules were built for, and each module's state
 */
function docker_modules(string $app_path, string $docker_root, array $names): array
{
    $loaded = [];

    foreach (explode("\n", (string)@file_get_contents('/proc/modules')) as $line) {
        $loaded[strtok($line, ' ')] = true;
    }

    $model     = preg_replace('/^WD/', '', trim((string)@file_get_contents('/usr/local/modules/files/model')));
    $firmware  = trim((string)@file_get_contents('/etc/version'));
    $built_for = trim((string)@file_get_contents($app_path.'/modules/firmware'));

    $modules = [];

    foreach ($names as $name) {
        $marker = is_file($docker_root.'/.loading-'.$name);

        if (isset($loaded[$name])) {
            $state = 'loaded';
        } elseif (!is_file("{$app_path}/modules/{$model}/{$name}.ko")) {
            $state = 'not_built';
        } elseif ($firmware !== $built_for) {
            $state = 'wrong_firmware';
        } elseif ($marker) {
            $state = 'crashed';
        } else {
            $state = 'not_loaded';
        }

        $modules[] = [
            'name'   => $name,
            'state'  => $state,
            'marker' => $marker
        ];
    }

    return [
        'model'     => $model,
        'firmware'  => $firmware,
        'built_for' => $built_for,
        'modules'   => $modules
    ];
}

/**
 * Docker's memory: the NAS's total and available memory, the share chosen for Docker (as daemon.sh works it out), the
 * limit actually in force and what Docker's containers use (without reclaimable file cache, as "docker stats" counts
 * it).
 *
 * @param string $memory_file The share chosen on the page (a percentage)
 * @param string $cgroup      Docker's memory cgroup
 *
 * @return array{
 *     total:     int,
 *     available: int,
 *     percent:   int,
 *     limit:     int,
 *     usage:     int,
 * } Bytes, and the share as a percentage
 */
function docker_memory(string $memory_file, string $cgroup): array
{
    $meminfo   = (string)@file_get_contents('/proc/meminfo');
    $total     = preg_match('/^MemTotal:\s+(\d+)/m', $meminfo, $m) ? (int)$m[1] * 1024 : 0;
    $available = preg_match('/^MemAvailable:\s+(\d+)/m', $meminfo, $m) ? (int)$m[1] * 1024 : 0;
    $saved     = trim((string)@file_get_contents($memory_file));
    $percent   = preg_match('/^[1-9][0-9]$/', $saved) ? (int)$saved : ($total > 1073741824 ? 50 : 33);
    $limit     = (int)trim((string)@file_get_contents($cgroup.'/memory.limit_in_bytes'));
    $usage     = (int)trim((string)@file_get_contents($cgroup.'/memory.usage_in_bytes'));
    $stat      = (string)@file_get_contents($cgroup.'/memory.stat');

    if (preg_match('/^total_inactive_file (\d+)/m', $stat, $m)) {
        $usage = max(0, $usage - (int)$m[1]);
    }

    return [
        'total'     => $total,
        'available' => $available,
        'percent'   => $percent,
        'limit'     => $limit > 0 && $limit < $total * 2 ? $limit : 0,
        'usage'     => $usage,
    ];
}

/**
 * Asks Portainer (on the NAS itself) whether its admin account has been created yet.
 *
 * @return bool|null Whether it has, or null if Portainer didn't say
 */
function portainer_has_admin(): ?bool
{
    list($status) = manage_http_get('http://127.0.0.1:9000/api/users/admin/check');

    return $status === 204 ? true : ($status === 404 ? false : null);
}

$action = $_GET['action'] ?? 'status';

if ($action === 'status') {
    $info    = docker_json_lines($docker, ['info', '--format', '{{json .}}']);
    $info    = $info ? $info[0] : null;
    $running = is_array($info) && !empty($info['ServerVersion']);

    $containers = [];
    $portainer  = '';

    foreach ($running ? (array)docker_json_lines($docker, ['ps', '-a', '--format', '{{json .}}']) : [] as $c) {
        $name         = $c['Names'] ?? '';
        $containers[] = [
            'name'   => $name,
            'image'  => $c['Image']  ?? '',
            'state'  => $c['State']  ?? '',
            'status' => $c['Status'] ?? '',
            'ports'  => $c['Ports']  ?? '',
        ];

        if ($name === 'portainer') {
            $portainer = $c['State'] ?? '';
        }
    }

    // Containerd's way of laying out images: overlayfs, or native without the overlay module
    $driver     = $running && isset($info['Driver']) ? $info['Driver'] : '';
    $old_stores = [];

    // Docker's older image store (overlay2 or vfs): no longer used, its folders only take up space
    foreach (['overlay2', 'vfs'] as $old) {
        if (is_dir($docker_root.'/'.$old)) {
            $old_stores[] = $old;
        }
    }

    manage_json([
        'running'             => $running,
        'restarting'          => docker_restarting($restart_pid_file),
        'version'             => $running ? $info['ServerVersion'] : '',
        'driver'              => $driver,
        'old_stores'          => $old_stores,
        'docker_root'         => $docker_root,
        'images'              => $running && isset($info['Images']) ? (int)$info['Images'] : 0,
        'containers'          => $containers,
        'portainer'           => $portainer,
        'portainer_has_admin' => $portainer === 'running' ? portainer_has_admin() : null,
        // The Nginx app's HTTPS address for Portainer (see nginx.json), if it serves it
        'portainer_site'      => manage_nginx_site(dirname($app_path), 'http://127.0.0.1:9000'),
        'kernel'              => docker_modules($app_path, $docker_root, $app_modules),
        'memory'              => docker_memory($memory_file, $memory_cgroup),
        'memory_choices'      => $memory_choices,
    ]);
}

if ($action === 'disk') {
    // Can take a few seconds (especially with native storage), so it isn't part of the regular status
    $rows = docker_json_lines($docker, ['system', 'df', '--format', '{{json .}}']);

    if ($rows === null) {
        manage_fail(500, 'Docker is not running');
    }

    $disk = [];

    foreach ($rows as $row) {
        $disk[] = [
            'type'        => $row['Type']        ?? '',
            'count'       => $row['TotalCount']  ?? '',
            'active'      => $row['Active']      ?? '',
            'size'        => $row['Size']        ?? '',
            'reclaimable' => $row['Reclaimable'] ?? '',
        ];
    }

    manage_json(['disk' => $disk]);
}

manage_require_action('docker');

if ($action === 'setup_token') {
    // Portainer prints a new setup token (needed to create its admin account) every time it starts
    list($code, $output) = manage_run([$docker, 'logs', '--tail', '1000', 'portainer']);

    if ($code !== 0 || !preg_match_all('/setup_token=([0-9a-f]{16,})/', $output, $m)) {
        manage_fail(500, 'No setup token found in Portainer\'s log - restart Portainer to get a new one');
    }

    manage_json(['token' => end($m[1])]);
}

if ($action === 'restart_portainer') {
    list($code, $output) = manage_run([$docker, 'restart', 'portainer']);

    if ($code !== 0) {
        manage_fail(500, 'Portainer could not be restarted: '.$output);
    }

    manage_json();
}

if ($action === 'memory') {
    $percent = isset($_POST['percent']) ? (int)$_POST['percent'] : 0;

    if (!in_array($percent, $memory_choices, true)) {
        manage_fail(400, 'Choose one of: '.implode('%, ', $memory_choices).'%');
    }

    if (!manage_write_file($memory_file, $percent."\n")) {
        manage_fail(500, 'The setting could not be saved in: '.$memory_file);
    }

    // Applied straight away when Docker is set up; otherwise (or if the containers already use more than a lower limit)
    // it takes effect when Docker next starts
    list($code) = manage_run(['/bin/sh', $app_path.'/daemon.sh', 'memory']);

    manage_json(['applied' => $code === 0]);
}

if ($action === 'restart') {
    if (docker_restarting($restart_pid_file)) {
        manage_fail(409, 'Docker is already restarting');
    }

    // Retrying the kernel modules: remove the markers left by an attempt that never finished (see daemon.sh)
    if (!empty($_POST['retry_modules'])) {
        foreach ($app_modules as $name) {
            @unlink($docker_root.'/.loading-'.$name);
        }
    }

    // Stopping every container can take a while, so the restart runs in the background (detached from this request) and
    // the page follows it through the status
    $restart = 'echo $$ > "$1"; /bin/sh "$0/stop.sh" "$0"; /bin/sh "$0/start.sh" "$0"; rm -f "$1"';

    manage_run(['/bin/sh', '-c', '/bin/sh -c "$0" "$1" "$2" > /dev/null 2>&1 < /dev/null &', $restart, $app_path, $restart_pid_file]);

    // Wait briefly for it to start, so that the next status already shows the restart
    for ($i = 0; $i < 20 && !docker_restarting($restart_pid_file); $i++) {
        usleep(100000);
    }

    manage_json();
}

manage_fail(400, 'Unknown action');
