<?php
// Adminer management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('adminer');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path = dirname(__DIR__);
$apps_path = dirname($app_path);
$data_path = $apps_path . '/_adminer';
$password_file = $data_path . '/password';
$settings_file = $data_path . '/settings';
$ctl = $app_path . '/adminer_ctl.sh';
require $app_path . '/lib/adminer.php';

// LISTEN=local: only through the Nginx app; all: on the network too (with only Adminer's own database login)
function adminer_listen($file)
{
	return preg_match('/^LISTEN=all$/m', (string)@file_get_contents($file)) ? 'all' : 'local';
}

// Saves one setting, keeping the others
function adminer_save_setting($file, $key, $value)
{
	$text = preg_replace('/^' . $key . '=.*\n?/m', '', (string)@file_get_contents($file));
	return manage_write_file($file, rtrim($text, "\n") . ($text !== '' ? "\n" : '') . $key . '=' . $value . "\n");
}

function adminer_restart($ctl)
{
	manage_run(['/bin/sh', $ctl, 'stop']);
	list($code, $output) = manage_run(['/bin/sh', $ctl, 'start']);
	if ($code !== 0) {
		manage_fail(500, 'Adminer could not be started: ' . $output);
	}
}

$action = isset($_GET['action']) ? $_GET['action'] : 'status';

if ($action === 'status') {
	$running = manage_pid_running('/var/run/adminer.pid');
	list($code, $body) = $running ? manage_http_get(ADMINER_TARGET . '/') : [0, ''];
	$file = (string)@file_get_contents($app_path . '/www/index.php', false, null, 0, 2048);
	$log = @file($data_path . '/adminer.log', FILE_IGNORE_NEW_LINES) ?: [];
	manage_json([
		'running' => $running,
		'answering' => $code === 200 && strpos($body, 'Adminer</title>') !== false,
		'version' => preg_match('/@version (\S+)/', $file, $m) ? $m[1] : '',
		'listen' => adminer_listen($settings_file),
		// Whether its HTTPS address asks for the page's password first (AUTH=0: only Adminer's own database login)
		'auth' => !preg_match('/^AUTH=0$/m', (string)@file_get_contents($settings_file)),
		'site' => adminer_site($apps_path),
		'mariadb' => is_dir($apps_path . '/mariadb'),
		'postgresql' => is_dir($apps_path . '/postgresql'),
		'valkey' => is_dir($apps_path . '/valkey'),
		// Which PHP it runs on (as adminer_ctl.sh picks it): the PHP app's (every driver), or the NAS's own 7.4 (no PostgreSQL)
		'php' => is_file($apps_path . '/php/binaries/php') ? 'app' : (is_file('/usr/local/modules/usr/bin/php') ? 'nas' : ''),
		'log' => array_slice($log, -20),
	]);
}

manage_require_action('adminer');

if ($action === 'password') {
	manage_json(['password' => trim((string)@file_get_contents($password_file))]);
}

if ($action === 'set_password') {
	// A new password: the one given (letters, digits and . _ ~ - only, like the other apps), or a random one. Nginx reads
	// the new htpasswd file on the next request, so nothing restarts
	$new = isset($_POST['password']) ? trim((string)$_POST['password']) : '';
	if ($new === '') {
		$new = substr(str_replace(['+', '/', '='], '', base64_encode(random_bytes(48))), 0, 20);
	} elseif (!preg_match('/^[A-Za-z0-9._~-]{12,128}$/', $new)) {
		manage_fail(400, 'Passwords must be 12-128 characters: letters, digits and . _ ~ -');
	}
	list($code, $output) = manage_run(['/bin/sh', $ctl, 'set-password'], [], $new . "\n");
	if ($code !== 0) {
		manage_fail(500, 'The password could not be saved: ' . $output);
	}
	manage_json(['password' => $new]);
}

if ($action === 'auth') {
	$auth = !empty($_POST['auth']);
	if (!adminer_save_setting($settings_file, 'AUTH', $auth ? 1 : 0)) {
		manage_fail(500, 'The setting could not be saved');
	}
	// Its site in the Nginx app follows (its nginx.json rewritten)
	manage_run(['/bin/sh', $ctl, 'nginx']);
	manage_json([]);
}

if ($action === 'listen') {
	$listen = isset($_POST['listen']) && $_POST['listen'] === 'all' ? 'all' : 'local';
	if (!adminer_save_setting($settings_file, 'LISTEN', $listen)) {
		manage_fail(500, 'The setting could not be saved');
	}
	adminer_restart($ctl);
	manage_json([]);
}

if ($action === 'restart') {
	adminer_restart($ctl);
	manage_json([]);
}

manage_fail(400, 'Unknown action');
