<?php
// Vaultwarden management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('vaultwarden');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path = dirname(__DIR__);
$apps_path = dirname($app_path);
$data_path = $apps_path . '/_vaultwarden';
$vw_data = $data_path . '/data';
$settings_file = $data_path . '/settings';
$ctl = $app_path . '/vw_ctl.sh';
require $app_path . '/lib/vw.php';

// The settings file (KEY=value lines, also read by vw_ctl.sh), with defaults
function vw_settings($file)
{
	$settings = ['SIGNUPS' => '1', 'BACKUP_DIR' => '', 'BACKUP_KEEP' => '14'];
	foreach (@file($file, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
		if (preg_match('/^([A-Z_]+)=(.*)$/', $line, $m) && isset($settings[$m[1]])) {
			$settings[$m[1]] = $m[2];
		}
	}
	return $settings;
}

function vw_save_settings($file, array $settings)
{
	$text = '';
	foreach ($settings as $key => $value) {
		$text .= $key . '=' . $value . "\n";
	}
	return manage_write_file($file, $text);
}

function vw_ctl($ctl, $command)
{
	return manage_run(['/bin/sh', $ctl, $command]);
}

$settings = vw_settings($settings_file);
$backup_dir = $settings['BACKUP_DIR'] !== '' ? $settings['BACKUP_DIR'] : $data_path . '/backups';
$action = isset($_GET['action']) ? $_GET['action'] : 'status';

if ($action === 'status') {
	$running = manage_pid_running('/var/run/vaultwarden.pid');
	list($alive) = $running ? manage_http_get(VW_TARGET . '/alive') : [0];
	list(, $version) = manage_run([$app_path . '/binaries/vaultwarden', '--version']);
	$web_vault = json_decode((string)@file_get_contents($app_path . '/binaries/web-vault/vw-version.json'), true);

	// The address it runs with (set when it started) and the one the Nginx app has now
	$site = vw_site($apps_path);
	$env = (string)@file_get_contents($data_path . '/vaultwarden.env');
	$domain = preg_match("/^DOMAIN='([^']*)'/m", $env, $m) ? $m[1] : '';

	$backups = [];
	foreach (glob($backup_dir . '/vaultwarden-*.tar.gz') ?: [] as $file) {
		$backups[] = ['name' => basename($file), 'size' => filesize($file), 'time' => filemtime($file)];
	}
	usort($backups, function ($a, $b) { return strcmp($b['name'], $a['name']); });

	$log = @file($data_path . '/vaultwarden.log', FILE_IGNORE_NEW_LINES) ?: [];

	manage_json([
		'running' => $running,
		'answering' => $alive === 200,
		'version' => preg_match('/Vaultwarden (\S+)/', $version, $m) ? $m[1] : '',
		'web_vault' => is_array($web_vault) && isset($web_vault['version']) ? $web_vault['version'] : '',
		'site' => $site,
		'restart_needed' => $running && $site['url'] !== '' && rtrim($site['url'], '/') !== $domain,
		'signups' => $settings['SIGNUPS'] === '1',
		'backup_dir' => $settings['BACKUP_DIR'],
		'backup_dir_default' => $data_path . '/backups',
		'backup_keep' => (int)$settings['BACKUP_KEEP'],
		'backups' => array_slice($backups, 0, 30),
		'has_db' => is_file($vw_data . '/db.sqlite3'),
		'log' => array_slice($log, -40),
	]);
}

manage_require_action('vaultwarden');

if ($action === 'token') {
	manage_json(['token' => trim((string)@file_get_contents($data_path . '/admin_token'))]);
}

if ($action === 'new_token') {
	list($code, $output) = vw_ctl($ctl, 'new-token');
	$hash = trim((string)@file_get_contents($data_path . '/admin_token.hash'));
	if ($code !== 0 || $hash === '') {
		manage_fail(500, 'A new token could not be made: ' . $output);
	}
	if (!vw_config_set($vw_data, 'admin_token', $hash)) {
		manage_fail(500, 'The new token could not replace the one saved in Vaultwarden\'s admin panel (data/config.json)');
	}
	vw_ctl($ctl, 'restart');
	manage_json(['token' => trim((string)@file_get_contents($data_path . '/admin_token'))]);
}

if ($action === 'signups') {
	$on = !empty($_POST['on']);
	$settings['SIGNUPS'] = $on ? '1' : '0';
	if (!vw_save_settings($settings_file, $settings) || !vw_config_set($vw_data, 'signups_allowed', $on)) {
		manage_fail(500, 'The setting could not be saved');
	}
	vw_ctl($ctl, 'restart');
	manage_json([]);
}

if ($action === 'backup_settings') {
	$dir = isset($_POST['dir']) ? rtrim(trim((string)$_POST['dir']), '/') : '';
	$keep = isset($_POST['keep']) ? (int)$_POST['keep'] : 0;
	if ($keep < 1 || $keep > 365) {
		manage_fail(400, 'Keep between 1 and 365 backups');
	}
	if ($dir !== '') {
		// On the NAS's volumes or USB drives (no line breaks or quotes, which vw_ctl.sh couldn't take), in a folder that
		// exists or can be created in one that does
		if (!preg_match('#^/(mnt/HD|mnt/USB|shares)/[^"\'\\\\\x00-\x1f]+$#', $dir)) {
			manage_fail(400, 'Backups go in a folder on the NAS\'s volumes or USB drives, e.g. /mnt/HD/HD_a2/Backups/Vaultwarden');
		}
		$existing = is_dir($dir) ? $dir : dirname($dir);
		if (!is_dir($existing) || !preg_match('#^/(mnt/HD|mnt/USB)/#', realpath($existing) . '/')) {
			manage_fail(400, 'No such folder (its parent folder must exist): ' . $dir);
		}
	}
	$settings['BACKUP_DIR'] = $dir;
	$settings['BACKUP_KEEP'] = (string)$keep;
	if (!vw_save_settings($settings_file, $settings)) {
		manage_fail(500, 'The settings could not be saved');
	}
	manage_json([]);
}

if ($action === 'backup_now') {
	list($code, $output) = vw_ctl($ctl, 'backup');
	if ($code !== 0) {
		manage_fail(500, $output !== '' ? $output : 'The backup failed (see /tmp/debug_apkg)');
	}
	manage_json(['message' => $output]);
}

if ($action === 'restart') {
	list($code, $output) = vw_ctl($ctl, 'restart');
	if ($code !== 0) {
		manage_fail(500, 'Vaultwarden could not be started: ' . $output);
	}
	manage_json([]);
}

manage_fail(400, 'Unknown action');
