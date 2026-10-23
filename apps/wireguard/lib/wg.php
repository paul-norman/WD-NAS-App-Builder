<?php
// WireGuard's settings and configurations. Used by the management page, and by wg_ctl.sh through the NAS's PHP CLI (WD's
// PHP 7.4, or the PHP app's 8.5), so it must work on both:
//     php wg.php setconf <data path> <app path>  - prints the interface's configuration (for wg setconf)
//     php wg.php env <data path>                 - prints the settings wg_ctl.sh needs, as shell variables
//
// The settings (settings.json, root only) hold each device's keys: the page shows a device's configuration (and its QR
// code) again whenever it's needed. The server's private key is in its own file (server_key, root only)

const WG_INTERFACE = 'wg0';
const WG_DEFAULT_PORT = 51820;
const WG_DEFAULT_SUBNET = '10.8.0.0/24';
// What the devices can reach through the NAS: the NAS only, the NAS and the home network, or everything (all their
// internet traffic goes through home)
const WG_ACCESS = ['nas', 'lan', 'all'];

function wg_settings($data_path)
{
	$settings = json_decode((string)@file_get_contents($data_path . '/settings.json'), true);
	if (!is_array($settings)) {
		$settings = [];
	}
	return $settings + ['port' => WG_DEFAULT_PORT, 'subnet' => WG_DEFAULT_SUBNET, 'endpoint' => '', 'dns' => '',
		'access' => 'lan', 'peers' => []];
}

