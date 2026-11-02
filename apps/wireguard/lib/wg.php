<?php
// WireGuard's settings and configurations. Used by the management page, and by wg_ctl.sh through the NAS's PHP CLI
// WD's PHP 7.4, or the PHP app's 8.5, so it must work on both:
//     php wg.php setconf <data path> <app path>  - prints the interface's configuration (for wg setconf)
//     php wg.php env <data path>                 - prints the settings wg_ctl.sh needs, as shell variables
//
// The settings (settings.json, root only) hold each device's keys: the page shows a device's configuration (and its QR
// code) again whenever it's needed. The server's private key is in its own file (server_key, root only)

const WG_INTERFACE      = 'wg0';
const WG_DEFAULT_PORT   = 51820;
const WG_DEFAULT_SUBNET = '10.8.0.0/24';
// What the devices can reach through the NAS: the NAS only, the NAS and the home network, or everything (all their
// internet traffic goes through home)
const WG_ACCESS         = ['nas', 'lan', 'all'];

/**
 * WireGuard's settings (settings.json, root only), with the defaults for any not saved.
 *
 * @param string $data_path The app's data folder
 *
 * @return array<string, mixed> port, subnet, endpoint, dns, access and peers (the devices, with their keys)
 */
function wg_settings(string $data_path): array
{
    $settings = json_decode((string)@file_get_contents($data_path.'/settings.json'), true);

    if (!is_array($settings)) {
        $settings = [];
    }

    return $settings + [
        'port'     => WG_DEFAULT_PORT,
        'subnet'   => WG_DEFAULT_SUBNET,
        'endpoint' => '',
        'dns'      => '',
        'access'   => 'lan',
        'peers'    => [],
    ];
}

/**
 * Runs a WireGuard tool from the app (no shell), with input.
 *
 * @param string       $app_path The app's folder
 * @param list<string> $command  The tool (in binaries/) and its arguments
 * @param string       $input    What to give it on its standard input
 *
 * @return string Its output, trimmed ('' if it couldn't be run)
 */
