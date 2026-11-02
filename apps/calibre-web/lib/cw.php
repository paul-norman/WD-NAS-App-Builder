<?php
require_once dirname(__DIR__).'/manage/manage_helpers.php';

// Calibre-Web's address in the Nginx app, for the management page. It also works as a command (with the NAS's PHP CLI -
// WD's PHP 7.4, or the PHP app's 8.5):
//     php cw.php url <apps path>    - prints Calibre-Web's address (e.g. https://books.nas.example.com/), if any
const CW_TARGET = 'http://127.0.0.1:8083';

if (PHP_SAPI === 'cli' && isset($argv[0]) && realpath($argv[0]) === __FILE__) {
    if (!isset($argv[1], $argv[2]) || $argv[1] !== 'url' || !is_dir($argv[2])) {
        fwrite(STDERR, "Usage: php cw.php url <apps path>\n");

        exit(2);
    }

    $site = manage_nginx_site($argv[2], CW_TARGET);

    echo $site['url'];
}
