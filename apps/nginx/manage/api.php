<?php
// Nginx management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('nginx');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path = dirname(__DIR__);
$data_path = dirname($app_path) . '/_nginx';
$acme_path = $data_path . '/acme';
$lego = $app_path . '/binaries/lego';
$job_pid_file = '/var/run/nginx_cert_job.pid';
$job_log_file = $acme_path . '/last.log';
// The sites' PHP: the PHP app's php-fpm (see nginx_ctl.sh)
$php_fpm = dirname($app_path) . '/php/binaries/php-fpm';
require $app_path . '/lib/sites.php';

// The CAs offered by name (lego's short codes); any other ACME server can be given by its URL
$acme_servers = ['letsencrypt' => "Let's Encrypt", 'googletrust' => 'Google Trust Services', 'zerossl' => 'ZeroSSL'];

// Runs nginx with the app's configuration
function ng_nginx($app_path, $data_path, array $args)
{
	return manage_run(array_merge([$app_path . '/binaries/nginx', '-p', $data_path . '/', '-c', $data_path . '/nginx.conf'], $args));
}

function ng_job_running($pid_file)
{
	return manage_pid_running($pid_file);
}

// The certificate settings (written by this page as shell variables, sourced by cert.sh)
function ng_settings($acme_path)
{
	$settings = ['ACME_ENABLED' => '', 'ACME_DOMAIN' => '', 'ACME_EMAIL' => '', 'ACME_SERVER' => 'letsencrypt', 'ACME_PROVIDER' => '', 'ACME_EAB_KID' => '', 'ACME_EAB_HMAC' => ''];
	foreach (explode("\n", (string)@file_get_contents($acme_path . '/settings.conf')) as $line) {
		if (preg_match("/^(ACME_[A-Z_]+)='([^']*)'$/", $line, $m) && array_key_exists($m[1], $settings)) {
			$settings[$m[1]] = $m[2];
		}
	}
	return $settings;
}

function ng_save_settings($acme_path, array $settings)
{
	$lines = '';
	foreach ($settings as $name => $value) {
		$lines .= $name . "='" . $value . "'\n";
	}
	return manage_write_file($acme_path . '/settings.conf', $lines);
}

// The provider's credentials (lego's env file format: NAME="value")
function ng_credentials($acme_path)
{
	$credentials = [];
	foreach (explode("\n", (string)@file_get_contents($acme_path . '/credentials.env')) as $line) {
		if (preg_match('/^([A-Z0-9_]+)="((?:[^"\\\\]|\\\\.)*)"$/', $line, $m)) {
			$credentials[$m[1]] = stripcslashes($m[2]);
		}
	}
	return $credentials;
}

function ng_save_credentials($acme_path, array $credentials)
{
	$lines = '';
	foreach ($credentials as $name => $value) {
		$lines .= $name . '="' . addcslashes($value, "\\\"\$") . "\"\n";
	}
	return manage_write_file($acme_path . '/credentials.env', $lines);
}

// lego's DNS providers (their codes), from its own help
function ng_providers($lego)
{
	list(, $output) = manage_run([$lego, 'dnshelp']);
	if (!preg_match('/Supported DNS providers:\s*(.+?)(\n\s*\n|$)/s', $output, $m)) {
		return [];
	}
	// (not "manual", which waits for someone to type at a terminal)
	return array_values(array_filter(array_map('trim', explode(',', $m[1])), function ($code) {
		return preg_match('/^[a-z0-9]+$/', $code) && $code !== 'manual';
	}));
}

// One provider's settings, from lego's help for it: its name and its credentials / additional configuration
function ng_provider($lego, $code)
{
	list($status, $output) = manage_run([$lego, 'dnshelp', '-c', $code]);
	if ($status !== 0) {
		return null;
	}
	$provider = ['code' => $code, 'name' => preg_match('/^Configuration for (.+?)\.?$/m', $output, $m) ? $m[1] : $code,
		'url' => preg_match('/More information: (\S+)/', $output, $m) ? $m[1] : '', 'fields' => []];
	$group = '';
	foreach (explode("\n", $output) as $line) {
		if (preg_match('/^(Credentials|Additional Configuration):/', $line, $m)) {
			$group = $m[1] === 'Credentials' ? 'credentials' : 'additional';
		} elseif ($group !== '' && preg_match('/^\s+- "([A-Z0-9_]+)":\s*(.*)$/', $line, $m)) {
			$provider['fields'][] = ['name' => $m[1], 'description' => trim($m[2]), 'group' => $group];
		}
	}
	return $provider;
}

