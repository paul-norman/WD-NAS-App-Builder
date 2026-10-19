<?php
// Shared security checks for app management pages (copied into each app's manage/ folder when it is built).
//
// Management pages are only installed under /var/www/apps/<app>/ (URL /apps/<app>/), where nasAdmin itself only lets
// requests through with a valid NAS login token: its signature, expiry, client IP and origin are all checked, and the
// token is removed before the request reaches PHP. On top of that, every request here must belong to an admin's WD
// session, and every action must carry this page's CSRF token.
//
// Never trust the login_username cookie: browsers can set it to anything.

// Stops with a JSON error
function manage_fail($code, $message)
{
	http_response_code($code);
	header('Content-Type: application/json');
	echo json_encode(['ok' => false, 'error' => $message]);
	exit;
}

// Sends a JSON response
function manage_json($data)
{
	header('Content-Type: application/json');
	header('Cache-Control: no-store');
	echo json_encode(['ok' => true] + $data);
	exit;
}

// Whether a user is a NAS admin (a member of the "administrators" group, which the NAS maintains)
function manage_is_admin($user)
{
	foreach (file('/etc/group', FILE_IGNORE_NEW_LINES) ?: [] as $line) {
		$fields = explode(':', $line);
		if ($fields[0] === 'administrators') {
			return in_array($user, explode(',', isset($fields[3]) ? $fields[3] : ''), true);
		}
	}
	return false;
}

// Only allows NAS admins, and only where nasAdmin enforces the NAS login. Returns the admin's user name
function manage_require_admin($app)
{
	$path = parse_url(isset($_SERVER['REQUEST_URI']) ? $_SERVER['REQUEST_URI'] : '', PHP_URL_PATH);
	if (strpos((string)$path, "/apps/{$app}/") !== 0 || $_SERVER['REMOTE_ADDR'] !== '127.0.0.1') {
		manage_fail(403, 'Not available here');
	}

	// Who is logged in comes from WD's own session, which is stored on the NAS (the browser only holds its ID)
	session_start(['read_and_close' => true]);
	$user = isset($_SESSION['username']) ? (string)$_SESSION['username'] : '';
	if ($user === '' || !manage_is_admin($user)) {
		manage_fail(403, 'Only NAS admins can manage apps');
	}
	return $user;
}

// A CSRF token for this session: an HMAC of the session ID with a secret that never leaves the NAS (regenerated on
// every boot, as /var/run is in RAM)
function manage_csrf_token($app)
{
	$file = "/var/run/manage_{$app}.secret";
	if (!is_file($file)) {
		file_put_contents($file, bin2hex(random_bytes(32)), LOCK_EX);
		chmod($file, 0600);
	}
	return hash_hmac('sha256', session_id(), trim(file_get_contents($file)));
}

// Requires a POST request carrying this session's CSRF token (so other websites can't make an admin's browser act)
function manage_require_action($app)
{
	$sent = isset($_SERVER['HTTP_X_CSRF_TOKEN']) ? (string)$_SERVER['HTTP_X_CSRF_TOKEN'] : '';
	if ($_SERVER['REQUEST_METHOD'] !== 'POST' || !hash_equals(manage_csrf_token($app), $sent)) {
		manage_fail(403, 'Invalid request token - reload the page');
	}
}

// Runs a command without a shell (nothing can be injected), with optional extra environment variables and input (use
// these for secrets, which would otherwise be visible to other processes in the command line). Returns
// [exit code, output]
function manage_run(array $command, array $env = [], $input = '')
{
	$process = proc_open($command, [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes, null, $env + ['PATH' => '/usr/bin:/bin:/usr/sbin:/sbin']);
	if (!is_resource($process)) {
		return [-1, 'could not run: ' . $command[0]];
	}
	fwrite($pipes[0], $input);
	fclose($pipes[0]);
	$output = stream_get_contents($pipes[1]) . stream_get_contents($pipes[2]);
	fclose($pipes[1]);
	fclose($pipes[2]);
	return [proc_close($process), trim($output)];
}

// Replaces a file's contents in one step (a temporary file in the same folder, renamed over it), keeping its mode
function manage_write_file($file, $contents)
{
	$mode = is_file($file) ? fileperms($file) & 0777 : 0600;
	$temp = $file . '.tmp';
	if (file_put_contents($temp, $contents, LOCK_EX) === false || !chmod($temp, $mode) || !rename($temp, $file)) {
		@unlink($temp);
		return false;
	}
	return true;
}
