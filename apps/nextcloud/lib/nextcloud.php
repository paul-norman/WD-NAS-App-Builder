<?php
require_once dirname(__DIR__).'/manage/manage_helpers.php';

// Nextcloud's own settings, and its status. Used by the management page, and by nextcloud_ctl.sh through the NAS's PHP
// CLI (WD's PHP 7.4, or the PHP app's 8.5), so it must work on both:
//     php nextcloud.php config <data path> <app path> <listen> <address>
//         - writes <data path>/config/nas.config.php: the settings the app keeps (Nextcloud merges them with its own
//           config.php, which holds the rest - e.g. its database and secrets)
const NEXTCLOUD_PORT = 8097;

/**
 * The app's settings (KEY=value lines, written by its management page and also read by its control script), with
 * defaults.
 *
 * @param string $file The settings file
 *
 * @return array{ LISTEN: string, BACKUP_DIR: string, BACKUP_KEEP: string }
 */
function nextcloud_settings(string $file): array
{
    $settings = [
        'LISTEN'      => 'local',
        'BACKUP_DIR'  => '',
        'BACKUP_KEEP' => '7',
    ];

    foreach (@file($file, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
        if (preg_match('/^([A-Z_]+)=(.*)$/', $line, $m) && isset($settings[$m[1]])) {
            $settings[$m[1]] = $m[2];
        }
    }

    return $settings;
}

/**
 * The settings the app keeps for Nextcloud: where its data, its apps from the app store and its log are, its memory
 * cache, the addresses it answers to (the NAS's, and the Nginx app's site), the Nginx app as a proxy it trusts (for
 * visitors' own addresses, and HTTPS), and no updating itself (the app's updates bring new versions).
 *
 * @param string $data_path The app's data folder
 * @param string $app_path  The app's folder
 * @param string $listen    all (also on the local network) or local
 * @param string $address   The NAS's address on the network ('' if unknown)
 * @param string $site      The Nginx app's site for it (e.g. https://nextcloud.nas.example.com/), or ''
 *
 * @return array<string, mixed> The settings
 */
function nextcloud_config(string $data_path, string $app_path, string $listen, string $address, string $site): array
{
    $domains = ['127.0.0.1', 'localhost'];
    $host    = (string)parse_url($site, PHP_URL_HOST);
    $name    = (string)gethostname();

    if ($host !== '') {
        $domains[] = $host;
    }

    if ($listen === 'all') {
        foreach ([$address, $name] as $domain) {
            if ($domain !== '') {
                $domains[] = $domain;
            }
        }
    }

    return [
        'datadirectory'            => $data_path.'/data',
        'apps_paths'               => [
            ['path' => $app_path.'/binaries/nextcloud/apps', 'url' => '/apps', 'writable' => false],
            ['path' => $data_path.'/custom_apps', 'url' => '/custom_apps', 'writable' => true],
        ],
        'tempdirectory'            => $data_path.'/run/tmp',
        'logfile'                  => $data_path.'/logs/nextcloud.log',
        'log_type'                 => 'file',
        'loglevel'                 => 2,
        'log_rotate_size'          => 10485760,
        'memcache.local'           => '\\OC\\Memcache\\APCu',
        'trusted_domains'          => array_values(array_unique($domains)),
        'trusted_proxies'          => ['127.0.0.1'],
        'overwrite.cli.url'        => $site !== '' ? rtrim($site, '/') : ($address !== '' && $listen === 'all' ? 'http://'.$address.':'.NEXTCLOUD_PORT : 'http://127.0.0.1:'.NEXTCLOUD_PORT),
        'htaccess.RewriteBase'     => '/',
        'upgrade.disable-web'      => true,
        'updatechecker'            => false,
        // Its heavier background jobs at night (from 1am, for four hours)
        'maintenance_window_start' => 1,
    ];
}

/**
 * Writes the app's settings for Nextcloud: <data path>/config/nas.config.php (root's, readable by Nextcloud).
 *
 * @param string               $data_path The app's data folder
 * @param array<string, mixed> $config    The settings
 *
 * @return bool Whether it was written
 */
function nextcloud_write_config(string $data_path, array $config): bool
{
    $file = $data_path.'/config/nas.config.php';
    $text = "<?php\n// Written by the Nextcloud app at every start (nextcloud_ctl.sh) - changes here are lost. Nextcloud merges these\n"
        ."// settings with config.php's\n\$CONFIG = ".var_export($config, true).";\n";

    if (@file_put_contents($file.'.tmp', $text) === false) {
        return false;
    }

    chmod($file.'.tmp', 0644);

    return rename($file.'.tmp', $file);
}

/**
 * Nextcloud's status (its status.php), from its web server on the NAS itself.
 *
 * @return array<string, mixed>|null Whether it's installed, its version, whether it's in maintenance mode... or null if
 *                                   it didn't answer
 */
function nextcloud_status(): ?array
{
    list($code, $body) = manage_http_get('http://127.0.0.1:'.NEXTCLOUD_PORT.'/status.php', 10);
    $status            = $code === 200 ? json_decode($body, true) : null;

    return is_array($status) ? $status : null;
}

if (PHP_SAPI === 'cli' && isset($argv[0]) && realpath($argv[0]) === __FILE__) {
    if (($argv[1] ?? '') !== 'config' || !isset($argv[5]) || !is_dir($argv[2])) {
        fwrite(STDERR, "Usage: php nextcloud.php config <data path> <app path> <listen> <address>\n");

        exit(2);
    }

    // Its site in the Nginx app (whatever it's been renamed to), if it has one
    $site = manage_nginx_site(dirname($argv[3]), 'http://127.0.0.1:'.NEXTCLOUD_PORT)['url'];

    exit(nextcloud_write_config($argv[2], nextcloud_config($argv[2], $argv[3], $argv[4], $argv[5], $site)) ? 0 : 1);
}
