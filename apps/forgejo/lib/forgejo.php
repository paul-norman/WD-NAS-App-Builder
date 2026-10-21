<?php
// Forgejo's address in the Nginx app, and the settings the app keeps current in Forgejo's app.ini. Used by the management
// page, and by forgejo_ctl.sh through the NAS's PHP CLI (WD's PHP 7.4, or the PHP app's 8.5), so it must work on both:
//     php forgejo.php configure <apps path> <app.ini> <listen: all|local> <ssh: 0|1> <nas ip> <git program>
//         - sets the address, listening address, SSH server and git program in app.ini (other settings are left alone)

const FORGEJO_TARGET = 'http://127.0.0.1:3002';
const FORGEJO_PORT = 3002;
const FORGEJO_SSH_PORT = 2222;

// Where the Nginx app serves Forgejo: ['state' => ok|no_nginx|no_domain|off, 'url' => address or '']. It's the enabled
// app whose target is Forgejo's port (offered by the Nginx app as "git", but it can be renamed)
function forgejo_site($apps_path)
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
		if ($app['enabled'] && rtrim($app['target'], '/') === FORGEJO_TARGET) {
			return ['state' => 'ok', 'url' => 'https://' . $app['name'] . '.' . $settings['domain'] . '/'];
		}
	}
	return ['state' => 'off', 'url' => ''];
}

// A setting from app.ini's text (e.g. 'server', 'ROOT_URL'), or ''
function forgejo_ini_get($text, $section, $key)
{
	$current = '';
	foreach (preg_split('/\r?\n/', $text) as $line) {
		if (preg_match('/^\s*\[([^\]]+)\]/', $line, $m)) {
			$current = trim($m[1]);
		} elseif ($current === $section && preg_match('/^\s*' . preg_quote($key, '/') . '\s*=\s*(.*?)\s*$/', $line, $m)) {
			return $m[1];
		}
	}
	return '';
}

// app.ini's text with the given settings (['section' => ['KEY' => value]]) replaced, or added to their section (which is
// added if missing). Everything else - comments included - is kept as it is
function forgejo_ini_set($text, array $values)
{
	$lines = preg_split('/\r?\n/', rtrim($text, "\r\n"));
	foreach ($values as $section => $keys) {
		foreach ($keys as $key => $value) {
			$current = '';
			// Where a new setting goes: after the section's last setting (or its header)
			$insert_at = -1;
			$done = false;
			foreach ($lines as $i => $line) {
				if (preg_match('/^\s*\[([^\]]+)\]/', $line, $m)) {
					$current = trim($m[1]);
					if ($current === $section) {
						$insert_at = $i;
					}
				} elseif ($current === $section && preg_match('/^\s*' . preg_quote($key, '/') . '\s*=/', $line)) {
					$lines[$i] = $key . ' = ' . $value;
					$done = true;
					break;
				} elseif ($current === $section && preg_match('/^\s*[^\s;#]/', $line)) {
					$insert_at = $i;
				}
			}
			if ($done) {
				continue;
			}
			if ($insert_at < 0) {
				$lines[] = '';
				$lines[] = '[' . $section . ']';
				$lines[] = $key . ' = ' . $value;
			} else {
				array_splice($lines, $insert_at + 1, 0, [$key . ' = ' . $value]);
			}
		}
	}
	return implode("\n", $lines) . "\n";
}

// Sets the app's settings in app.ini (written in one step, keeping its owner and permissions)
function forgejo_configure($apps_path, $ini, $listen, $ssh, $ip, $git)
{
	$text = @file_get_contents($ini);
	if ($text === false) {
		return 'Could not read ' . $ini;
	}
	$site = forgejo_site($apps_path);
	$url = $site['url'] !== '' ? $site['url'] : 'http://' . $ip . ':' . FORGEJO_PORT . '/';
	$domain = parse_url($url, PHP_URL_HOST);
	$text = forgejo_ini_set($text, [
		'server' => [
			'ROOT_URL' => $url,
			'DOMAIN' => $domain,
			'SSH_DOMAIN' => $domain,
			'HTTP_ADDR' => $listen === 'local' ? '127.0.0.1' : '0.0.0.0',
			'START_SSH_SERVER' => $ssh ? 'true' : 'false',
			'DISABLE_SSH' => $ssh ? 'false' : 'true',
		],
		'git' => ['PATH' => $git],
	]);
	$stat = stat($ini);
	$temp = $ini . '.tmp';
	if (file_put_contents($temp, $text) === false || !chmod($temp, $stat['mode'] & 0777)
		|| !chown($temp, $stat['uid']) || !chgrp($temp, $stat['gid']) || !rename($temp, $ini)) {
		@unlink($temp);
		return 'Could not write ' . $ini;
	}
	return '';
}

if (PHP_SAPI === 'cli' && isset($argv[0]) && realpath($argv[0]) === __FILE__) {
	if (!isset($argv[7]) || $argv[1] !== 'configure' || !is_dir($argv[2])) {
		fwrite(STDERR, "Usage: php forgejo.php configure <apps path> <app.ini> <all|local> <0|1> <nas ip> <git program>\n");
		exit(2);
	}
	$error = forgejo_configure($argv[2], $argv[3], $argv[4], $argv[5] === '1', $argv[6], $argv[7]);
	if ($error !== '') {
		fwrite(STDERR, $error . "\n");
		exit(1);
	}
}
