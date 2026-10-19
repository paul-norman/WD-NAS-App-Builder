<?php
// PHP app management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('php');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path = dirname(__DIR__);
$error_log = dirname($app_path) . '/_php/php-errors.log';
$wd_pages = '/usr/local/modules/web/pages/';

$action = isset($_GET['action']) ? $_GET['action'] : 'status';

if ($action === 'status') {
	// The running php-fpm (WD's PHP 7.4 or the app's PHP 8.5) - this page itself is served by it
	$pid = (int)@file_get_contents('/var/run/php-fpm.pid');
	$serving = $pid > 0 ? (string)@readlink('/proc/' . $pid . '/exe') : '';
	$patches = [];
	foreach (explode("\n", (string)@file_get_contents('/proc/mounts')) as $line) {
		$fields = explode(' ', $line);
		if (isset($fields[1]) && strpos($fields[1], $wd_pages) === 0) {
			$patches[] = substr($fields[1], strlen($wd_pages));
		}
	}
	list(, $cli) = manage_run(['/usr/bin/php', '-r', 'echo PHP_VERSION;']);
	list(, $modules) = manage_run([$app_path . '/binaries/php', '-m']);

	// The most recent errors, newest last
	$lines = is_file($error_log) ? file($error_log, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) : [];
	manage_json([
		'app_php' => $serving === $app_path . '/binaries/php-fpm',
		'serving' => $serving,
		'fpm_version' => PHP_VERSION,
		'cli_version' => $cli,
		'patches' => $patches,
		'restart_pending' => is_file('/var/run/php_app_restart.pid'),
		'extensions' => array_values(array_filter(explode("\n", $modules), function ($m) {
			return $m !== '' && $m[0] !== '[';
		})),
		'errors' => array_slice($lines, -100),
		'error_count' => count($lines),
		'log_size' => is_file($error_log) ? filesize($error_log) : 0,
	]);
}

manage_require_action('php');

if ($action === 'clear_log') {
	@unlink($error_log . '.1');
	if (is_file($error_log) && file_put_contents($error_log, '') === false) {
		manage_fail(500, 'The log could not be cleared: ' . $error_log);
	}
	manage_json([]);
}

manage_fail(400, 'Unknown action');
