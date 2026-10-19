<?php
// phpMyAdmin management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('phpMyAdmin');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path = dirname(__DIR__);
$password_file = dirname($app_path) . '/_phpMyAdmin/admin_password';

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

manage_fail(400, 'Unknown action');
