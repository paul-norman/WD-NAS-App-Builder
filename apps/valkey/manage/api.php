<?php
// ValKey management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('valkey');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path = dirname(__DIR__);
$conf_file = dirname($app_path) . '/_valkey/valkey.conf';
$cli = $app_path . '/binaries/valkey-cli';

// The password currently in the config file
function valkey_conf_password($conf_file)
{
	return preg_match('/^requirepass[ \t]+(\S+)[ \t]*$/m', (string)@file_get_contents($conf_file), $m) ? $m[1] : '';
}

// Whether ValKey is running
function valkey_running()
{
	$pid = trim((string)@file_get_contents('/var/run/valkey.pid'));
	return ctype_digit($pid) && is_dir("/proc/{$pid}");
}

$action = isset($_GET['action']) ? $_GET['action'] : 'status';

if ($action === 'status') {
	list(, $version) = manage_run([$app_path . '/binaries/valkey-server', '--version']);
	$conf = (string)@file_get_contents($conf_file);
	manage_json([
		'running' => valkey_running(),
		'version' => preg_match('/v=(\S+)/', $version, $m) ? $m[1] : '',
		'port' => preg_match('/^port[ \t]+(\d+)/m', $conf, $m) ? (int)$m[1] : 6379,
		'bind' => preg_match('/^bind[ \t]+(.+)$/m', $conf, $m) ? trim($m[1]) : '',
		'has_password' => valkey_conf_password($conf_file) !== '',
	]);
}

manage_require_action('valkey');

if ($action === 'password') {
	manage_json(['password' => valkey_conf_password($conf_file)]);
}

if ($action === 'set_password') {
	// A new password: the one given (letters, digits and . _ ~ - only, so it is safe in the config file), or a random one
	$new = isset($_POST['password']) ? trim((string)$_POST['password']) : '';
	if ($new === '') {
		$new = substr(str_replace(['+', '/', '='], '', base64_encode(random_bytes(48))), 0, 32);
	} elseif (!preg_match('/^[A-Za-z0-9._~-]{12,128}$/', $new)) {
		manage_fail(400, 'Passwords must be 12-128 characters: letters, digits and . _ ~ -');
	}
	$old = valkey_conf_password($conf_file);

	// Apply it to the running server first (the password goes in via stdin, not the command line)
	if (valkey_running()) {
		list($code, $output) = manage_run([$cli], ['REDISCLI_AUTH' => $old], "CONFIG SET requirepass {$new}\n");
		if ($code !== 0 || $output !== 'OK') {
			manage_fail(500, 'ValKey refused the new password: ' . $output);
		}
	}

	// Then save it to the config file (the real file in the persistent path, not the /etc symlink to it)
	$conf = (string)@file_get_contents($conf_file);
	$updated = preg_match('/^requirepass[ \t]/m', $conf)
		? preg_replace('/^requirepass[ \t].*$/m', 'requirepass ' . $new, $conf)
		: rtrim($conf, "\n") . "\nrequirepass {$new}\n";
	if (!manage_write_file($conf_file, $updated)) {
		if (valkey_running()) {
			manage_run([$cli], ['REDISCLI_AUTH' => $new], "CONFIG SET requirepass {$old}\n");
		}
		manage_fail(500, 'The config file could not be saved, so the password was not changed');
	}

	manage_json(['password' => $new, 'applied' => valkey_running()]);
}

manage_fail(400, 'Unknown action');
