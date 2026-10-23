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

// Sends a request to a service on the NAS itself (e.g. http://127.0.0.1:8096/health) with the NAS's own curl, as WD's
// PHP has allow_url_fopen turned off. Headers (e.g. API keys) go via a root-only file rather than the command line, which
// other processes can see. The body (JSON unless another content type is given, e.g. a form's
// application/x-www-form-urlencoded) goes on curl's input. Returns [HTTP status, body], or [0, ''] if it couldn't be
// reached
function manage_http_request($method, $url, $body = null, $timeout = 3, array $headers = [], $content_type = 'application/json')
{
	$command = ['curl', '-s', '-m', (string)$timeout, '-X', $method, '-w', '\n%{http_code}'];
	if ($body !== null) {
		$command = array_merge($command, ['-H', 'Content-Type: ' . $content_type, '--data-binary', '@-']);
	}
	$header_file = null;
	if ($headers) {
		$header_file = tempnam(sys_get_temp_dir(), 'manage');
		chmod($header_file, 0600);
		file_put_contents($header_file, implode("\n", $headers) . "\n");
		$command = array_merge($command, ['-H', '@' . $header_file]);
	}
	list($code, $output) = manage_run(array_merge($command, [$url]), [], (string)$body);
	if ($header_file !== null) {
		unlink($header_file);
	}
	// The status code comes last, after a newline (which manage_run trims away when the body is empty)
	if ($code !== 0 || !preg_match('/^(.*?)\n?(\d{3})$/s', $output, $m)) {
		return [0, ''];
	}
	return [(int)$m[2], $m[1]];
}

function manage_http_get($url, $timeout = 3)
{
	return manage_http_request('GET', $url, null, $timeout);
}

// Whether the process in a PID file (e.g. /var/run/mailpit.pid) is running
function manage_pid_running($pid_file)
{
	$pid = (int)@file_get_contents($pid_file);
	return $pid > 0 && file_exists('/proc/' . $pid);
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

// JavaScript for showing a secret (a password or token) on request, to echo inside a page's script (its closure):
//     var secret = mgSecret(codeElement, showButton, copyButton, load);
// load() returns a promise of the secret (or null, e.g. after saying why it failed). Show fetches and displays it, and
// becomes Hide (which puts the dots back); Copy copies it without showing it. secret.set(value) shows a new value (e.g.
// after changing a password), secret.reset() hides it and forgets it (e.g. after a new token was issued)
function manage_secret_script()
{
	echo <<<'JS'
		function mgCopy(text) {
			// The clipboard API only exists on secure (https) pages - the dashboard is often plain http
			if (navigator.clipboard && window.isSecureContext) {
				return navigator.clipboard.writeText(text).then(function () { return true; }, function () { return false; });
			}
			var area = document.createElement('textarea');
			area.value = text;
			area.setAttribute('readonly', '');
			area.style.position = 'fixed';
			area.style.left = '-9999px';
			document.body.appendChild(area);
			area.select();
			var ok = false;
			try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
			document.body.removeChild(area);
			return Promise.resolve(ok);
		}

		function mgSecret(code, show, copy, load) {
			var dots = code.textContent;
			var value = null;
			var shown = false;
			function display(on) {
				shown = on;
				code.textContent = on ? value : dots;
				show.textContent = on ? 'Hide' : 'Show';
			}
			function get() {
				return value !== null ? Promise.resolve(value) : load().then(function (secret) {
					if (secret !== null && secret !== undefined) { value = secret; }
					return value;
				});
			}
			show.addEventListener('click', function () {
				if (shown) { display(false); return; }
				get().then(function (secret) { if (secret !== null) { display(true); } });
			});
			copy.addEventListener('click', function () {
				get().then(function (secret) {
					if (secret === null) { return; }
					mgCopy(secret).then(function (ok) {
						copy.textContent = ok ? 'Copied' : 'Copy failed';
						setTimeout(function () { copy.textContent = 'Copy'; }, 1500);
					});
				});
			});
			return {
				set: function (secret) { value = secret; display(true); },
				reset: function () { value = null; display(false); }
			};
		}

JS;
}

// The shared look of management pages, scoped to the page's own element (pages are injected into the dashboard's window,
// so unscoped rules would restyle the dashboard itself)
function manage_styles($id)
{
	$s = '#' . $id;
	echo "<style>
		{$s} { font-family: inherit; color: inherit; padding: 0.5rem 0; line-height: 1.5; white-space: normal; }
		{$s} h2 { font-size: 1.3em; font-weight: bold; margin: 0 0 0.75rem; }
		{$s} h3 { font-size: 1.05em; font-weight: bold; margin: 2rem 0 0.75rem; padding-top: 1.25rem; border-top: 1px solid rgba(127, 127, 127, 0.3); }
		{$s} .mg-section { margin-top: 2rem; padding-top: 1.25rem; border-top: 1px solid rgba(127, 127, 127, 0.3); }
		{$s} p { margin: 0.6rem 0; }
		{$s} table { border-collapse: collapse; }
		{$s} td { padding: 0.15rem 1rem 0.15rem 0; vertical-align: top; }
		{$s} code { background: rgba(127, 127, 127, 0.15); border-radius: 4px; padding: 0.1rem 0.35rem; word-break: break-all; }
		{$s} input[type=text] { width: 22rem; max-width: 100%; padding: 0.3rem; }
		{$s} input::placeholder { color: #b0b0b0; opacity: 1; }
		{$s} select, {$s} input[type=number] { box-sizing: border-box; height: 32px; padding: 0 6px; border: 1px solid #c8c8c8; border-radius: 0; outline: 0; background-color: #f0f0f0; color: #4b5a68; font: 14px Arial, Helvetica, sans-serif; vertical-align: middle; cursor: pointer; }
		{$s} select:focus, {$s} input[type=number]:focus { border-color: #0099ff; }
		{$s} input[type=number] { cursor: text; }
		{$s} button, {$s} a.mg-button { display: inline-block; margin: 0.2rem 0.4rem 0.2rem 0; padding: 0.3rem 0.8rem; cursor: pointer; }
		{$s} a.mg-button { text-decoration: none; color: #fafafa; border-top: 1px solid #15abff; border-bottom: 1px solid #0067a6; outline: 1px solid #0067a6; background-color: #018be3; background-image: linear-gradient(to bottom, #0099ff, #027dc8); background-origin: border-box; background-repeat: no-repeat; box-sizing: border-box; height: 32px; padding-top: 0; padding-bottom: 0; font: 14px Arial, Helvetica, sans-serif; line-height: 30px; }
		{$s} a.mg-button:hover { background-image: linear-gradient(to bottom, #027dc8, #0099ff); }
		{$s} [hidden] { display: none !important; }
		{$s} .mg-ok { color: #2e7d32; }
		{$s} .mg-bad { color: #c62828; }
		{$s} .mg-note { opacity: 0.75; font-size: 0.9em; }
	</style>\n";
}
