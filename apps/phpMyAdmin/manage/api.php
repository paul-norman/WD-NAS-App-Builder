<?php
// phpMyAdmin management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('phpMyAdmin');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path = dirname(__DIR__);
$apps_path = dirname($app_path);
$password_file = $apps_path . '/_phpMyAdmin/admin_password';
// Its HTTPS address's own password (the Nginx app asks for it first, unless AUTH=0), and its settings
$site_password_file = $apps_path . '/_phpMyAdmin/site_password';
$settings_file = $apps_path . '/_phpMyAdmin/settings';
$site_ctl = $app_path . '/pma_site.sh';

// Where the Nginx app serves phpMyAdmin: ['state' => ok|no_nginx|no_domain|off, 'url' => address or ''] - its site
// (its nginx.json's: offered as "phpmyadmin", but it can be renamed)
function pma_site($apps_path)
{
	$sites = $apps_path . '/nginx/lib/sites.php';
	if (!is_file($sites) || !is_dir($apps_path . '/_nginx')) {
		return ['state' => 'no_nginx', 'url' => ''];
	}
	require_once $sites;
	$settings = sites_load($apps_path . '/_nginx');
	if ($settings['domain'] === '') {
		return ['state' => 'no_domain', 'url' => ''];
	}
	foreach ($settings['apps'] as $app) {
		if ($app['enabled'] && $app['path'] === '/phpMyAdmin/' && rtrim($app['target'], '/') === 'http://127.0.0.1:80') {
			return ['state' => 'ok', 'url' => 'https://' . sites_host($settings, $app) . '/phpMyAdmin/'];
		}
	}
	return ['state' => 'off', 'url' => ''];
}

// Runs SQL as MariaDB's root user (which only accepts local connections without a password). The SQL goes in via stdin
function pma_sql($sql)
{
	return manage_run(['mysql', '--user=root', '--password=', '--batch', '--skip-column-names'], [], $sql);
}

$action = isset($_GET['action']) ? $_GET['action'] : 'status';

if ($action === 'status') {
	list($code, $output) = pma_sql("SELECT VERSION(), @@bind_address, @@port, (SELECT COUNT(*) FROM mysql.user WHERE User = 'admin' AND Host = 'localhost');\n");
	$fields = $code === 0 ? explode("\t", $output) : [];
	$rc = (string)@file_get_contents($app_path . '/apkg.rc');
	manage_json([
		'running' => count($fields) === 4,
		'mariadb_version' => isset($fields[0]) ? $fields[0] : '',
		'bind' => isset($fields[1]) ? $fields[1] : '',
		'port' => isset($fields[2]) ? (int)$fields[2] : 0,
		'admin_exists' => isset($fields[3]) && $fields[3] === '1',
		'phpmyadmin_version' => preg_match('/^Version:[ \t]*(\S+)/m', $rc, $m) ? $m[1] : '',
		'site' => pma_site($apps_path),
		'auth' => !preg_match('/^AUTH=0$/m', (string)@file_get_contents($settings_file)),
	]);
}

manage_require_action('phpMyAdmin');

if ($action === 'password') {
	manage_json(['password' => trim((string)@file_get_contents($password_file))]);
}

if ($action === 'set_password') {
	// A new password: the one given (letters, digits and . _ ~ - only, so it can't break out of the SQL), or a random one
	$new = isset($_POST['password']) ? trim((string)$_POST['password']) : '';
	if ($new === '') {
		$new = substr(str_replace(['+', '/', '='], '', base64_encode(random_bytes(48))), 0, 24);
	} elseif (!preg_match('/^[A-Za-z0-9._~-]{12,128}$/', $new)) {
		manage_fail(400, 'Passwords must be 12-128 characters: letters, digits and . _ ~ -');
	}

	// Change it in MariaDB first, then save it (reinstalling the app recreates the account with the saved password)
	list($code, $output) = pma_sql("ALTER USER 'admin'@'localhost' IDENTIFIED BY '{$new}';\n");
	if ($code !== 0) {
		manage_fail(500, $output !== '' ? 'MariaDB refused the new password: ' . $output : 'MariaDB could not be reached - is it running?');
	}
	if (!manage_write_file($password_file, $new)) {
		manage_fail(500, 'The password was changed in MariaDB, but could not be saved to: ' . $password_file);
	}

	manage_json(['password' => $new]);
}

if ($action === 'site_password') {
	manage_json(['password' => trim((string)@file_get_contents($site_password_file))]);
}

if ($action === 'set_site_password') {
	// A new password for its HTTPS address: the one given (letters, digits and . _ ~ -), or a random one. Nginx reads the
	// new htpasswd file on the next request
	$new = isset($_POST['password']) ? trim((string)$_POST['password']) : '';
	if ($new === '') {
		$new = substr(str_replace(['+', '/', '='], '', base64_encode(random_bytes(48))), 0, 20);
	} elseif (!preg_match('/^[A-Za-z0-9._~-]{12,128}$/', $new)) {
		manage_fail(400, 'Passwords must be 12-128 characters: letters, digits and . _ ~ -');
	}
	list($code, $output) = manage_run(['/bin/sh', $site_ctl, 'set-password'], [], $new . "\n");
	if ($code !== 0) {
		manage_fail(500, 'The password could not be saved: ' . $output);
	}
	manage_json(['password' => $new]);
}

if ($action === 'auth') {
	$auth = !empty($_POST['auth']);
	if (!manage_write_file($settings_file, 'AUTH=' . ($auth ? 1 : 0) . "\n")) {
		manage_fail(500, 'The setting could not be saved');
	}
	// Its site in the Nginx app follows (its nginx.json rewritten)
	manage_run(['/bin/sh', $site_ctl, 'nginx']);
	manage_json([]);
}

manage_fail(400, 'Unknown action');
