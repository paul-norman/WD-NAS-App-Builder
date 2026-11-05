<?php
require_once dirname(__DIR__).'/manage/manage_helpers.php';

// Paperless's address in the Nginx app. Used by the management page, and by pl_ctl.sh through the NAS's PHP CLI (WD's
// PHP 7.4, or the PHP app's 8.5), so it must work on both:
//     php paperless.php url <apps path>    - prints Paperless's address (e.g. https://paperless.nas.example.com/), if any
const PAPERLESS_TARGET = 'http://127.0.0.1:8040';

if (PHP_SAPI === 'cli' && isset($argv[0]) && realpath($argv[0]) === __FILE__) {
    if (!isset($argv[1], $argv[2]) || $argv[1] !== 'url' || !is_dir($argv[2])) {
        fwrite(STDERR, "Usage: php paperless.php url <apps path>\n");

        exit(2);
    }

    $site = manage_nginx_site($argv[2], PAPERLESS_TARGET);

    echo $site['url'];
}
