<?php
// Syncthing management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('syncthing');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path = dirname(__DIR__);
$data_path = dirname($app_path) . '/_syncthing';
$password_file = $data_path . '/gui_password';
$syncthing_url = 'http://127.0.0.1:8384';

// Calls Syncthing's REST API with the API key from its (root-only) configuration. Returns the decoded JSON, or null
function st_api($method, $path, $body = null)
{
	global $data_path, $syncthing_url;
	$config = (string)@file_get_contents($data_path . '/config.xml');
	if (!preg_match('#<apikey>([^<]+)</apikey>#', $config, $m)) {
		return null;
	}
	list($status, $response) = manage_http_request($method, $syncthing_url . $path, $body === null ? null : json_encode($body), 5,
		['X-API-Key: ' . $m[1]]);
	if ($status !== 200) {
		return null;
	}
	$data = json_decode($response, true);
	return $data === null && trim($response) === '' ? [] : $data;
}

$action = isset($_GET['action']) ? $_GET['action'] : 'status';

if ($action === 'status') {
	$running = manage_pid_running('/var/run/syncthing.pid');
	$system = $running ? st_api('GET', '/rest/system/status') : null;
	if (!is_array($system)) {
		manage_json(['running' => $running, 'answering' => false]);
	}
	$version = st_api('GET', '/rest/system/version');
	$config = st_api('GET', '/rest/config');
	$connections = st_api('GET', '/rest/system/connections');

	$folders = [];
	foreach (isset($config['folders']) ? $config['folders'] : [] as $folder) {
		$state = st_api('GET', '/rest/db/status?folder=' . rawurlencode($folder['id']));
		$folders[] = [
			'label' => $folder['label'] !== '' ? $folder['label'] : $folder['id'],
			'path' => $folder['path'],
			'state' => !empty($folder['paused']) ? 'paused' : (isset($state['state']) ? $state['state'] : ''),
			'need' => isset($state['needFiles']) ? (int)$state['needFiles'] : 0,
		];
	}
	$devices = [];
	foreach (isset($config['devices']) ? $config['devices'] : [] as $device) {
		if ($device['deviceID'] === $system['myID']) {
			continue;
		}
		$devices[] = [
			'name' => $device['name'] !== '' ? $device['name'] : substr($device['deviceID'], 0, 7),
			'connected' => !empty($connections['connections'][$device['deviceID']]['connected']),
			'paused' => !empty($device['paused']),
		];
	}

	manage_json([
		'running' => true,
		'answering' => true,
		'version' => isset($version['version']) ? ltrim($version['version'], 'v') : '',
		'device_id' => $system['myID'],
		'folders' => $folders,
		'devices' => $devices,
		// Anonymous usage reporting: above 0 when accepted, 0 when not yet asked, -1 when declined
		'usage_reporting' => isset($config['options']['urAccepted']) ? (int)$config['options']['urAccepted'] : 0,
		'gui_user' => isset($config['gui']['user']) ? $config['gui']['user'] : '',
	]);
}

manage_require_action('syncthing');

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
	// Syncthing stores it hashed, so the file is the only place it can be read back from
	if (st_api('PATCH', '/rest/config/gui', ['password' => $new]) === null) {
		manage_fail(500, 'Syncthing did not accept the new password - is it running?');
	}
	if (!manage_write_file($password_file, $new)) {
		manage_fail(500, 'The password was changed in Syncthing, but could not be saved to: ' . $password_file);
	}
	manage_json(['password' => $new]);
}

if ($action === 'usage_reporting_off') {
	if (st_api('PATCH', '/rest/config/options', ['urAccepted' => -1]) === null) {
		manage_fail(500, 'Syncthing did not accept the setting - is it running?');
	}
	manage_json([]);
}

if ($action === 'restart') {
	manage_run(['/bin/sh', $app_path . '/stop.sh', $app_path]);
	list($code, $output) = manage_run(['/bin/sh', $app_path . '/start.sh', $app_path]);
	if ($code !== 0) {
		manage_fail(500, 'Syncthing could not be started: ' . $output);
	}
	manage_json([]);
}

manage_fail(400, 'Unknown action');
