<?php
// Go management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('golang');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path = dirname(__DIR__);
$go = $app_path . '/binaries/bin/go';
// Go keeps its telemetry setting in root's home folder
$env = ['HOME' => '/home/root'];

$action = isset($_GET['action']) ? $_GET['action'] : 'status';

if ($action === 'status') {
	list($code, $version) = manage_run([$go, 'version'], $env);
	list(, $telemetry) = manage_run([$go, 'telemetry'], $env);
	$running = manage_pid_running('/var/run/golang_test_server.pid');
	list($status) = $running ? manage_http_get('http://127.0.0.1:30289/') : [0];
	manage_json([
		'version' => $code === 0 && preg_match('/go version go(\S+)/', $version, $m) ? $m[1] : '',
		'telemetry' => in_array($telemetry, ['off', 'local', 'on'], true) ? $telemetry : '',
		'test_server' => $running ? ($status === 200 ? 'running' : 'starting') : 'stopped',
	]);
}

manage_require_action('golang');

if ($action === 'restart') {
	manage_run(['/bin/sh', $app_path . '/stop.sh', $app_path]);
	list($code, $output) = manage_run(['/bin/sh', $app_path . '/start.sh', $app_path]);
	if ($code !== 0) {
		manage_fail(500, 'The test server could not be started: ' . $output);
	}
	manage_json([]);
}

if ($action === 'telemetry_off') {
	// As init.sh does on install: turn it off, and remove anything it collected locally
	list($code, $output) = manage_run([$go, 'telemetry', 'off'], $env);
	if ($code !== 0) {
		manage_fail(500, 'Could not turn telemetry off: ' . $output);
	}
	manage_run(['rm', '-rf', '/home/root/.config/go/telemetry/local']);
	manage_json([]);
}

manage_fail(400, 'Unknown action');