// The current certificate: who it's for, who issued it, and until when
function ng_certificate($data_path)
{
	$pem = (string)@file_get_contents($data_path . '/certs/default.crt');
	$cert = $pem !== '' ? @openssl_x509_parse($pem) : false;
	if (!$cert) {
		return null;
	}
	$names = [];
	foreach (explode(',', isset($cert['extensions']['subjectAltName']) ? $cert['extensions']['subjectAltName'] : '') as $name) {
		if (strpos(trim($name), 'DNS:') === 0) {
			$names[] = substr(trim($name), 4);
		}
	}
	$issuer = isset($cert['issuer']['O']) ? $cert['issuer']['O'] : (isset($cert['issuer']['CN']) ? $cert['issuer']['CN'] : '');
	return [
		'names' => $names,
		'issuer' => $issuer,
		'self_signed' => $cert['issuer'] == $cert['subject'],
		'staging' => stripos(json_encode($cert['issuer']), 'staging') !== false || stripos(json_encode($cert['issuer']), 'fake') !== false,
		'expires' => date('Y-m-d', $cert['validTo_time_t']),
		'days_left' => (int)floor(($cert['validTo_time_t'] - time()) / 86400),
	];
}

// The NAS's own address on the local network (for the DNS records to add)
function ng_nas_ip()
{
	list(, $output) = manage_run(['ip', '-o', '-4', 'addr', 'show', 'scope', 'global']);
	foreach (explode("\n", $output) as $line) {
		if (preg_match('#^\d+:\s+(\S+)\s+inet\s+(\d+\.\d+\.\d+\.\d+)/#', $line, $m) && !preg_match('/^(docker|br-|veth|tailscale|lo)/', $m[1])) {
			return $m[2];
		}
	}
	return '';
}

// Checks Nginx's configuration, then reloads it (Nginx keeps running on the old one if it's broken): [ok, message]
function ng_reload($app_path)
{
	list($code, $output) = manage_run(['/bin/sh', $app_path . '/nginx_ctl.sh', 'reload']);
	return [$code === 0, $output];
}

$action = isset($_GET['action']) ? $_GET['action'] : 'status';

if ($action === 'status') {
	$pid = (int)@file_get_contents($data_path . '/logs/nginx.pid');
	list(, $version) = ng_nginx($app_path, $data_path, ['-v']);
	list($test_code, $test) = ng_nginx($app_path, $data_path, ['-t']);
	$settings = ng_settings($acme_path);
	$sites = sites_load($data_path);
	$error_log = is_file($data_path . '/logs/error.log') ? file($data_path . '/logs/error.log', FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) : [];
	manage_json([
		'running' => $pid > 0 && file_exists('/proc/' . $pid),
		'version' => preg_match('#nginx/(\S+)#', $version, $m) ? $m[1] : '',
		'config_ok' => $test_code === 0,
		'config_test' => $test,
		'certificate' => ng_certificate($data_path),
		'acme' => [
			'enabled' => $settings['ACME_ENABLED'] === 'yes',
			'domain' => $settings['ACME_DOMAIN'],
			'email' => $settings['ACME_EMAIL'],
			'server' => $settings['ACME_SERVER'],
			'provider' => $settings['ACME_PROVIDER'],
			'eab' => $settings['ACME_EAB_KID'] !== '',
			// Only which credentials are saved, never their values
			'saved' => array_keys(ng_credentials($acme_path)),
		],
		'servers' => $acme_servers,
		'domain' => $sites['domain'],
		'home' => $sites['home'],
		'start_name' => SITES_START_NAME,
		'apps' => $sites['apps'],
		'sites' => $sites['sites'],
		'php' => [
			'available' => is_executable($php_fpm),
			'version' => is_executable($php_fpm) && preg_match('/^PHP (\S+)/m', manage_run([$php_fpm, '-n', '-v'])[1], $m) ? $m[1] : '',
			'running' => manage_pid_running($data_path . '/logs/php-fpm.pid'),
		],
		'known' => array_keys(sites_known_apps()),
		'own_sites' => sites_own_names($data_path),
		'nas_ip' => ng_nas_ip(),
		'job_running' => ng_job_running($job_pid_file),
		'job_log' => (string)@file_get_contents($job_log_file),
		'error_log' => array_slice($error_log, -30),
	]);
}

