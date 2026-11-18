<?php
// AdGuard Home management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('adguardhome');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path      = dirname(__DIR__);
$apps_path     = dirname($app_path);
$data_path     = $apps_path.'/_adguardhome';
$settings_file = $data_path.'/settings';
$ctl           = $app_path.'/adguardhome_ctl.sh';

require $app_path.'/lib/adguardhome.php';

/**
 * The app's settings, with defaults.
 *
 * @param string $file The settings file (KEY=value lines, also read by the app's control script)
 *
 * @return array{ LISTEN: string, BACKUP_KEEP: string } The settings
 */
function adguardhome_settings(string $file): array
{
    $settings = [
        'LISTEN'      => 'local',
        'BACKUP_KEEP' => '14',
    ];

    foreach (@file($file, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
        if (preg_match('/^([A-Z_]+)=(.*)$/', $line, $m) && isset($settings[$m[1]])) {
            $settings[$m[1]] = $m[2];
        }
    }

    return $settings;
}

/**
 * Restarts AdGuard Home with its control script (stop, then start), failing the request if it doesn't start.
 *
 * @param string $ctl The app's control script
 *
 * @return void
 */
function adguardhome_restart(string $ctl): void
{
    manage_run(['/bin/sh', $ctl, 'stop']);

    list($code, $output) = manage_run(['/bin/sh', $ctl, 'start']);

    if ($code !== 0) {
        manage_fail(500, 'AdGuard Home could not be started: '.$output);
    }
}

/**
 * The backups in Nas_Prog/_adguardhome/backups, newest first.
 *
 * @param string $data_path The app's data folder
 *
 * @return list<array{ name: string, size: int, time: int }> Each backup's file name, size (bytes) and time (seconds
 *                                                           since 1970)
 */
function adguardhome_backups(string $data_path): array
{
    $list = [];

    foreach (glob($data_path.'/backups/adguardhome-*.tar.gz') ?: [] as $file) {
        $list[] = ['name' => basename($file), 'size' => (int)filesize($file), 'time' => (int)filemtime($file)];
    }

    usort($list, function (array $a, array $b): int {
        return strcmp($b['name'], $a['name']);
    });

    return $list;
}

/**
 * A system program, where the NAS keeps it (the page's PHP may not have /usr/sbin in its PATH).
 *
 * @param string $name Its name (e.g. iptables)
 *
 * @return string Its path, or the name itself if it's in none of the usual folders
 */
function adguardhome_program(string $name): string
{
    foreach (['/usr/sbin', '/sbin', '/usr/bin', '/bin'] as $folder) {
        if (is_executable($folder.'/'.$name)) {
            return $folder.'/'.$name;
        }
    }

    return $name;
}

/**
 * The NAS's own IPv4 addresses (not the loopback's): the devices on the network use AdGuard Home at these.
 *
 * @return list<string> The addresses
 */
function adguardhome_addresses(): array
{
    list(, $output) = manage_run([adguardhome_program('ip'), '-4', '-o', 'addr', 'show']);

    preg_match_all('#\sinet\s+([0-9.]+)/#', $output, $m);

    return array_values(array_unique(array_filter($m[1], function (string $address): bool {
        return strpos($address, '127.') !== 0;
    })));
}

/**
 * The last line of a command's output (its message, without what came before it).
 *
 * @param string $output The output
 *
 * @return string The line
 */
function adguardhome_last_line(string $output): string
{
    $lines = preg_split('/\R/', trim($output)) ?: [];

    return (string)end($lines);
}

$settings = adguardhome_settings($settings_file);
$action   = $_GET['action'] ?? 'status';

if ($action === 'status') {
    $running = manage_pid_running('/var/run/adguardhome.pid');

    // (its API, which asks for a login: 401)
    list($code) = $running ? manage_http_get(ADGUARDHOME_TARGET.'/control/status') : [0, ''];

    // Its version: the app's, without the app's packaging revision
    $rc      = (string)@file_get_contents($app_path.'/apkg.rc');
    $version = preg_match('/^Version:\s*(\S+)/m', $rc, $m) ? (string)preg_replace('/-[0-9]+$/', '', $m[1]) : '';
    $log     = @file($data_path.'/adguardhome.log', FILE_IGNORE_NEW_LINES) ?: [];

    // Whether the network's DNS (port 53) is forwarded to it: its NAT chain has rules
    list(, $rules) = manage_run([adguardhome_program('iptables'), '-t', 'nat', '-S', 'ADGUARDHOME']);

    manage_json([
        'running'     => $running,
        'answering'   => $code === 401 || $code === 200,
        'version'     => $version,
        'site'        => manage_nginx_site($apps_path, ADGUARDHOME_TARGET),
        'admin'       => ADGUARDHOME_ADMIN,
        'dns'         => adguardhome_addresses(),
        'forwarding'  => $running && strpos($rules, '--dport 53') !== false,
        'problem'     => trim((string)@file_get_contents($data_path.'/problem')),
        'listen'      => $settings['LISTEN'] === 'all' ? 'all' : 'local',
        'backup_keep' => (int)$settings['BACKUP_KEEP'],
        'backups'     => array_slice(adguardhome_backups($data_path), 0, 5),
        'log'         => array_slice($log, -20),
    ]);
}

manage_require_action('adguardhome');

if ($action === 'password') {
    manage_json(['password' => trim((string)@file_get_contents($data_path.'/admin_password'))]);
}

if ($action === 'new_password') {
    // The password typed (any visible characters), or a generated one
    $password = manage_new_password(isset($_POST['password']) ? (string)$_POST['password'] : '', 12, 72, true);

    list($code, $output) = manage_run(['/bin/sh', $ctl, 'set-password'], [], $password."\n");

    if ($code !== 0) {
        manage_fail(500, 'A new password could not be set: '.adguardhome_last_line($output));
    }

    manage_json(['password' => trim((string)@file_get_contents($data_path.'/admin_password'))]);
}

if ($action === 'settings') {
    $keep = isset($_POST['backup_keep']) ? (string)$_POST['backup_keep'] : '';

    if (!preg_match('/^[0-9]{1,2}$/', $keep) || (int)$keep < 1) {
        manage_fail(400, 'Keep 1 to 99 backups');
    }

    $text = 'LISTEN='.(isset($_POST['listen']) && $_POST['listen'] === 'all' ? 'all' : 'local')."\n"
        .'BACKUP_KEEP='.(int)$keep."\n";

    if (!manage_write_file($settings_file, $text)) {
        manage_fail(500, 'The settings could not be saved');
    }

    adguardhome_restart($ctl);
    manage_json();
}

if ($action === 'backup') {
    list($code, $output) = manage_run(['/bin/sh', $ctl, 'backup']);

    if ($code !== 0) {
        manage_fail(500, 'The backup failed: '.adguardhome_last_line($output));
    }

    manage_json(['backups' => array_slice(adguardhome_backups($data_path), 0, 5)]);
}

if ($action === 'restart') {
    adguardhome_restart($ctl);
    manage_json();
}

manage_fail(400, 'Unknown action');
