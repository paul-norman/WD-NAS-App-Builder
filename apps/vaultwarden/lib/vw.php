<?php
// Vaultwarden's address in the Nginx app, and changes to settings saved in Vaultwarden's own admin panel. Used by the
// management page, and by vw_ctl.sh through the NAS's PHP CLI (WD's PHP 7.4, or the PHP app's 8.5), so it must work on
// both:
//     php vw.php url <apps path>    - prints Vaultwarden's address (e.g. https://vaultwarden.nas.example.com/), if any

const VW_TARGET = 'http://127.0.0.1:8222';

// Where the Nginx app serves Vaultwarden: ['state' => ok|no_nginx|no_domain|off, 'url' => address or '']. It's the
// enabled app whose target is Vaultwarden's port (offered by the Nginx app as "vaultwarden", but it can be renamed)
function vw_site($apps_path)
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
		if ($app['enabled'] && rtrim($app['target'], '/') === VW_TARGET) {
			return ['state' => 'ok', 'url' => 'https://' . (function_exists('sites_host') ? sites_host($settings, $app) : $app['name'] . '.' . $settings['domain']) . '/'];
		}
	}
	return ['state' => 'off', 'url' => ''];
}

// Settings saved in Vaultwarden's admin panel (data/config.json) override its environment: when one of them is there,
// it's changed there too. Returns false only if the file couldn't be rewritten
function vw_config_set($data_path, $key, $value)
{
	$file = $data_path . '/config.json';
	$config = is_file($file) ? json_decode((string)file_get_contents($file), true) : null;
	if (!is_array($config) || !array_key_exists($key, $config)) {
		return true;
	}
	$config[$key] = $value;
	$temp = $file . '.tmp';
	$json = json_encode($config, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
	if ($json === false || file_put_contents($temp, $json) === false) {
		@unlink($temp);
		return false;
	}
	// (keeping it Vaultwarden's own, and private)
	@chown($temp, fileowner($file));
	@chgrp($temp, filegroup($file));
	chmod($temp, 0600);
	return rename($temp, $file);
}

if (PHP_SAPI === 'cli' && isset($argv[0]) && realpath($argv[0]) === __FILE__) {
	if (!isset($argv[1], $argv[2]) || $argv[1] !== 'url' || !is_dir($argv[2])) {
		fwrite(STDERR, "Usage: php vw.php url <apps path>\n");
		exit(2);
	}
	$site = vw_site($argv[2]);
	echo $site['url'];
}