if ($action === 'providers') {
	manage_json(['providers' => ng_providers($lego)]);
}

if ($action === 'provider') {
	$code = isset($_GET['code']) ? (string)$_GET['code'] : '';
	$provider = preg_match('/^[a-z0-9]{1,40}$/', $code) ? ng_provider($lego, $code) : null;
	if ($provider === null) {
		manage_fail(400, 'Unknown DNS provider: ' . $code);
	}
	manage_json(['provider' => $provider]);
}

manage_require_action('nginx');

if ($action === 'save_apps') {
	$apps = json_decode(isset($_POST['apps']) ? (string)$_POST['apps'] : '', true);
	if (!is_array($apps)) {
		manage_fail(400, 'No apps given');
	}
	$checked = [];
	$names = [];
	foreach ($apps as $app) {
		$app = [
			'name' => strtolower(trim((string)(isset($app['name']) ? $app['name'] : ''))),
			'label' => trim((string)(isset($app['label']) ? $app['label'] : '')),
			'target' => trim((string)(isset($app['target']) ? $app['target'] : '')),
			'host' => trim((string)(isset($app['host']) ? $app['host'] : '')),
			'path' => trim((string)(isset($app['path']) ? $app['path'] : '')),
			'stream' => !empty($app['stream']),
			'uploads' => !empty($app['uploads']),
			'enabled' => !empty($app['enabled']),
		];
		if ($app['label'] === '') {
			$app['label'] = $app['name'];
		}
		if (($error = sites_check_app($app)) !== '') {
			manage_fail(400, $error);
		}
		if (isset($names[$app['name']])) {
			manage_fail(400, 'Each name can only be used once: ' . $app['name']);
		}
		$names[$app['name']] = true;
		$checked[] = $app;
	}
	// The app shown at the domain itself ('' for the start page)
	$home = isset($_POST['home']) ? (string)$_POST['home'] : '';
	if ($home !== '' && !isset($names[$home])) {
		manage_fail(400, 'Choose one of the apps for the domain itself: ' . $home);
	}
	$settings = sites_load($data_path);
	foreach ($settings['sites'] as $site) {
		if (isset($names[$site['name']])) {
			manage_fail(400, 'A site already uses this name: ' . $site['name']);
		}
	}
	$settings['apps'] = $checked;
	$settings['home'] = $home;
	if (!manage_write_file($data_path . '/apps.json', json_encode($settings, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n")) {
		manage_fail(500, 'Could not save the apps');
	}
	if (($error = sites_generate($data_path)) !== '') {
		manage_fail(500, $error);
	}
	list($ok, $output) = ng_reload($app_path);
	if (!$ok) {
		manage_fail(500, "Saved, but Nginx's configuration has an error, so it carries on with the previous one: " . $output);
	}
	manage_json([]);
}

if ($action === 'save_sites') {
	$sites = json_decode(isset($_POST['sites']) ? (string)$_POST['sites'] : '', true);
	if (!is_array($sites)) {
		manage_fail(400, 'No sites given');
	}
	$settings = sites_load($data_path);
	$names = [];
	foreach ($settings['apps'] as $app) {
		$names[$app['name']] = 'An app already uses this name: ';
	}
	$checked = [];
	foreach ($sites as $site) {
		$site = [
			'name' => strtolower(trim((string)(isset($site['name']) ? $site['name'] : ''))),
			'label' => trim((string)(isset($site['label']) ? $site['label'] : '')),
			'root' => trim((string)(isset($site['root']) ? $site['root'] : '')),
			'php' => !empty($site['php']),
			'front' => !empty($site['front']),
			'enabled' => !empty($site['enabled']),
		];
		if ($site['label'] === '') {
			$site['label'] = $site['name'];
		}
		if (($error = sites_check_site($site)) !== '') {
			manage_fail(400, $error);
		}
		if (isset($names[$site['name']])) {
			manage_fail(400, $names[$site['name']] . $site['name']);
		}
		$names[$site['name']] = 'Each name can only be used once: ';
		$checked[] = $site;
	}
	$settings['sites'] = $checked;
	if (!manage_write_file($data_path . '/apps.json', json_encode($settings, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n")) {
		manage_fail(500, 'Could not save the sites');
	}
	if (($error = sites_generate($data_path)) !== '') {
		manage_fail(500, $error);
	}
	list($ok, $output) = ng_reload($app_path);
	if (!$ok) {
		manage_fail(500, "Saved, but Nginx's configuration has an error, so it carries on with the previous one: " . $output);
	}
	manage_json([]);
}

if ($action === 'restart_php') {
	if (!is_executable($php_fpm)) {
		manage_fail(400, 'Install the PHP app first - it provides PHP for the sites');
	}
	list($code, $output) = manage_run(['/bin/sh', $app_path . '/nginx_ctl.sh', 'php-restart']);
	if (!manage_pid_running($data_path . '/logs/php-fpm.pid')) {
		manage_fail(500, 'PHP could not start: ' . $output . ' (see ' . $data_path . '/logs/php-fpm.log)');
	}
	manage_json([]);
}

if ($action === 'issue') {
	if (ng_job_running($job_pid_file)) {
		manage_fail(409, 'A certificate is already being requested');
	}
	$settings = ng_settings($acme_path);
	$domain = strtolower(trim(isset($_POST['domain']) ? (string)$_POST['domain'] : ''));
	$email = trim(isset($_POST['email']) ? (string)$_POST['email'] : '');
	$server = trim(isset($_POST['server']) ? (string)$_POST['server'] : '');
	$provider_code = isset($_POST['provider']) ? (string)$_POST['provider'] : '';
	$eab_kid = trim(isset($_POST['eab_kid']) ? (string)$_POST['eab_kid'] : '');
	$eab_hmac = trim(isset($_POST['eab_hmac']) ? (string)$_POST['eab_hmac'] : '');

	if (($error = sites_check_domain($domain)) !== '') {
		manage_fail(400, $error);
	}
	if (!filter_var($email, FILTER_VALIDATE_EMAIL) || strpbrk($email, "'\"\\`\$") !== false) {
		manage_fail(400, 'Not an email address: ' . $email);
	}
	if (!isset($acme_servers[$server]) && !preg_match('#^https://[A-Za-z0-9.-]+(:\d{1,5})?(/[A-Za-z0-9._~/-]*)?$#', $server)) {
		manage_fail(400, 'Not an ACME server address (https://...): ' . $server);
	}
	$provider = preg_match('/^[a-z0-9]{1,40}$/', $provider_code) ? ng_provider($lego, $provider_code) : null;
	if ($provider === null) {
		manage_fail(400, 'Unknown DNS provider: ' . $provider_code);
	}
	// External account binding (some CAs need it): a key ID and a base64url key, or the ones saved before
	if ($eab_kid === '' && $eab_hmac === '' && $settings['ACME_SERVER'] === $server) {
		$eab_kid = $settings['ACME_EAB_KID'];
		$eab_hmac = $settings['ACME_EAB_HMAC'];
	}
	if ($eab_kid !== '' && (!preg_match('/^[A-Za-z0-9_-]{1,200}$/', $eab_kid) || !preg_match('/^[A-Za-z0-9_-]{1,500}$/', $eab_hmac))) {
		manage_fail(400, 'External account binding needs a key ID and an HMAC key (letters, digits, _ and -)');
	}

	// The provider's credentials: the values saved for the same provider, updated by the fields filled in (empty fields
	// keep them) and by "other variables" (NAME=value lines, for settings lego doesn't describe - NAME= removes one)
	$credentials = $settings['ACME_PROVIDER'] === $provider_code ? ng_credentials($acme_path) : [];
	$given = isset($_POST['credentials']) && is_array($_POST['credentials']) ? $_POST['credentials'] : [];
	foreach ($provider['fields'] as $field) {
		$value = isset($given[$field['name']]) ? trim((string)$given[$field['name']]) : '';
		if ($value !== '') {
			$credentials[$field['name']] = $value;
		}
	}
	foreach (preg_split('/\r?\n/', isset($_POST['other']) ? (string)$_POST['other'] : '') as $line) {
		if (trim($line) === '') {
			continue;
		}
		if (!preg_match('/^\s*([A-Z][A-Z0-9_]{0,99})=(.*)$/', $line, $m)) {
			manage_fail(400, 'Other variables are NAME=value, one per line: ' . $line);
		}
		if (trim($m[2]) === '') {
			unset($credentials[$m[1]]);
		} else {
			$credentials[$m[1]] = trim($m[2]);
		}
	}
	foreach ($credentials as $name => $value) {
		if (preg_match('/[\x00-\x1f]/', $value)) {
			manage_fail(400, 'Values are a single line, for: ' . $name);
		}
	}
	if (!$credentials) {
		manage_fail(400, 'Enter the credentials for ' . $provider['name'] . ' (see its documentation for what they are)');
	}

	$settings = ['ACME_ENABLED' => 'yes', 'ACME_DOMAIN' => $domain, 'ACME_EMAIL' => $email, 'ACME_SERVER' => $server,
		'ACME_PROVIDER' => $provider_code, 'ACME_EAB_KID' => $eab_kid, 'ACME_EAB_HMAC' => $eab_hmac];
	if (!ng_save_settings($acme_path, $settings) || !ng_save_credentials($acme_path, $credentials)) {
		manage_fail(500, 'Could not save the certificate settings');
	}

	// The apps' names use the same domain
	$sites = sites_load($data_path);
	$sites['domain'] = $domain;
	manage_write_file($data_path . '/apps.json', json_encode($sites, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
	sites_generate($data_path);

	// Getting a certificate can take a few minutes (DNS changes have to spread), so it runs in the background, detached
	// from this request; the page follows its progress
	$job = 'echo $$ > "$1"; /bin/sh "$0/cert.sh" issue > "$2" 2>&1; echo "Finished (exit code $?)" >> "$2"; rm -f "$1"';
	manage_run(['/bin/sh', '-c', '/bin/sh -c "$0" "$1" "$2" "$3" > /dev/null 2>&1 < /dev/null &', $job, $app_path, $job_pid_file, $job_log_file]);
	for ($i = 0; $i < 20 && !ng_job_running($job_pid_file); $i++) {
		usleep(100000);
	}
	manage_json([]);
}

if ($action === 'own_certificate') {
	// A certificate (with its chain) and its private key, in PEM format
	$cert = trim(isset($_POST['certificate']) ? (string)$_POST['certificate'] : '') . "\n";
	$key = trim(isset($_POST['key']) ? (string)$_POST['key'] : '') . "\n";
	$x509 = @openssl_x509_read($cert);
	$private = @openssl_pkey_get_private($key);
	if (!$x509 || !$private) {
		manage_fail(400, 'Paste the certificate and its private key in PEM format (-----BEGIN ...)');
	}
	if (!openssl_x509_check_private_key($x509, $private)) {
		manage_fail(400, "The private key doesn't belong to the certificate");
	}
	$certs = $data_path . '/certs';
	if (!manage_write_file($certs . '/default.key', $key) || !chmod($certs . '/default.key', 0600) || !manage_write_file($certs . '/default.crt', $cert)) {
		manage_fail(500, 'Could not save the certificate');
	}
	// Not renewed by the app any more
	$settings = ng_settings($acme_path);
	$settings['ACME_ENABLED'] = '';
	ng_save_settings($acme_path, $settings);
	list($ok, $output) = ng_reload($app_path);
	if (!$ok) {
		manage_fail(500, "Saved, but Nginx's configuration has an error: " . $output);
	}
	manage_json([]);
}

// Empties a log: the certificate request's (not while one is running), or Nginx's error log (Nginx appends to it, so it
// carries on at the start)
if ($action === 'clear_log') {
	$log = isset($_POST['log']) ? (string)$_POST['log'] : '';
	if ($log === 'certificate') {
		if (ng_job_running($job_pid_file)) {
			manage_fail(409, 'A certificate is being requested - wait for it to finish');
		}
		@unlink($job_log_file);
	} elseif ($log === 'error') {
		if (is_file($data_path . '/logs/error.log') && file_put_contents($data_path . '/logs/error.log', '') === false) {
			manage_fail(500, "Could not clear Nginx's error log");
		}
	} else {
		manage_fail(400, 'Unknown log');
	}
	manage_json([]);
}

if ($action === 'reload') {
	list($ok, $output) = ng_reload($app_path);
	if (!$ok) {
		manage_fail(500, "Nginx's configuration has an error, so it carries on with the previous one: " . $output);
	}
	manage_json([]);
}

manage_fail(400, 'Unknown action');
