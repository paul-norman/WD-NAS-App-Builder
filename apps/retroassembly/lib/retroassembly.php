<?php
require_once dirname(__DIR__).'/manage/manage_helpers.php';

// RetroAssembly's address in the Nginx app, and reading its answers. Used by the management page, and by
// retroassembly_ctl.sh through the NAS's PHP CLI (WD's PHP 7.4, or the PHP app's 8.5), so it must work on both:
//     php retroassembly.php url <apps path>    - prints RetroAssembly's address (e.g. https://games.nas.example.com/)
//     php retroassembly.php id < answer        - prints the id in one of its answers (JSON), if any
const RETROASSEMBLY_TARGET = 'http://127.0.0.1:8098';
const RETROASSEMBLY_PORT   = 8098;

if (PHP_SAPI === 'cli' && isset($argv[0]) && realpath($argv[0]) === __FILE__) {
    if (isset($argv[1]) && $argv[1] === 'id') {
        $answer = json_decode((string)stream_get_contents(STDIN), true);

        echo is_array($answer) && isset($answer['id']) && is_string($answer['id']) ? $answer['id'] : '';

        exit(0);
    }

    if (!isset($argv[1], $argv[2]) || $argv[1] !== 'url' || !is_dir($argv[2])) {
        fwrite(STDERR, "Usage: php retroassembly.php url <apps path> | id < answer\n");

        exit(2);
    }

    $site = manage_nginx_site($argv[2], RETROASSEMBLY_TARGET);

    echo $site['url'];
}
