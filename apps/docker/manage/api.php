<?php
// Docker management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('docker');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path = dirname(__DIR__);
$docker = $app_path . '/binaries/docker';
$docker_root = dirname($app_path) . '/_docker';
$restart_pid_file = '/var/run/docker_manage_restart.pid';
$app_modules = ['overlay', 'iptable_raw'];

// Runs a docker command that prints one JSON object per line (--format '{{json .}}'), returning them (or null)
function docker_json_lines($docker, array $args)
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

// Whether a restart started from this page is still going
function docker_restarting($pid_file)
{
	$pid = (int)@file_get_contents($pid_file);
	return $pid > 0 && file_exists('/proc/' . $pid);
}

// Why each of the app's own kernel modules is (or isn't) loaded - the same checks as daemon.sh's load_app_module
function docker_modules($app_path, $docker_root, array $names)
{
	$loaded = [];
	foreach (explode("\n", (string)@file_get_contents('/proc/modules')) as $line) {
		$loaded[strtok($line, ' ')] = true;
	}
	$model = preg_replace('/^WD/', '', trim((string)@file_get_contents('/usr/local/modules/files/model')));
	$firmware = trim((string)@file_get_contents('/etc/version'));
	$built_for = trim((string)@file_get_contents($app_path . '/modules/firmware'));

	$modules = [];
	foreach ($names as $name) {
		$marker = is_file($docker_root . '/.loading-' . $name);
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
		$modules[] = ['name' => $name, 'state' => $state, 'marker' => $marker];
	}
	return ['model' => $model, 'firmware' => $firmware, 'built_for' => $built_for, 'modules' => $modules];
}

// Asks Portainer (on the NAS itself) whether its admin account has been created yet: true, false or null (unknown)
function portainer_has_admin()
{
	list($status) = manage_http_get('http://127.0.0.1:9000/api/users/admin/check');
	return $status === 204 ? true : ($status === 404 ? false : null);
}

$action = isset($_GET['action']) ? $_GET['action'] : 'status';

if ($action === 'status') {
	$info = docker_json_lines($docker, ['info', '--format', '{{json .}}']);
	$info = $info ? $info[0] : null;
	$running = is_array($info) && !empty($info['ServerVersion']);

	$containers = [];
	$portainer = '';
	foreach ($running ? (array)docker_json_lines($docker, ['ps', '-a', '--format', '{{json .}}']) : [] as $c) {
		$name = isset($c['Names']) ? $c['Names'] : '';
		$containers[] = [
			'name' => $name,
			'image' => isset($c['Image']) ? $c['Image'] : '',
			'state' => isset($c['State']) ? $c['State'] : '',
			'status' => isset($c['Status']) ? $c['Status'] : '',
			'ports' => isset($c['Ports']) ? $c['Ports'] : '',
		];
		if ($name === 'portainer') {
			$portainer = isset($c['State']) ? $c['State'] : '';
		}
	}

	$driver = $running && isset($info['Driver']) ? $info['Driver'] : '';
	$unused_driver = '';
	foreach (['vfs', 'overlay2'] as $other) {
		if ($driver !== '' && $other !== $driver && is_dir($docker_root . '/' . $other)) {
			$unused_driver = $other;
		}
	}

	manage_json([
		'running' => $running,
		'restarting' => docker_restarting($restart_pid_file),
		'version' => $running ? $info['ServerVersion'] : '',
		'driver' => $driver,
		'unused_driver' => $unused_driver,
		'docker_root' => $docker_root,
		'images' => $running && isset($info['Images']) ? (int)$info['Images'] : 0,
		'containers' => $containers,
		'portainer' => $portainer,
		'portainer_has_admin' => $portainer === 'running' ? portainer_has_admin() : null,
		'kernel' => docker_modules($app_path, $docker_root, $app_modules),
	]);
}

if ($action === 'disk') {
	// Can take a few seconds (especially with vfs), so it isn't part of the regular status
	$rows = docker_json_lines($docker, ['system', 'df', '--format', '{{json .}}']);
	if ($rows === null) {
		manage_fail(500, 'Docker is not running');
	}
	$disk = [];
	foreach ($rows as $row) {
		$disk[] = [
			'type' => isset($row['Type']) ? $row['Type'] : '',
			'count' => isset($row['TotalCount']) ? $row['TotalCount'] : '',
			'active' => isset($row['Active']) ? $row['Active'] : '',
			'size' => isset($row['Size']) ? $row['Size'] : '',
			'reclaimable' => isset($row['Reclaimable']) ? $row['Reclaimable'] : '',
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
		manage_fail(500, 'Portainer could not be restarted: ' . $output);
	}
	manage_json([]);
}

if ($action === 'restart') {
	if (docker_restarting($restart_pid_file)) {
		manage_fail(409, 'Docker is already restarting');
	}
	// Retrying the kernel modules: remove the markers left by an attempt that never finished (see daemon.sh)
	if (!empty($_POST['retry_modules'])) {
		foreach ($app_modules as $name) {
			@unlink($docker_root . '/.loading-' . $name);
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
	manage_json([]);
}

manage_fail(400, 'Unknown action');
