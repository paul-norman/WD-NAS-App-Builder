<?php
require_once dirname(__DIR__).'/manage/manage_helpers.php';

// Vaultwarden's address in the Nginx app, and changes to settings saved in Vaultwarden's own admin panel. Used by the
// management page, and by vw_ctl.sh through the NAS's PHP CLI (WD's PHP 7.4, or the PHP app's 8.5), so it must work on
// both:
//     php vw.php url <apps path>    - prints Vaultwarden's address (e.g. https://vaultwarden.nas.example.com/), if any
const VW_TARGET = 'http://127.0.0.1:8222';

/**
 * Changes a setting saved in Vaultwarden's admin panel (data/config.json), which overrides its environment: only when
 * it's there.
 *
 * @param string $data_path Vaultwarden's data folder
 * @param string $key       The setting
 * @param mixed  $value     Its value
 *
 * @return bool False only if the file couldn't be rewritten
 */
function vw_config_set(string $data_path, string $key, $value): bool
{
    $file   = $data_path.'/config.json';
    $config = is_file($file) ? json_decode((string)file_get_contents($file), true) : null;

    if (!is_array($config) || !array_key_exists($key, $config)) {
        return true;
    }

    $config[$key] = $value;
    $temp         = $file.'.tmp';
    $json         = json_encode($config, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);

    if ($json === false || file_put_contents($temp, $json) === false) {
        @unlink($temp);

        return false;
    }

    // Keeping it Vaultwarden's own, and private
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

    $site = manage_nginx_site($argv[2], VW_TARGET);

    echo $site['url'];
}
