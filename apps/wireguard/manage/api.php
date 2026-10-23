<?php
// WireGuard management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('wireguard');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path = dirname(__DIR__);
$apps_path = dirname($app_path);
$data_path = $apps_path . '/_wireguard';
$settings_file = $data_path . '/settings.json';
$ctl = $app_path . '/wg_ctl.sh';
require $app_path . '/lib/wg.php';

function wg_save($file, array $settings)
{
	$text = json_encode($settings, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n";
	$ok = is_file($file) ? manage_write_file($file, $text) : file_put_contents($file, $text) !== false && chmod($file, 0600);
	if (!$ok) {
		manage_fail(500, 'The settings could not be saved');
	}
}

function wg_restart($ctl)
{
	manage_run(['/bin/sh', $ctl, 'stop']);
	list($code, $output) = manage_run(['/bin/sh', $ctl, 'start']);
	if ($code !== 0) {
		manage_fail(500, 'WireGuard could not be started: ' . $output);
	}
}

function wg_peer_index(array $settings, $id)
{
	foreach ($settings['peers'] as $i => $peer) {
		if ($peer['id'] === $id) {
			return $i;
		}
	}
	manage_fail(404, 'No such device');
}

// Where the Nginx app is set up for (its domain), as a suggested address for the devices to connect to
function wg_suggested_endpoint($apps_path)
{
	$sites = $apps_path . '/nginx/lib/sites.php';
	if (is_file($sites) && is_dir($apps_path . '/_nginx')) {
		require_once $sites;
		$nginx = sites_load($apps_path . '/_nginx');
		return $nginx['domain'];
	}
	return '';
}

$settings = wg_settings($data_path);
$action = isset($_GET['action']) ? $_GET['action'] : 'status';

if ($action === 'status') {
	$running = manage_pid_running('/var/run/wireguard-go.pid');
	// Each device's latest handshake and traffic (wg show's dump: the interface first, then one line per peer)
	$live = [];
	if ($running) {
		list(, $dump) = manage_run([$app_path . '/binaries/wg', 'show', WG_INTERFACE, 'dump']);
		foreach (array_slice(explode("\n", $dump), 1) as $line) {
			$f = explode("\t", $line);
			if (count($f) >= 8) {
				$live[$f[0]] = ['endpoint' => $f[2] === '(none)' ? '' : preg_replace('/:\d+$/', '', $f[2]),
					'handshake' => (int)$f[4], 'received' => (int)$f[5], 'sent' => (int)$f[6]];
			}
		}
	}
	$peers = [];
	foreach ($settings['peers'] as $peer) {
		$peers[] = ['id' => $peer['id'], 'name' => $peer['name'], 'address' => $peer['address'], 'enabled' => !empty($peer['enabled']),
			'live' => isset($live[$peer['public']]) ? $live[$peer['public']] : null];
	}
	$log = array_values(array_filter(@file($data_path . '/wireguard.log', FILE_IGNORE_NEW_LINES) ?: [], function ($line) {
		return trim($line) !== '';
	}));
	$lan = wg_lan();
	manage_json([
		'running' => $running,
		'version' => preg_match('/^Version:\s*(\S+)/m', (string)@file_get_contents($app_path . '/apkg.rc'), $m) ? $m[1] : '',
		// (wireguard-tools' wg: e.g. "wireguard-tools v1.0.20260223 - https://...")
		'tools_version' => preg_match('/wireguard-tools v(\S+)/', manage_run([$app_path . '/binaries/wg', '--version'])[1], $m) ? $m[1] : '',
		'port' => (int)$settings['port'],
		'subnet' => $settings['subnet'],
		'address' => wg_server_address($settings['subnet']),
		'endpoint' => $settings['endpoint'],
		'suggested_endpoint' => wg_suggested_endpoint($apps_path),
		'dns' => $settings['dns'],
		'default_dns' => wg_default_dns(),
		'access' => $settings['access'],
		'lan' => $lan,
		'now' => time(),
		'peers' => $peers,
		'log' => array_slice($log, -20),
	]);
}

manage_require_action('wireguard');

if ($action === 'add_peer') {
	$name = isset($_POST['name']) ? trim((string)$_POST['name']) : '';
	if ($name === '' || mb_strlen($name) > 40 || preg_match('/[\x00-\x1f]/', $name)) {
		manage_fail(400, 'Give the device a name (up to 40 characters), e.g. Paul\'s phone');
	}
	if ($settings['endpoint'] === '') {
		manage_fail(400, 'First set the address devices connect to (under Settings): their configurations need it');
	}
	$address = wg_free_address($settings);
	if ($address === null) {
		manage_fail(400, 'The address range is full: choose a larger one below');
	}
	list($private, $public) = wg_keys($app_path);
	$psk = wg_tool($app_path, ['wg', 'genpsk']);
	if (strlen($private) !== 44 || strlen($public) !== 44 || strlen($psk) !== 44) {
		manage_fail(500, 'The device\'s keys could not be made');
	}
	$peer = ['id' => bin2hex(random_bytes(6)), 'name' => $name, 'address' => $address, 'private' => $private, 'public' => $public,
		'psk' => $psk, 'enabled' => true];
	$settings['peers'][] = $peer;
	wg_save($settings_file, $settings);
	wg_server_keys($data_path, $app_path);
	manage_run(['/bin/sh', $ctl, 'reload']);
	manage_json(['id' => $peer['id']]);
}

if ($action === 'peer_config') {
	$peer = $settings['peers'][wg_peer_index($settings, isset($_POST['id']) ? (string)$_POST['id'] : '')];
	list(, $server_public) = wg_server_keys($data_path, $app_path);
	$conf = wg_client_conf($settings, $peer, $server_public);
	list(, $svg) = manage_run([$app_path . '/binaries/qrencode', '-t', 'SVG', '-m', '2', '-o', '-'], [], $conf);
	manage_json(['name' => $peer['name'], 'config' => $conf, 'qr' => strpos($svg, '<svg') !== false ? base64_encode($svg) : '',
		'file' => preg_replace('/[^A-Za-z0-9_-]+/', '-', $peer['name']) . '.conf']);
}

if ($action === 'switch_peer' || $action === 'remove_peer') {
	$i = wg_peer_index($settings, isset($_POST['id']) ? (string)$_POST['id'] : '');
	if ($action === 'remove_peer') {
		array_splice($settings['peers'], $i, 1);
	} else {
		$settings['peers'][$i]['enabled'] = !empty($_POST['enabled']);
	}
	wg_save($settings_file, $settings);
	manage_run(['/bin/sh', $ctl, 'reload']);
	manage_json([]);
}

if ($action === 'settings') {
	$endpoint = isset($_POST['endpoint']) ? strtolower(trim((string)$_POST['endpoint'])) : '';
	$port = isset($_POST['port']) ? (int)$_POST['port'] : 0;
	$subnet = isset($_POST['subnet']) ? trim((string)$_POST['subnet']) : '';
	$dns = isset($_POST['dns']) ? preg_replace('/\s*,\s*/', ', ', trim((string)$_POST['dns'])) : '';
	$access = isset($_POST['access']) ? (string)$_POST['access'] : '';
	if ($endpoint !== '' && (strlen($endpoint) > 253 || !preg_match('/^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)*[a-z0-9]([a-z0-9-]*[a-z0-9])?$/', $endpoint))) {
		manage_fail(400, 'The address must be a domain name (e.g. home.example.com) or your internet IP address');
	}
	if ($port < 1024 || $port > 65535) {
		manage_fail(400, 'The port must be between 1024 and 65535 (WireGuard\'s usual one is 51820)');
	}
	$parts = wg_subnet($subnet);
	if ($parts === null) {
		manage_fail(400, 'The address range must be a private one, e.g. 10.8.0.0/24');
	}
	$lan = wg_lan();
	if ($lan['subnet'] !== '' && ($lan_parts = wg_subnet($lan['subnet'])) !== null) {
		$bits = min($parts[1], $lan_parts[1]);
		$mask = (0xFFFFFFFF << (32 - $bits)) & 0xFFFFFFFF;
		if (($parts[0] & $mask) === ($lan_parts[0] & $mask)) {
			manage_fail(400, 'The address range overlaps the home network (' . $lan['subnet'] . '): choose another, e.g. 10.8.0.0/24');
		}
	}
	foreach ($dns === '' ? [] : explode(', ', $dns) as $server) {
		if (!filter_var($server, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) {
			manage_fail(400, 'DNS servers are IPv4 addresses, separated by commas: ' . $server);
		}
	}
	if (!in_array($access, WG_ACCESS, true)) {
		manage_fail(400, 'Unknown access: ' . $access);
	}
	// A new address range: the devices move to the same places in it (their configurations must be added again)
	$normalised = long2ip($parts[0]) . '/' . $parts[1];
	if ($normalised !== $settings['subnet']) {
		list($old_network) = wg_subnet($settings['subnet']);
		$size = 1 << (32 - $parts[1]);
		foreach ($settings['peers'] as &$peer) {
			$offset = ip2long($peer['address']) - $old_network;
			if ($offset < 2 || $offset >= $size - 1) {
				manage_fail(400, 'The new address range is too small for the devices: choose a larger one');
			}
			$peer['address'] = long2ip($parts[0] + $offset);
		}
		unset($peer);
	}
	$settings = array_merge($settings, ['endpoint' => $endpoint, 'port' => $port, 'subnet' => $normalised, 'dns' => $dns,
		'access' => $access]);
	wg_save($settings_file, $settings);
	wg_restart($ctl);
	manage_json([]);
}

if ($action === 'restart') {
	wg_restart($ctl);
	manage_json([]);
}

manage_fail(400, 'Unknown action');
