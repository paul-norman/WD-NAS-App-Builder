<?php
// Tailscale management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('tailscale');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path = dirname(__DIR__);
$cli = $app_path . '/binaries/tailscale';
$upload_logs_file = dirname($app_path) . '/_tailscale/upload_logs';
$default_server = 'https://controlplane.tailscale.com';

// Runs the tailscale command and decodes its JSON output (or returns null)
function ts_json($cli, array $args)
{
	list($code, $output) = manage_run(array_merge([$cli], $args));
	$data = $code === 0 ? json_decode($output, true) : null;
	return is_array($data) ? $data : null;
}

// The NAS's own local network (e.g. 192.168.1.0/24), suggested for sharing with the tailnet
function ts_lan_subnet()
{
	list(, $routes) = manage_run(['ip', '-o', '-4', 'route', 'show']);
	foreach (explode("\n", $routes) as $route) {
		if (preg_match('#^(\d+\.\d+\.\d+\.\d+/\d+) dev (\S+) .*scope link#', $route, $m) && !preg_match('/^(docker|br-|veth|tailscale|lo)/', $m[2])) {
			return $m[1];
		}
	}
	return '';
}

// IP forwarding is needed to share networks or act as an exit node (Docker turns it on too)
function ts_enable_forwarding()
{
	@file_put_contents('/proc/sys/net/ipv4/ip_forward', "1\n");
	@file_put_contents('/proc/sys/net/ipv6/conf/all/forwarding', "1\n");
}

$action = isset($_GET['action']) ? $_GET['action'] : 'status';

if ($action === 'status') {
	$status = ts_json($cli, ['status', '--json']);
	if ($status === null) {
		manage_json(['running' => false]);
	}
	$prefs = ts_json($cli, ['debug', 'prefs']);
	$routes = isset($prefs['AdvertiseRoutes']) && is_array($prefs['AdvertiseRoutes']) ? $prefs['AdvertiseRoutes'] : [];

	$peers = [];
	foreach (isset($status['Peer']) && is_array($status['Peer']) ? $status['Peer'] : [] as $peer) {
		$peers[] = [
			'name' => isset($peer['HostName']) ? $peer['HostName'] : '',
			'ip' => isset($peer['TailscaleIPs'][0]) ? $peer['TailscaleIPs'][0] : '',
			'os' => isset($peer['OS']) ? $peer['OS'] : '',
			'online' => !empty($peer['Online']),
		];
	}

	manage_json([
		'running' => true,
		'state' => isset($status['BackendState']) ? $status['BackendState'] : '',
		'auth_url' => isset($status['AuthURL']) ? $status['AuthURL'] : '',
		'version' => isset($status['Version']) ? preg_replace('/-.*/', '', $status['Version']) : '',
		'tailnet' => isset($status['CurrentTailnet']['Name']) ? $status['CurrentTailnet']['Name'] : '',
		'name' => isset($status['Self']['DNSName']) ? rtrim($status['Self']['DNSName'], '.') : '',
		'ips' => isset($status['Self']['TailscaleIPs']) && is_array($status['Self']['TailscaleIPs']) ? $status['Self']['TailscaleIPs'] : [],
		'peers' => $peers,
		'routes' => array_values(array_diff($routes, ['0.0.0.0/0', '::/0'])),
		'exit_node' => in_array('0.0.0.0/0', $routes, true),
		'lan_subnet' => ts_lan_subnet(),
		'login_server' => !empty($prefs['ControlURL']) ? $prefs['ControlURL'] : $default_server,
		'default_server' => $default_server,
		'upload_logs' => is_file($upload_logs_file),
	]);
}

manage_require_action('tailscale');

if ($action === 'login') {
	// The coordination server: Tailscale's own, or a self-hosted one (e.g. Headscale)
	$server = isset($_POST['login_server']) ? trim((string)$_POST['login_server']) : '';
	if ($server === '') {
		$server = $default_server;
	} elseif (!preg_match('#^https?://[A-Za-z0-9.-]+(:\d{1,5})?(/[A-Za-z0-9._~/-]*)?$#', $server)) {
		manage_fail(400, 'The login server must be a web address, e.g. https://headscale.example.com');
	}

	// Starts a login and waits briefly for the server to issue its link (the login finishes when the link is opened).
	// Privacy: the NAS keeps its own DNS servers (e.g. a Pi-hole), rather than switching to Tailscale's MagicDNS
	manage_run([$cli, 'login', '--timeout=5s', '--login-server=' . $server, '--accept-dns=false']);
	$status = ts_json($cli, ['status', '--json']);
	$url = isset($status['AuthURL']) ? $status['AuthURL'] : '';
	if ($url === '' && (!isset($status['BackendState']) || $status['BackendState'] !== 'Running')) {
		manage_fail(500, 'No login link was provided - can the NAS reach ' . parse_url($server, PHP_URL_HOST) . '?');
	}
	manage_json(['auth_url' => $url]);
}

if ($action === 'logout') {
	list($code, $output) = manage_run([$cli, 'logout']);
	if ($code !== 0) {
		manage_fail(500, 'Could not log out: ' . $output);
	}
	manage_json([]);
}

if ($action === 'set_options') {
	// Networks to share: comma-separated IPv4 / IPv6 networks (CIDR notation), or none
	$routes = isset($_POST['routes']) ? preg_replace('/\s+/', '', (string)$_POST['routes']) : '';
	foreach ($routes === '' ? [] : explode(',', $routes) as $route) {
		if (!preg_match('#^(\d{1,3}(\.\d{1,3}){3}/\d{1,2}|[0-9a-fA-F:]+/\d{1,3})$#', $route)) {
			manage_fail(400, 'Not a network in CIDR notation (e.g. 192.168.1.0/24): ' . $route);
		}
	}
	$exit_node = !empty($_POST['exit_node']);

	if ($routes !== '' || $exit_node) {
		ts_enable_forwarding();
	}
	list($code, $output) = manage_run([$cli, 'set', '--advertise-routes=' . $routes, '--advertise-exit-node=' . ($exit_node ? 'true' : 'false')]);
	if ($code !== 0) {
		manage_fail(500, 'Tailscale refused the settings: ' . $output);
	}
	manage_json([]);
}

if ($action === 'set_logs') {
	// Uploading logs to Tailscale (needed for their support) is off unless allowed here; tailscaled restarts to apply it
	if (!empty($_POST['upload_logs'])) {
		touch($upload_logs_file);
	} else {
		@unlink($upload_logs_file);
	}
	manage_run(['/bin/sh', $app_path . '/stop.sh', $app_path]);
	list($code, $output) = manage_run(['/bin/sh', $app_path . '/start.sh', $app_path]);
	if ($code !== 0) {
		manage_fail(500, 'Tailscale could not be restarted: ' . $output);
	}
	manage_json(['upload_logs' => is_file($upload_logs_file)]);
}

manage_fail(400, 'Unknown action');
