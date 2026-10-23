<?php
// Kopia's address in the Nginx app, and its server's own API, for the management page

const KOPIA_TARGET = 'http://127.0.0.1:51515';

// Where the Nginx app serves Kopia: ['state' => ok|no_nginx|no_domain|off, 'url' => address or '']. It's the enabled app
// whose target is Kopia's port (offered by the Nginx app as "kopia", but it can be renamed)
function kopia_site($apps_path)
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
		if ($app['enabled'] && rtrim($app['target'], '/') === KOPIA_TARGET) {
			return ['state' => 'ok', 'url' => 'https://' . (function_exists('sites_host') ? sites_host($settings, $app) : $app['name'] . '.' . $settings['domain']) . '/'];
		}
	}
	return ['state' => 'off', 'url' => ''];
}

// Reads from Kopia's API (as its web interface does: logged in, with the session cookie and CSRF token its page gives).
// The login goes via a root-only header file, never on curl's command line. Returns the decoded JSON for each path asked
// (null for any that failed), or null if Kopia didn't answer
function kopia_api($password, array $paths)
{
	$dir = sys_get_temp_dir() . '/kopia-manage-' . bin2hex(random_bytes(6));
	if (!@mkdir($dir, 0700)) {
		return null;
	}
	$headers = $dir . '/headers';
	$jar = $dir . '/cookies';
	$get = function ($path, array $extra) use ($password, $headers, $jar) {
		file_put_contents($headers, implode("\n", array_merge(['Authorization: Basic ' . base64_encode('admin:' . $password)], $extra)) . "\n");
		chmod($headers, 0600);
		list($code, $out) = manage_run(['curl', '-s', '-m', '5', '-c', $jar, '-b', $jar, '-H', '@' . $headers, KOPIA_TARGET . $path]);
		return $code === 0 ? $out : '';
	};
	$results = null;
	if (preg_match('/name="kopia-csrf-token" content="([0-9a-f]+)"/', $get('/', []), $m)) {
		$results = [];
		foreach ($paths as $path) {
			$results[$path] = json_decode($get($path, ['X-Kopia-Csrf-Token: ' . $m[1]]), true);
		}
	}
	@unlink($headers);
	@unlink($jar);
	@rmdir($dir);
	return $results;
}
