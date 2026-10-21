<?php
// Uptime Kuma management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('uptime-kuma');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path = dirname(__DIR__);
$apps_path = dirname($app_path);
$data_path = $apps_path . '/_uptime-kuma';
$kuma_data = $data_path . '/data';
$settings_file = $data_path . '/settings';
$ctl = $app_path . '/kuma_ctl.sh';
require $app_path . '/lib/kuma.php';

// The settings file (KEY=value lines, also read by kuma_ctl.sh), with defaults
function kuma_settings($file)
{
	$settings = ['LISTEN' => 'all', 'BACKUP_DIR' => '', 'BACKUP_KEEP' => '7'];
	foreach (@file($file, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
		if (preg_match('/^([A-Z_]+)=(.*)$/', $line, $m) && isset($settings[$m[1]])) {
			$settings[$m[1]] = $m[2];
		}
	}
	return $settings;
}

function kuma_save_settings($file, array $settings)
{
	$text = '';
	foreach ($settings as $key => $value) {
		$text .= $key . '=' . $value . "\n";
	}
	return manage_write_file($file, $text);
}

function kuma_ctl($ctl, $command, $input = '')
{
	return manage_run(['/bin/sh', $ctl, $command], [], $input);
}

$settings = kuma_settings($settings_file);
$backup_dir = $settings['BACKUP_DIR'] !== '' ? $settings['BACKUP_DIR'] : $data_path . '/backups';
$action = isset($_GET['action']) ? $_GET['action'] : 'status';

if ($action === 'status') {
	$running = manage_pid_running('/var/run/uptime-kuma.pid');
	list($code) = $running ? manage_http_get(KUMA_TARGET . '/') : [0];
	$package = json_decode((string)@file_get_contents($app_path . '/binaries/uptime-kuma/package.json'), true);

	// Its admin account (none until it has been set up in Uptime Kuma itself)
	$user = '';
	if (is_file($kuma_data . '/kuma.db')) {
		list($rc, $out) = manage_run([$app_path . '/binaries/sqlite3', '-readonly', $kuma_data . '/kuma.db', 'SELECT username FROM user LIMIT 1;']);
		$user = $rc === 0 ? $out : '';
	}

	$backups = [];
	foreach (glob($backup_dir . '/uptime-kuma-*.tar.gz') ?: [] as $file) {
		$backups[] = ['name' => basename($file), 'size' => filesize($file), 'time' => filemtime($file)];
	}
	usort($backups, function ($a, $b) { return strcmp($b['name'], $a['name']); });

	$log = @file($data_path . '/uptime-kuma.log', FILE_IGNORE_NEW_LINES) ?: [];

	manage_json([
		'running' => $running,
		'answering' => $code >= 200 && $code < 400,
		'version' => is_array($package) && isset($package['version']) ? $package['version'] : '',
		'listen' => $settings['LISTEN'] === 'local' ? 'local' : 'all',
		'site' => kuma_site($apps_path),
		'user' => $user,
		'backup_dir' => $settings['BACKUP_DIR'],
		'backup_dir_default' => $data_path . '/backups',
		'backup_keep' => (int)$settings['BACKUP_KEEP'],
		'backups' => array_slice($backups, 0, 30),
		'has_db' => is_file($kuma_data . '/kuma.db'),
		'log' => array_slice($log, -40),
	]);
}

manage_require_action('uptime-kuma');

if ($action === 'listen') {
	$settings['LISTEN'] = isset($_POST['listen']) && $_POST['listen'] === 'local' ? 'local' : 'all';
	if (!kuma_save_settings($settings_file, $settings)) {
		manage_fail(500, 'The setting could not be saved');
	}
	kuma_ctl($ctl, 'restart');
	manage_json([]);
}

if ($action === 'reset_password') {
	// A new random password (letters and digits, strong enough for Uptime Kuma's own check), given to its tool on input
	$password = substr(str_replace(['+', '/', '='], '', base64_encode(random_bytes(48))), 0, 20);
	list($code, $output) = kuma_ctl($ctl, 'reset-password', $password . "\n");
	if ($code !== 0) {
		manage_fail(500, 'The password could not be reset: ' . trim(preg_replace('/^.*?(Error: )/s', '$1', $output)));
	}
	manage_json(['password' => $password]);
}

if ($action === 'backup_settings') {
	$dir = isset($_POST['dir']) ? rtrim(trim((string)$_POST['dir']), '/') : '';
	$keep = isset($_POST['keep']) ? (int)$_POST['keep'] : 0;
	if ($keep < 1 || $keep > 365) {
		manage_fail(400, 'Keep between 1 and 365 backups');
	}
	if ($dir !== '') {
		// On the NAS's volumes or USB drives (no line breaks or quotes, which kuma_ctl.sh couldn't take), in a folder that
		// exists or can be created in one that does
		if (!preg_match('#^/(mnt/HD|mnt/USB|shares)/[^"\'\\\\\x00-\x1f]+$#', $dir)) {
			manage_fail(400, 'Backups go in a folder on the NAS\'s volumes or USB drives, e.g. /mnt/HD/HD_a2/Backups/Uptime-Kuma');
		}
		$existing = is_dir($dir) ? $dir : dirname($dir);
		if (!is_dir($existing) || !preg_match('#^/(mnt/HD|mnt/USB)/#', realpath($existing) . '/')) {
			manage_fail(400, 'No such folder (its parent folder must exist): ' . $dir);
		}
	}
	$settings['BACKUP_DIR'] = $dir;
	$settings['BACKUP_KEEP'] = (string)$keep;
	if (!kuma_save_settings($settings_file, $settings)) {
		manage_fail(500, 'The settings could not be saved');
	}
	manage_json([]);
}

if ($action === 'backup_now') {
	list($code, $output) = kuma_ctl($ctl, 'backup');
	if ($code !== 0) {
		manage_fail(500, $output !== '' ? $output : 'The backup failed (see /tmp/debug_apkg)');
	}
	manage_json(['message' => $output]);
}

if ($action === 'restart') {
	list($code, $output) = kuma_ctl($ctl, 'restart');
	if ($code !== 0) {
		manage_fail(500, 'Uptime Kuma could not be started: ' . $output);
	}
	manage_json([]);
}

manage_fail(400, 'Unknown action');
