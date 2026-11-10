<?php
require_once dirname(__DIR__).'/manage/manage_helpers.php';

// Vikunja's address in the Nginx app. Used by the management page, and by vikunja_ctl.sh through the NAS's PHP CLI
// (WD's PHP 7.4, or the PHP app's 8.5), so it must work on both:
//     php vikunja.php url <apps path>    - prints Vikunja's address (e.g. https://vikunja.nas.example.com/), if any
const VIKUNJA_TARGET = 'http://127.0.0.1:3456';
const VIKUNJA_PORT   = 3456;

if (PHP_SAPI === 'cli' && isset($argv[0]) && realpath($argv[0]) === __FILE__) {
    if (!isset($argv[1], $argv[2]) || $argv[1] !== 'url' || !is_dir($argv[2])) {
        fwrite(STDERR, "Usage: php vikunja.php url <apps path>\n");

        exit(2);
    }

    $site = manage_nginx_site($argv[2], VIKUNJA_TARGET);

    echo $site['url'];
}
