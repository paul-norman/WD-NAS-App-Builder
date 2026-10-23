<?php
// Calibre-Web management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('calibre-web');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path = dirname(__DIR__);
$apps_path = dirname($app_path);
$data_path = $apps_path . '/_calibre-web';
$settings_file = $data_path . '/settings';
$ctl = $app_path . '/cw_ctl.sh';
require $app_path . '/lib/cw.php';

// The settings file (KEY=value lines, also read by cw_ctl.sh), with defaults
function cw_settings($file)
{
	$settings = ['LIBRARY' => '/mnt/HD/HD_a2/Public/Books/Calibre Library', 'LISTEN' => 'all', 'INGEST' => '0',
		'INGEST_FOLDER' => '/mnt/HD/HD_a2/Public/Books/Add to library', 'INGEST_CONVERT' => 'none'];
	foreach (@file($file, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
		if (preg_match('/^([A-Z_]+)=(.*)$/', $line, $m) && isset($settings[$m[1]])) {
			$settings[$m[1]] = $m[2];
		}
	}
	return $settings;
}

function cw_settings_text(array $settings)
{
	$text = '';
	foreach ($settings as $key => $value) {
		$text .= $key . '=' . $value . "\n";
	}
	return $text;
}

function cw_password($data_path)
{
	return trim((string)@file_get_contents($data_path . '/admin_password'));
}

// A folder for the library or the ingest folder: on a share (not Nas_Prog, where the apps keep their secrets), with no
// quotes, backslashes or control characters. Returns '' or why not
function cw_check_folder($folder)
{
	if (!preg_match('#^/mnt/(HD/HD_[a-z][0-9]+|USB/[A-Za-z0-9_]+)/[^/.][^"\\\\\x00-\x1f]*$#', $folder) || strpos($folder, '/..') !== false
		|| strpos($folder, '/./') !== false) {
		return 'It must be a folder on one of the NAS\'s shares, e.g. /mnt/HD/HD_a2/Public/Books/Calibre Library';
	}
	if (preg_match('#^/mnt/HD/HD_[a-z][0-9]+/Nas_Prog(/|$)#', $folder)) {
		return 'It must be on a share, not in Nas_Prog (the apps\' folder)';
	}
	return '';
}

function cw_restart($ctl)
{
	manage_run(['/bin/sh', $ctl, 'stop']);
	list($code, $output) = manage_run(['/bin/sh', $ctl, 'start']);
	if ($code !== 0) {
		manage_fail(500, 'Calibre-Web could not be started: ' . $output);
	}
}

$settings = cw_settings($settings_file);
$action = isset($_GET['action']) ? $_GET['action'] : 'status';

if ($action === 'status') {
	$running = manage_pid_running('/var/run/calibre-web.pid');
	list($code) = $running ? manage_http_get(CW_TARGET . '/login') : [0];
	$answering = $code === 200;
	$versions = [];
	foreach (@file($data_path . '/versions', FILE_IGNORE_NEW_LINES) ?: [] as $line) {
		if (preg_match('/^([A-Z_]+)=(.*)$/', $line, $m)) {
			$versions[strtolower($m[1])] = $m[2];
		}
	}
	$site = cw_site($apps_path);
	$host = isset($_SERVER['HTTP_HOST']) ? preg_replace('/:\d+$/', '', $_SERVER['HTTP_HOST']) : '';
	$library = $settings['LIBRARY'];
	list(, $books) = is_file($library . '/metadata.db')
		? manage_run([$app_path . '/binaries/python/bin/python3', $app_path . '/lib/cw.py', 'count', $library . '/metadata.db']) : [0, ''];
	// The ingest folder: what's waiting, and what happened lately
	$waiting = 0;
	foreach (glob(rtrim($settings['INGEST_FOLDER'], '/') . '/*') ?: [] as $file) {
		if (is_file($file) && basename($file)[0] !== '.') {
			$waiting++;
		}
	}
	$ingest_log = array_slice(@file($data_path . '/ingest.log', FILE_IGNORE_NEW_LINES) ?: [], -15);
	$backups = [];
	foreach (glob($data_path . '/backups/????-??-??') ?: [] as $dir) {
		$size = 0;
		foreach (glob($dir . '/*.db') ?: [] as $file) {
			$size += filesize($file);
		}
		$backups[] = ['name' => basename($dir), 'size' => $size];
	}
	rsort($backups);
	// (Calibre-Web's warnings and errors)
	$log = array_values(array_filter(@file($data_path . '/data/calibre-web.log', FILE_IGNORE_NEW_LINES) ?: [], function ($line) {
		return preg_match('/\]\s+(WARN|ERROR|CRIT)/', $line) === 1;
	}));
	$address = $site['url'] ?: ($host !== '' ? 'http://' . $host . ':8083/' : '');

	manage_json([
		'running' => $running,
		'answering' => $answering,
		'versions' => $versions,
		'site' => $site,
		'local_url' => $host !== '' ? 'http://' . $host . ':8083/' : '',
		'opds' => $address !== '' ? rtrim($address, '/') . '/opds' : '',
		'library' => $library,
		'library_ok' => is_file($library . '/metadata.db'),
		'books' => is_numeric(trim($books)) ? (int)trim($books) : null,
		'listen' => $settings['LISTEN'] === 'local' ? 'local' : 'all',
		'ingest' => $settings['INGEST'] === '1',
		'ingest_folder' => $settings['INGEST_FOLDER'],
		'ingest_convert' => $settings['INGEST_CONVERT'] === 'epub' ? 'epub' : 'none',
		'ingest_waiting' => $waiting,
		'ingest_log' => $ingest_log,
		'backup_dir' => $data_path . '/backups',
		'backups' => $backups,
		'log' => array_slice($log, -20),
	]);
}

manage_require_action('calibre-web');

if ($action === 'password') {
	manage_json(['password' => cw_password($data_path)]);
}

if ($action === 'new_password') {
	list($code, $output) = manage_run(['/bin/sh', $ctl, 'new-password']);
	if ($code !== 0) {
		manage_fail(500, 'A new password could not be set: ' . $output);
	}
	manage_json(['password' => cw_password($data_path)]);
}

if ($action === 'settings') {
	$listen = isset($_POST['listen']) && $_POST['listen'] === 'local' ? 'local' : 'all';
	$folder = isset($_POST['ingest_folder']) ? rtrim(trim((string)$_POST['ingest_folder']), '/') : '';
	$error = cw_check_folder($folder);
	if ($error !== '') {
		manage_fail(400, 'Ingest folder: ' . $error);
	}
	$library = rtrim($settings['LIBRARY'], '/');
	if ($folder === $library || strpos($folder . '/', $library . '/') === 0 || strpos($library . '/', $folder . '/') === 0) {
		manage_fail(400, 'The ingest folder must be separate from the library (not in it, nor around it)');
	}
	$ingest = empty($_POST['ingest']) ? '0' : '1';
	if ($ingest === '1' && !is_dir($folder) && !@mkdir($folder, 0777, true)) {
		manage_fail(500, 'Could not create ' . $folder);
	}
	if (is_dir($folder)) {
		// (anyone who can reach the share can drop books in it)
		@chmod($folder, 0777);
	}
	$restart = $listen !== $settings['LISTEN'];
	$settings = array_merge($settings, ['LISTEN' => $listen, 'INGEST' => $ingest, 'INGEST_FOLDER' => $folder,
		'INGEST_CONVERT' => isset($_POST['ingest_convert']) && $_POST['ingest_convert'] === 'epub' ? 'epub' : 'none']);
	if (!manage_write_file($settings_file, cw_settings_text($settings))) {
		manage_fail(500, 'The settings could not be saved');
	}
	if ($restart) {
		cw_restart($ctl);
	}
	manage_json(['restarted' => $restart]);
}

if ($action === 'library') {
	$folder = isset($_POST['library']) ? rtrim(trim((string)$_POST['library']), '/') : '';
	$error = cw_check_folder($folder);
	if ($error !== '') {
		manage_fail(400, $error);
	}
	$ingest = rtrim($settings['INGEST_FOLDER'], '/');
	if ($folder === $ingest || strpos($folder . '/', $ingest . '/') === 0 || strpos($ingest . '/', $folder . '/') === 0) {
		manage_fail(400, 'The library must be separate from the ingest folder');
	}
	// (an existing folder must be a Calibre library, or empty: a new library is made in it)
	if (is_dir($folder) && !is_file($folder . '/metadata.db') && count(array_diff(scandir($folder) ?: [], ['.', '..'])) > 0) {
		manage_fail(400, $folder . ' isn\'t a Calibre library (no metadata.db) and isn\'t empty - choose an existing library, an empty folder or a new one');
	}
	list($code, $output) = manage_run(['/bin/sh', $ctl, 'library', $folder]);
	if ($code !== 0) {
		manage_fail(500, 'Calibre-Web could not use that library: ' . $output);
	}
	manage_json([]);
}

if ($action === 'restart') {
	cw_restart($ctl);
	manage_json([]);
}

manage_fail(400, 'Unknown action');
