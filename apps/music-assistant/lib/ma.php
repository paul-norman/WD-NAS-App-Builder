<?php
// Music Assistant's address in the Nginx app, for the management page (WD's PHP 7.4, or the PHP app's 8.5)

const MA_TARGET = 'http://127.0.0.1:8095';

// Where the Nginx app serves Music Assistant: ['state' => ok|no_nginx|no_domain|off, 'url' => address or '']. It's the
// enabled app whose target is Music Assistant's port (offered by the Nginx app as "music-assistant", but it can be renamed)
function ma_site($apps_path)
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
		if ($app['enabled'] && rtrim($app['target'], '/') === MA_TARGET) {
			return ['state' => 'ok', 'url' => 'https://' . $app['name'] . '.' . $settings['domain'] . '/'];
		}
	}
	return ['state' => 'off', 'url' => ''];
}
