<?php
require_once dirname(__DIR__).'/manage/manage_helpers.php';

// Memos' address in the Nginx app. Used by the management page, and by memos_ctl.sh through the NAS's PHP CLI (WD's
// PHP 7.4, or the PHP app's 8.5), so it must work on both:
//     php memos.php url <apps path>    - prints Memos' address (e.g. https://memos.nas.example.com/), if any
const MEMOS_TARGET = 'http://127.0.0.1:5230';
const MEMOS_PORT   = 5230;

if (PHP_SAPI === 'cli' && isset($argv[0]) && realpath($argv[0]) === __FILE__) {
    if (!isset($argv[1], $argv[2]) || $argv[1] !== 'url' || !is_dir($argv[2])) {
        fwrite(STDERR, "Usage: php memos.php url <apps path>\n");

        exit(2);
    }

    $site = manage_nginx_site($argv[2], MEMOS_TARGET);

    echo $site['url'];
}
