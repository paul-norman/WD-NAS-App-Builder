<?php
// ntfy's address in the Nginx app. Used by the management page, and by ntfy_ctl.sh through the NAS's PHP CLI (WD's
// PHP 7.4, or the PHP app's 8.5), so it must work on both:
//     php ntfy.php url <apps path>    - prints ntfy's address (e.g. https://ntfy.nas.example.com/), if any

const NTFY_TARGET = 'http://127.0.0.1:2586';

// Where the Nginx app serves ntfy: ['state' => ok|no_nginx|no_domain|off, 'url' => address or '']. It's the
// enabled app whose target is ntfy's port (offered by the Nginx app as "ntfy", but it can be renamed)
function ntfy_site($apps_path)
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
		if ($app['enabled'] && rtrim($app['target'], '/') === NTFY_TARGET) {
			return ['state' => 'ok', 'url' => 'https://' . $app['name'] . '.' . $settings['domain'] . '/'];
		}
	}
	return ['state' => 'off', 'url' => ''];
}

if (PHP_SAPI === 'cli' && isset($argv[0]) && realpath($argv[0]) === __FILE__) {
	if (!isset($argv[1], $argv[2]) || $argv[1] !== 'url' || !is_dir($argv[2])) {
		fwrite(STDERR, "Usage: php ntfy.php url <apps path>\n");
		exit(2);
	}
	$site = ntfy_site($argv[2]);
	echo $site['url'];
}
