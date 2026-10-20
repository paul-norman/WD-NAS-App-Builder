<?php
// Node Exporter management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('node_exporter');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path = dirname(__DIR__);
$data_path = dirname($app_path) . '/_node_exporter';
$settings_file = $data_path . '/settings';
$password_file = $data_path . '/password';
$web_config = $data_path . '/web-config.yml';
$wd_file = '/tmp/node_exporter-textfile/wd.prom';
$log_file = '/tmp/node_exporter.log';
$auth_user = 'prometheus';

// The settings: the port, and whether scrapes need a password
function ne_settings()
{
	global $settings_file;
	$text = (string)@file_get_contents($settings_file);
	return [
		'port' => preg_match('/^PORT=(\d+)$/m', $text, $m) ? (int)$m[1] : 9100,
		'auth' => (bool)preg_match('/^AUTH=1$/m', $text),
	];
}

// Writes the password's bcrypt hash where Node Exporter reads it (the password itself is kept, root-only, to be shown)
function ne_write_auth($password)
{
	global $password_file, $web_config, $auth_user;
	$yaml = "# Written by the management page: scrapes need this user name and password\nbasic_auth_users:\n"
		. '  ' . $auth_user . ': ' . password_hash($password, PASSWORD_BCRYPT) . "\n";
	return manage_write_file($password_file, $password) && manage_write_file($web_config, $yaml);
}

function ne_restart()
{
	global $app_path;
	manage_run(['/bin/sh', $app_path . '/stop.sh', $app_path]);
	list($code, $output) = manage_run(['/bin/sh', $app_path . '/start.sh', $app_path]);
	if ($code !== 0) {
		manage_fail(500, 'Node Exporter could not be started: ' . $output);
	}
}

// The samples of WD's metrics file, as [name, labels, value] (only the app's own simple format is parsed)
function ne_wd_samples($file)
{
	$samples = [];
	foreach (@file($file, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
		if (!preg_match('/^(\w+)(?:\{(.*)\})? (\S+)$/', $line, $m)) {
			continue;
		}
		preg_match_all('/(\w+)="((?:[^"\\\\]|\\\\.)*)"/', isset($m[2]) ? $m[2] : '', $pairs, PREG_SET_ORDER);
		$labels = [];
		foreach ($pairs as $pair) {
			$labels[$pair[1]] = stripcslashes($pair[2]);
		}
		$samples[] = [$m[1], $labels, $m[3] + 0];
	}
	return $samples;
}

$action = isset($_GET['action']) ? $_GET['action'] : 'status';

if ($action === 'status') {
	$settings = ne_settings();
	$running = manage_pid_running('/var/run/node_exporter.pid');
	list($status) = $running ? manage_http_get('http://127.0.0.1:' . $settings['port'] . '/') : [0];
	list(, $version) = manage_run([$app_path . '/binaries/node_exporter', '--version']);

	// WD's storage, from the metrics the script last wrote
	$disks = $raids = $volumes = [];
	$health = null;
	$collected = false;
	foreach (ne_wd_samples($wd_file) as list($name, $labels, $value)) {
		if (strpos($name, 'wd_disk_') === 0) {
			$key = $labels['disk'];
			$disks += [$key => ['disk' => $key, 'bay' => $labels['bay']]];
			$disks[$key][substr($name, 8)] = $name === 'wd_disk_info' ? $labels['model'] : $value;
		} elseif (strpos($name, 'wd_raid_') === 0) {
			$key = $labels['raid'];
			$raids += [$key => ['raid' => $key]];
			if ($name === 'wd_raid_info') {
				$raids[$key]['level'] = $labels['level'];
				$raids[$key]['system'] = $labels['system'] === '1';
			} elseif ($name === 'wd_raid_state') {
				$raids[$key]['state'] = $labels['state'];
			} elseif ($name === 'wd_raid_disks') {
				$raids[$key]['disks_' . $labels['state']] = $value;
			}
		} elseif (strpos($name, 'wd_volume_') === 0) {
			$key = $labels['volume'];
			$volumes += [$key => ['volume' => $key]];
			$volumes[$key][substr($name, 10)] = $name === 'wd_volume_info' ? $labels['mountpoint'] : $value;
		} elseif ($name === 'wd_health') {
			$health = $value;
		} elseif ($name === 'wd_collector_success') {
			$collected = $value === 1;
		}
	}

	// Node Exporter's latest warnings (its log is in RAM)
	$log = @file($log_file, FILE_IGNORE_NEW_LINES) ?: [];

	manage_json([
		'running' => $running,
		'answering' => $status === 200 || $status === 401,
		'version' => preg_match('/version (\S+)/', $version, $m) ? $m[1] : '',
		'port' => $settings['port'],
		'auth' => $settings['auth'],
		'user' => $auth_user,
		'wd_running' => manage_pid_running('/var/run/node_exporter-wd.pid'),
		'wd_collected' => $collected,
		'wd_age' => is_file($wd_file) ? time() - filemtime($wd_file) : null,
		'health' => $health,
		'disks' => array_values($disks),
		'raids' => array_values($raids),
		'volumes' => array_values($volumes),
		'log' => array_slice($log, -5),
	]);
}

manage_require_action('node_exporter');

if ($action === 'password') {
	manage_json(['password' => trim((string)@file_get_contents($password_file))]);
}

if ($action === 'set_password') {
	// A new password: the one given (letters, digits and . _ ~ - only, like the other apps), or a random one
	$new = isset($_POST['password']) ? trim((string)$_POST['password']) : '';
	if ($new === '') {
		$new = substr(str_replace(['+', '/', '='], '', base64_encode(random_bytes(48))), 0, 20);
	} elseif (!preg_match('/^[A-Za-z0-9._~-]{12,128}$/', $new)) {
		manage_fail(400, 'Passwords must be 12-128 characters: letters, digits and . _ ~ -');
	}
	if (!ne_write_auth($new)) {
		manage_fail(500, 'The password could not be saved in: ' . $data_path);
	}
	// Node Exporter rereads its web config on every request, so no restart is needed
	manage_json(['password' => $new]);
}

if ($action === 'settings') {
	$port = isset($_POST['port']) ? (int)$_POST['port'] : 0;
	$auth = !empty($_POST['auth']);
	if ($port < 1024 || $port > 65535) {
		manage_fail(400, 'The port must be between 1024 and 65535');
	}
	// A password given when turning it on (letters, digits and . _ ~ - only, like the other apps) - or, the first time one
	// is needed, a generated one
	$password = isset($_POST['password']) ? trim((string)$_POST['password']) : '';
	if ($auth && $password !== '' && !preg_match('/^[A-Za-z0-9._~-]{12,128}$/', $password)) {
		manage_fail(400, 'Passwords must be 12-128 characters: letters, digits and . _ ~ -');
	}
	if ($auth && ($password !== '' || !is_file($web_config))) {
		if (!ne_write_auth($password !== '' ? $password : substr(str_replace(['+', '/', '='], '', base64_encode(random_bytes(48))), 0, 20))) {
			manage_fail(500, 'The password could not be saved in: ' . $data_path);
		}
	}
	if (!manage_write_file($settings_file, 'PORT=' . $port . "\nAUTH=" . ($auth ? 1 : 0) . "\n")) {
		manage_fail(500, 'The settings could not be saved in: ' . $settings_file);
	}
	ne_restart();
	manage_json([]);
}

if ($action === 'restart') {
	ne_restart();
	manage_json([]);
}

manage_fail(400, 'Unknown action');
