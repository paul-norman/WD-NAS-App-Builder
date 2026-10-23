<?php
// Calibre-Web's address in the Nginx app, for the management page. It also works as a command (with the NAS's PHP CLI -
// WD's PHP 7.4, or the PHP app's 8.5):
//     php cw.php url <apps path>    - prints Calibre-Web's address (e.g. https://books.nas.example.com/), if any

const CW_TARGET = 'http://127.0.0.1:8083';

// Where the Nginx app serves Calibre-Web: ['state' => ok|no_nginx|no_domain|off, 'url' => address or '']. It's the
// enabled app whose target is Calibre-Web's port (offered by the Nginx app as "books", but it can be renamed)
function cw_site($apps_path)
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
		if ($app['enabled'] && rtrim($app['target'], '/') === CW_TARGET) {
			return ['state' => 'ok', 'url' => 'https://' . (function_exists('sites_host') ? sites_host($settings, $app) : $app['name'] . '.' . $settings['domain']) . '/'];
		}
	}
	return ['state' => 'off', 'url' => ''];
}

if (PHP_SAPI === 'cli' && isset($argv[0]) && realpath($argv[0]) === __FILE__) {
	if (!isset($argv[1], $argv[2]) || $argv[1] !== 'url' || !is_dir($argv[2])) {
		fwrite(STDERR, "Usage: php cw.php url <apps path>\n");
		exit(2);
	}
	$site = cw_site($argv[2]);
	echo $site['url'];
}
