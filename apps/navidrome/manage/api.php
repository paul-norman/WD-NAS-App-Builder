<?php
// Navidrome management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('navidrome');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path = dirname(__DIR__);
$apps_path = dirname($app_path);
$data_path = $apps_path . '/_navidrome';
$settings_file = $data_path . '/settings';
$ctl = $app_path . '/navidrome_ctl.sh';
require $app_path . '/lib/navidrome.php';

// The settings file (KEY=value lines, also read by navidrome_ctl.sh), with defaults
function nd_settings($file)
{
	$settings = ['MUSIC_FOLDER' => '/mnt/HD/HD_a2/Public', 'LISTEN' => 'all', 'EXTERNAL' => '0'];
	foreach (@file($file, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
		if (preg_match('/^([A-Z_]+)=(.*)$/', $line, $m) && isset($settings[$m[1]])) {
			$settings[$m[1]] = $m[2];
		}
	}
	return $settings;
}

function nd_password($data_path)
{
	return trim((string)@file_get_contents($data_path . '/admin_password'));
}

function nd_restart($ctl)
{
	manage_run(['/bin/sh', $ctl, 'stop']);
	list($code, $output) = manage_run(['/bin/sh', $ctl, 'start']);
	if ($code !== 0) {
		manage_fail(500, 'Navidrome could not be started: ' . $output);
	}
}

// Navidrome's own API, logged in as the admin user (with the app's password): the response's data, or null
function nd_api($data_path, $path)
{
	list($code, $body) = manage_http_request('POST', NAVIDROME_TARGET . '/auth/login',
		json_encode(['username' => 'admin', 'password' => nd_password($data_path)]));
	$login = $code === 200 ? json_decode($body, true) : null;
	if (!isset($login['token'])) {
		return null;
	}
	list($code, $body) = manage_http_request('GET', NAVIDROME_TARGET . $path, null, 5,
		['x-nd-authorization: Bearer ' . $login['token']]);
	return $code === 200 ? json_decode($body, true) : null;
}

$settings = nd_settings($settings_file);
$action = isset($_GET['action']) ? $_GET['action'] : 'status';

if ($action === 'status') {
	$running = manage_pid_running('/var/run/navidrome.pid');
	list($code) = $running ? manage_http_get(NAVIDROME_TARGET . '/ping') : [0];
	$answering = $code === 200;
	list(, $version) = manage_run([$app_path . '/binaries/navidrome', '--version']);
	$site = navidrome_site($apps_path);
	// The address it started with for its share links (the Nginx app's site)
	$config = (string)@file_get_contents($data_path . '/data/navidrome.toml');
	$share = preg_match('/^ShareURL = "([^"]*)"/m', $config, $m) ? $m[1] : '';
	$host = isset($_SERVER['HTTP_HOST']) ? preg_replace('/:\d+$/', '', $_SERVER['HTTP_HOST']) : '';
	$libraries = $answering ? nd_api($data_path, '/api/library') : null;
	list($readable) = manage_run(['/bin/sh', $ctl, 'check-folder', $settings['MUSIC_FOLDER']]);
	$backups = [];
	foreach (glob($data_path . '/backups/*.db') ?: [] as $file) {
		$backups[] = ['name' => basename($file), 'size' => filesize($file), 'time' => filemtime($file)];
	}
	usort($backups, function ($a, $b) { return $b['time'] - $a['time']; });
	// (Navidrome logs warnings and errors only)
	$log = array_values(array_filter(@file($data_path . '/navidrome.log', FILE_IGNORE_NEW_LINES) ?: [], function ($line) {
		return trim($line) !== '';
	}));

	manage_json([
		'running' => $running,
		'answering' => $answering,
		'version' => preg_match('/^(\S+)/', $version, $m) ? $m[1] : '',
		'site' => $site,
		'local_url' => $host !== '' ? 'http://' . $host . ':4533/' : '',
		'restart_needed' => $running && rtrim($site['url'], '/') !== $share,
		// null when the page can't log in (e.g. the admin user's password was changed in Navidrome)
		'libraries' => is_array($libraries) ? array_map(function ($library) {
			return ['name' => $library['name'], 'path' => $library['path'], 'songs' => $library['totalSongs'],
				'albums' => $library['totalAlbums'], 'artists' => $library['totalArtists'], 'size' => $library['totalSize'],
				'last_scan' => $library['lastScanAt'], 'scanning' => $library['fullScanInProgress']];
		}, $libraries) : null,
		'music_folder' => $settings['MUSIC_FOLDER'],
		'music_readable' => $readable === 0,
		'listen' => $settings['LISTEN'] === 'local' ? 'local' : 'all',
		'external' => $settings['EXTERNAL'] === '1',
		'backup_dir' => $data_path . '/backups',
		'backups' => $backups,
		'log' => array_slice($log, -20),
	]);
}

manage_require_action('navidrome');

if ($action === 'password') {
	manage_json(['password' => nd_password($data_path)]);
}

if ($action === 'new_password') {
	list($code, $output) = manage_run(['/bin/sh', $ctl, 'new-password']);
	if ($code !== 0) {
		manage_fail(500, 'A new password could not be set: ' . $output);
	}
	manage_json(['password' => nd_password($data_path)]);
}

if ($action === 'settings') {
	$folder = isset($_POST['music_folder']) ? rtrim(trim((string)$_POST['music_folder']), '/') : '';
	// (written into Navidrome's TOML configuration: no quotes, backslashes or control characters)
	if (!preg_match('#^/mnt/[^"\\\\\x00-\x1f]+$#', $folder) || strpos($folder, '/..') !== false) {
		manage_fail(400, 'The music folder must be a folder on the NAS, e.g. /mnt/HD/HD_a2/Music');
	}
	if (!is_dir($folder)) {
		manage_fail(400, 'No such folder: ' . $folder);
	}
	list($readable) = manage_run(['/bin/sh', $ctl, 'check-folder', $folder]);
	if ($readable !== 0) {
		manage_fail(400, 'Navidrome\'s user can\'t read ' . $folder . ' - give everyone read access to it (e.g. the share\'s Public access, or chmod o+rx)');
	}
	$text = 'MUSIC_FOLDER=' . $folder . "\n"
		. 'LISTEN=' . (isset($_POST['listen']) && $_POST['listen'] === 'local' ? 'local' : 'all') . "\n"
		. 'EXTERNAL=' . (empty($_POST['external']) ? 0 : 1) . "\n";
	if (!manage_write_file($settings_file, $text)) {
		manage_fail(500, 'The settings could not be saved');
	}
	nd_restart($ctl);
	manage_json([]);
}

if ($action === 'scan') {
	// Subsonic's startScan, as the admin user (the password in the form's body, not the address)
	$form = http_build_query(['u' => 'admin', 'p' => nd_password($data_path), 'v' => '1.16.1', 'c' => 'nas-page', 'f' => 'json',
		'fullScan' => empty($_POST['full']) ? 'false' : 'true']);
	list($code, $body) = manage_http_request('POST', NAVIDROME_TARGET . '/rest/startScan', $form, 5, [],
		'application/x-www-form-urlencoded');
	if ($code !== 200 || strpos($body, '"status":"ok"') === false) {
		manage_fail(500, 'Navidrome did not start a scan (does the admin user still have the password above?)');
	}
	manage_json([]);
}

if ($action === 'restart') {
	nd_restart($ctl);
	manage_json([]);
}

manage_fail(400, 'Unknown action');
