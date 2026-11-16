<?php
require_once dirname(__DIR__).'/manage/manage_helpers.php';

// linkding's addresses. Used by the management page, and by linkding_ctl.sh through the NAS's PHP CLI (WD's PHP 7.4, or
// the PHP app's 8.5), so it must work on both:
//     php linkding.php origins <apps path> <nas ip> <nas name>
//         - prints the addresses linkding accepts forms from (its Nginx site, the NAS's own on its port), with commas
const LINKDING_TARGET = 'http://127.0.0.1:9099';
const LINKDING_PORT   = 9099;

/**
 * The addresses linkding accepts forms from (Django's CSRF check compares a form's origin with them): its Nginx app
 * site's, and the NAS's own on its port - by address and by name.
 *
 * @param string $apps_path Nas_Prog
 * @param string $ip        The NAS's address
 * @param string $name      The NAS's name
 *
 * @return list<string> The addresses (scheme, host and port: no path)
 */
function linkding_origins(string $apps_path, string $ip, string $name): array
{
    $site    = manage_nginx_site($apps_path, LINKDING_TARGET);
    $origins = [];

    if ($site['url'] !== '' && preg_match('#^(https?://[^/]+)#', $site['url'], $m)) {
        $origins[] = $m[1];
    }

    foreach ([$ip, $name] as $host) {
        if (preg_match('/^[A-Za-z0-9.-]+$/', $host)) {
            $origins[] = 'http://'.$host.':'.LINKDING_PORT;
        }
    }

    return array_values(array_unique($origins));
}

if (PHP_SAPI === 'cli' && isset($argv[0]) && realpath($argv[0]) === __FILE__) {
    if (!isset($argv[1], $argv[2], $argv[3], $argv[4]) || $argv[1] !== 'origins' || !is_dir($argv[2])) {
        fwrite(STDERR, "Usage: php linkding.php origins <apps path> <nas ip> <nas name>\n");

        exit(2);
    }

    echo implode(',', linkding_origins($argv[2], $argv[3], $argv[4]));
}
