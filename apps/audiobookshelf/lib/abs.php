<?php
require_once dirname(__DIR__).'/manage/manage_helpers.php';

// Audiobookshelf's address in the Nginx app. Used by the management page, and from the command line through the NAS's
// PHP CLI (WD's PHP 7.4, or the PHP app's 8.5), so it must work on both:
//     php abs.php url <apps path>    - prints Audiobookshelf's address (e.g. https://audiobooks.nas.example.com/), if any
const ABS_TARGET = 'http://127.0.0.1:13378';

if (PHP_SAPI === 'cli' && isset($argv[0]) && realpath($argv[0]) === __FILE__) {
    if (!isset($argv[1], $argv[2]) || $argv[1] !== 'url' || !is_dir($argv[2])) {
        fwrite(STDERR, "Usage: php abs.php url <apps path>\n");

        exit(2);
    }

    $site = manage_nginx_site($argv[2], ABS_TARGET);

    echo $site['url'];
}
