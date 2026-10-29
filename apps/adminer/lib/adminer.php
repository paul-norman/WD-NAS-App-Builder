<?php
// adminer's address in the Nginx app, for the management page

const ADMINER_TARGET = 'http://127.0.0.1:8084';

// Where the Nginx app serves adminer: ['state' => ok|no_nginx|no_domain|off, 'url' => address or '']. It's the enabled app
// whose target is adminer's port (offered by the Nginx app as "adminer", but it can be renamed)
function adminer_site($apps_path)
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
		if ($app['enabled'] && rtrim($app['target'], '/') === ADMINER_TARGET) {
			return ['state' => 'ok', 'url' => 'https://' . sites_host($settings, $app) . '/'];
		}
	}
	return ['state' => 'off', 'url' => ''];
}
