<?php
require_once dirname(__DIR__).'/manage/manage_helpers.php';

// Grafana's address in the Nginx app. Used by the management page, and by graf_ctl.sh through the NAS's PHP CLI (WD's
// PHP 7.4, or the PHP app's 8.5), so it must work on both:
//     php graf.php url <apps path>    - prints Grafana's address (e.g. https://grafana.nas.example.com/), if any
const GRAF_TARGET = 'http://127.0.0.1:3000';

if (PHP_SAPI === 'cli' && isset($argv[0]) && realpath($argv[0]) === __FILE__) {
    if (!isset($argv[1], $argv[2]) || $argv[1] !== 'url' || !is_dir($argv[2])) {
        fwrite(STDERR, "Usage: php graf.php url <apps path>\n");

        exit(2);
    }

    $site = manage_nginx_site($argv[2], GRAF_TARGET);

    echo $site['url'];
}
