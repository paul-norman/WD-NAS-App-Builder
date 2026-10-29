<?php
// kvweb's address in the Nginx app, for the management page

const KVWEB_TARGET = 'http://127.0.0.1:8082';

// Where the Nginx app serves kvweb: ['state' => ok|no_nginx|no_domain|off, 'url' => address or '']. It's the enabled app
// whose target is kvweb's port (offered by the Nginx app as "kvweb", but it can be renamed)
function kvweb_site($apps_path)
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
		if ($app['enabled'] && rtrim($app['target'], '/') === KVWEB_TARGET) {
			return ['state' => 'ok', 'url' => 'https://' . sites_host($settings, $app) . '/'];
		}
	}
	return ['state' => 'off', 'url' => ''];
}