// Runs a WireGuard tool from the app (no shell), with input. Returns its output, trimmed
function wg_tool($app_path, array $command, $input = '')
{
	$process = proc_open(array_merge([$app_path . '/binaries/' . array_shift($command)], $command),
		[0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
	if (!is_resource($process)) {
		return '';
	}
	fwrite($pipes[0], $input);
	fclose($pipes[0]);
	$output = stream_get_contents($pipes[1]);
	fclose($pipes[1]);
	fclose($pipes[2]);
	proc_close($process);
	return trim($output);
}

// A new key pair: [private, public]
function wg_keys($app_path)
{
	$private = wg_tool($app_path, ['wg', 'genkey']);
	return [$private, wg_tool($app_path, ['wg', 'pubkey'], $private . "\n")];
}

// The server's key pair (made the first time)
function wg_server_keys($data_path, $app_path)
{
	$file = $data_path . '/server_key';
	$private = trim((string)@file_get_contents($file));
	if ($private === '') {
		list($private) = wg_keys($app_path);
		$old = umask(077);
		file_put_contents($file, $private . "\n");
		umask($old);
	}
	return [$private, wg_tool($app_path, ['wg', 'pubkey'], $private . "\n")];
}

// The subnet's parts: [network address as a number, prefix length], or null if it isn't a private IPv4 /16-/29 subnet
function wg_subnet($subnet)
{
	if (!preg_match('#^(\d{1,3}(\.\d{1,3}){3})/(\d{1,2})$#', $subnet, $m) || ip2long($m[1]) === false) {
		return null;
	}
	$bits = (int)$m[3];
	$address = ip2long($m[1]);
	$private = ($address & 0xFF000000) === 0x0A000000 || ($address & 0xFFF00000) === 0xAC100000 || ($address & 0xFFFF0000) === 0xC0A80000;
	if ($bits < 16 || $bits > 29 || !$private) {
		return null;
	}
	$mask = (0xFFFFFFFF << (32 - $bits)) & 0xFFFFFFFF;
	return [$address & $mask, $bits];
}

// The NAS's address in the VPN (the subnet's first)
function wg_server_address($subnet)
{
	list($network) = wg_subnet($subnet);
	return long2ip($network + 1);
}

// The next free address for a device (null when the subnet is full)
function wg_free_address(array $settings)
{
	list($network, $bits) = wg_subnet($settings['subnet']);
	$used = array_map(function ($peer) { return $peer['address']; }, $settings['peers']);
	for ($i = 2; $i < (1 << (32 - $bits)) - 1; $i++) {
		if (!in_array(long2ip($network + $i), $used, true)) {
			return long2ip($network + $i);
		}
	}
	return null;
}

// The home network, from the NAS's routes: ['device' => e.g. bond0, 'subnet' => e.g. 192.168.1.0/24, 'address' => the
// NAS's address in it, 'gateway' => the router] - empty strings where unknown
function wg_lan()
{
	$lan = ['device' => '', 'subnet' => '', 'address' => '', 'gateway' => ''];
	$routes = (string)shell_exec('ip -4 route 2>/dev/null');
	if (preg_match('/^default via (\S+) dev (\S+)/m', $routes, $m)) {
		$lan['gateway'] = $m[1];
		$lan['device'] = $m[2];
		if (preg_match('#^(\d+\.\d+\.\d+\.\d+/\d+) dev ' . preg_quote($m[2], '#') . '\b.*?src (\S+)#m', $routes, $n)) {
			$lan['subnet'] = $n[1];
			$lan['address'] = $n[2];
		}
	}
	return $lan;
}

// The NAS's own DNS server (the first in /etc/resolv.conf), if it's on a private network - for the devices to use
function wg_default_dns()
{
	if (preg_match('/^nameserver\s+(\d+\.\d+\.\d+\.\d+)/m', (string)@file_get_contents('/etc/resolv.conf'), $m)) {
		$address = ip2long($m[1]);
		if (($address & 0xFF000000) === 0x0A000000 || ($address & 0xFFF00000) === 0xAC100000 || ($address & 0xFFFF0000) === 0xC0A80000) {
			return $m[1];
		}
	}
	return '';
}

// What a device sends through the VPN (its AllowedIPs)
function wg_client_routes(array $settings)
{
	if ($settings['access'] === 'all') {
		// (IPv6 too, so that it can't go around the VPN: the NAS doesn't pass it on)
		return '0.0.0.0/0, ::/0';
	}
	$routes = [$settings['subnet']];
	$lan = wg_lan();
	if ($settings['access'] === 'lan' && $lan['subnet'] !== '') {
		$routes[] = $lan['subnet'];
	}
	return implode(', ', $routes);
}

// A device's own configuration (for its WireGuard app)
function wg_client_conf(array $settings, array $peer, $server_public)
{
	list(, $bits) = wg_subnet($settings['subnet']);
	$dns = $settings['access'] === 'nas' ? '' : ($settings['dns'] !== '' ? $settings['dns'] : wg_default_dns());
	return "[Interface]\n"
		. "# {$peer['name']}\n"
		. "PrivateKey = {$peer['private']}\n"
		. "Address = {$peer['address']}/32\n"
		. ($dns !== '' ? "DNS = {$dns}\n" : '')
		. "\n[Peer]\n"
		. "# The NAS\n"
		. "PublicKey = {$server_public}\n"
		. "PresharedKey = {$peer['psk']}\n"
		. "Endpoint = {$settings['endpoint']}:{$settings['port']}\n"
		. "AllowedIPs = " . wg_client_routes($settings) . "\n"
		// (keeps the connection open through the device's own router)
		. "PersistentKeepalive = 25\n";
}

// The NAS's interface configuration (wg setconf's format): its key and port, and each device switched on
function wg_server_conf(array $settings, $server_private)
{
	$conf = "[Interface]\nPrivateKey = {$server_private}\nListenPort = {$settings['port']}\n";
	foreach ($settings['peers'] as $peer) {
		if (!empty($peer['enabled'])) {
			$conf .= "\n[Peer]\nPublicKey = {$peer['public']}\nPresharedKey = {$peer['psk']}\nAllowedIPs = {$peer['address']}/32\n";
		}
	}
	return $conf;
}

if (PHP_SAPI === 'cli' && isset($argv[0]) && realpath($argv[0]) === __FILE__) {
	$command = isset($argv[1]) ? $argv[1] : '';
	if ($command === 'setconf' && isset($argv[2], $argv[3])) {
		$settings = wg_settings($argv[2]);
		list($private) = wg_server_keys($argv[2], $argv[3]);
		echo wg_server_conf($settings, $private);
	} elseif ($command === 'env' && isset($argv[2])) {
		$settings = wg_settings($argv[2]);
		$lan = wg_lan();
		list(, $bits) = wg_subnet($settings['subnet']) ?: [0, 24];
		// (all values checked by the page when saved; quoted for the shell anyway)
		foreach (['WG_PORT' => $settings['port'], 'WG_SUBNET' => $settings['subnet'],
			'WG_ADDRESS' => wg_server_address($settings['subnet']) . '/' . $bits, 'WG_ACCESS' => $settings['access'],
			'LAN_DEVICE' => $lan['device'], 'LAN_SUBNET' => $lan['subnet']] as $name => $value) {
			echo $name . '=' . escapeshellarg((string)$value) . "\n";
		}
	} else {
		fwrite(STDERR, "Usage: php wg.php setconf <data path> <app path> | env <data path>\n");
		exit(2);
	}
}