function wg_tool(string $app_path, array $command, string $input = ''): string
{
    $process = proc_open(array_merge([$app_path.'/binaries/'.array_shift($command)], $command),
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

/**
 * A new key pair.
 *
 * @param string $app_path The app's folder
 *
 * @return array{ 0: string, 1: string } [private, public]
 */
function wg_keys(string $app_path): array
{
    $private = wg_tool($app_path, ['wg', 'genkey']);

    return [$private, wg_tool($app_path, ['wg', 'pubkey'], $private."\n")];
}

/**
 * The server's key pair: its private key is made the first time, and kept in its own file (server_key, root only).
 *
 * @param string $data_path The app's data folder
 * @param string $app_path  The app's folder
 *
 * @return array{ 0: string, 1: string } [private, public]
 */
function wg_server_keys(string $data_path, string $app_path): array
{
    $file    = $data_path.'/server_key';
    $private = trim((string)@file_get_contents($file));

    if ($private === '') {
        list($private) = wg_keys($app_path);

        $old = umask(077);

        file_put_contents($file, $private."\n");
        umask($old);
    }

    return [$private, wg_tool($app_path, ['wg', 'pubkey'], $private."\n")];
}

/**
 * A subnet's parts, if it's a private IPv4 subnet from /16 to /29.
 *
 * @param mixed $subnet The subnet (e.g. 10.8.0.0/24)
 *
 * @return array{ 0: int, 1: int }|null [network address as a number, prefix length], or null
 */
function wg_subnet($subnet): ?array
{
    if (!preg_match('#^(\d{1,3}(\.\d{1,3}){3})/(\d{1,2})$#', $subnet, $m) || ip2long($m[1]) === false) {
        return null;
    }

    $bits    = (int)$m[3];
    $address = ip2long($m[1]);
    $private = ($address & 0xFF000000) === 0x0A000000 || ($address & 0xFFF00000) === 0xAC100000 || ($address & 0xFFFF0000) === 0xC0A80000;

    if ($bits < 16 || $bits > 29 || !$private) {
        return null;
    }

    $mask = (0xFFFFFFFF << (32 - $bits)) & 0xFFFFFFFF;

    return [$address & $mask, $bits];
}

/**
 * The NAS's address in the VPN: the subnet's first.
 *
 * @param mixed $subnet The subnet (checked: see wg_subnet())
 *
 * @return string The address
 */
function wg_server_address($subnet): string
{
    list($network) = wg_subnet($subnet);

    return long2ip($network + 1);
}

/**
 * The next free address for a device.
 *
 * @param array<string, mixed> $settings The settings (see wg_settings())
 *
 * @return string|null The address, or null when the subnet is full
 */
function wg_free_address(array $settings): ?string
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

/**
 * The home network, from the NAS's routes.
 *
 * @return array{
 *     device:  string,
 *     subnet:  string,
 *     address: string,
 *     gateway: string,
 * } Its device (e.g. bond0), subnet (e.g. 192.168.1.0/24), the NAS's address in it and the router - '' where unknown
 */
function wg_lan(): array
{
    $lan    = ['device' => '', 'subnet' => '', 'address' => '', 'gateway' => ''];
    $routes = (string)shell_exec('ip -4 route 2>/dev/null');

    if (preg_match('/^default via (\S+) dev (\S+)/m', $routes, $m)) {
        $lan['gateway'] = $m[1];
        $lan['device'] = $m[2];

        if (preg_match('#^(\d+\.\d+\.\d+\.\d+/\d+) dev '.preg_quote($m[2], '#').'\b.*?src (\S+)#m', $routes, $n)) {
            $lan['subnet'] = $n[1];
            $lan['address'] = $n[2];
        }
    }

    return $lan;
}

/**
 * The NAS's own DNS server (the first in /etc/resolv.conf), if it's on a private network - for the devices to use.
 *
 * @return string Its address, or ''
 */
function wg_default_dns(): string
{
    if (preg_match('/^nameserver\s+(\d+\.\d+\.\d+\.\d+)/m', (string)@file_get_contents('/etc/resolv.conf'), $m)) {
        $address = ip2long($m[1]);

        if (($address & 0xFF000000) === 0x0A000000 || ($address & 0xFFF00000) === 0xAC100000 || ($address & 0xFFFF0000) === 0xC0A80000) {
            return $m[1];
        }
    }

    return '';
}

/**
 * What a device sends through the VPN (its AllowedIPs): everything (IPv6 too, so that it can't go around the VPN - the
 * NAS doesn't pass it on), the VPN and the home network, or the VPN only.
 *
 * @param array<string, mixed> $settings The settings (see wg_settings())
 *
 * @return string The routes, separated by commas
 */
function wg_client_routes(array $settings): string
{
    if ($settings['access'] === 'all') {
        // IPv6 too, so that it can't go around the VPN: the NAS doesn't pass it on
        return '0.0.0.0/0, ::/0';
    }

    $routes = [$settings['subnet']];
    $lan    = wg_lan();

    if ($settings['access'] === 'lan' && $lan['subnet'] !== '') {
        $routes[] = $lan['subnet'];
    }

    return implode(', ', $routes);
}

/**
 * A device's own configuration, for its WireGuard app (and its QR code).
 *
 * @param array<string, mixed> $settings      The settings (see wg_settings())
 * @param array<string, mixed> $peer          The device
 * @param string               $server_public The NAS's public key
 *
 * @return string The configuration
 */
function wg_client_conf(array $settings, array $peer, string $server_public): string
{
    list(, $bits) = wg_subnet($settings['subnet']);

    $dns = $settings['access'] === 'nas' ? '' : ($settings['dns'] !== '' ? $settings['dns'] : wg_default_dns());

    return "[Interface]\n"
        ."# {$peer['name']}\n"
        ."PrivateKey = {$peer['private']}\n"
        ."Address = {$peer['address']}/32\n"
        .($dns !== '' ? "DNS = {$dns}\n" : '')
        ."\n[Peer]\n"
        ."# The NAS\n"
        ."PublicKey = {$server_public}\n"
        ."PresharedKey = {$peer['psk']}\n"
        ."Endpoint = {$settings['endpoint']}:{$settings['port']}\n"
        .'AllowedIPs = '.wg_client_routes($settings)."\n"
        // Keeps the connection open through the device's own router
        ."PersistentKeepalive = 25\n";
}

/**
 * The NAS's interface configuration, in wg setconf's format: its key and port, and each device switched on.
 *
 * @param array<string, mixed> $settings       The settings (see wg_settings())
 * @param string               $server_private The NAS's private key
 *
 * @return string The configuration
 */
function wg_server_conf(array $settings, string $server_private): string
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
    $command = $argv[1] ?? '';

    if ($command === 'setconf' && isset($argv[2], $argv[3])) {
        $settings = wg_settings($argv[2]);

        list($private) = wg_server_keys($argv[2], $argv[3]);

        echo wg_server_conf($settings, $private);
    } elseif ($command === 'env' && isset($argv[2])) {
        $settings = wg_settings($argv[2]);
        $lan      = wg_lan();

        list(, $bits) = wg_subnet($settings['subnet']) ?: [0, 24];

        // All values checked by the page when saved; quoted for the shell anyway
        foreach ([
            'WG_PORT'    => $settings['port'],
            'WG_SUBNET'  => $settings['subnet'],
            'WG_ADDRESS' => wg_server_address($settings['subnet']).'/'.$bits,
            'WG_ACCESS'  => $settings['access'],
            'LAN_DEVICE' => $lan['device'],
            'LAN_SUBNET' => $lan['subnet']] as $name => $value) {
            echo $name.'='.escapeshellarg((string)$value)."\n";
        }
    } else {
        fwrite(STDERR, "Usage: php wg.php setconf <data path> <app path> | env <data path>\n");

        exit(2);
    }
}
