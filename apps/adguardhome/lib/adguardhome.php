<?php
require_once dirname(__DIR__).'/manage/manage_helpers.php';

// AdGuard Home's address in the Nginx app, and its settings file (AdGuardHome.yaml - AdGuard Home writes it itself, so
// only its own lines are changed here). Used by the management page, and by adguardhome_ctl.sh through the NAS's PHP
// CLI (WD's PHP 7.4, or the PHP app's 8.5), so it must work on both:
//     php adguardhome.php url <apps path>                    - prints its address (https://adguard.<domain>/), if any
//     php adguardhome.php new-config <file> <password file>  - writes its first settings: the admin account, DNS on
//                                                              the port the firewall rules forward to, upstream servers
//     php adguardhome.php set-password <file> <password file> - gives the admin account the password in the file
//     php adguardhome.php set-web <file> <host>              - its web interface on this address (127.0.0.1 or 0.0.0.0)
const ADGUARDHOME_TARGET   = 'http://127.0.0.1:8094';
const ADGUARDHOME_WEB_PORT = 8094;
// The port it answers DNS on: the firewall rules forward the network's DNS (port 53) to it
const ADGUARDHOME_DNS_PORT = 5335;
const ADGUARDHOME_ADMIN    = 'admin';
// The settings format of the AdGuard Home the first settings are written for (0.107.80's; without it, AdGuard Home
// takes them for its oldest format, and its newer versions bring them up to date themselves)
const ADGUARDHOME_SCHEMA   = 34;

/**
 * Its first settings file: the admin account (bcrypt, as AdGuard Home's own), its web interface on the NAS itself, DNS
 * on every address at ADGUARDHOME_DNS_PORT, and the upstream servers its own setup offers (Quad9, encrypted, with
 * Quad9's addresses to find it). AdGuard Home adds the rest of its settings, with its defaults, when it starts.
 *
 * @param string $password The admin's password
 *
 * @return string The file's text
 */
function adguardhome_new_config(string $password): string
{
    return "http:\n"
        .'  address: 127.0.0.1:'.ADGUARDHOME_WEB_PORT."\n"
        ."users:\n"
        .'  - name: '.ADGUARDHOME_ADMIN."\n"
        .'    password: '.password_hash($password, PASSWORD_BCRYPT)."\n"
        ."dns:\n"
        ."  bind_hosts:\n"
        ."    - 0.0.0.0\n"
        .'  port: '.ADGUARDHOME_DNS_PORT."\n"
        ."  upstream_dns:\n"
        ."    - https://dns10.quad9.net/dns-query\n"
        ."  bootstrap_dns:\n"
        ."    - 9.9.9.10\n"
        ."    - 149.112.112.10\n"
        .'schema_version: '.ADGUARDHOME_SCHEMA."\n";
}

/**
 * Changes one setting's line in a top-level section of AdGuard Home's settings (e.g. http's address).
 *
 * @param string $text    The settings file's text
 * @param string $section The section (e.g. http)
 * @param string $pattern A regular expression for the line (one of the section's own, e.g. ^  address: .*$)
 * @param string $line    Its new line
 *
 * @return string|null The changed text, or null if the line isn't there
 */
function adguardhome_set_line(string $text, string $section, string $pattern, string $line): ?string
{
    if (!preg_match('/^'.preg_quote($section, '/').":\n((?:[ #].*\n|\n)*)/m", $text, $m, PREG_OFFSET_CAPTURE)) {
        return null;
    }

    $block   = $m[1][0];
    $changed = preg_replace('/'.$pattern.'/m', str_replace(['\\', '$'], ['\\\\', '\\$'], $line), $block, 1, $count);

    if ($count !== 1 || $changed === null) {
        return null;
    }

    return substr_replace($text, $changed, $m[1][1], strlen($block));
}

if (PHP_SAPI === 'cli' && isset($argv[0]) && realpath($argv[0]) === __FILE__) {
    $command = $argv[1] ?? '';

    if ($command === 'url' && isset($argv[2]) && is_dir($argv[2])) {
        $site = manage_nginx_site($argv[2], ADGUARDHOME_TARGET);

        echo $site['url'];

        exit(0);
    }

    if (in_array($command, ['new-config', 'set-password', 'set-web'], true) && isset($argv[2], $argv[3])) {
        $file     = $argv[2];
        $text     = (string)@file_get_contents($file);
        $password = $command === 'set-web' ? '' : trim((string)@file_get_contents($argv[3]));

        if ($command !== 'set-web' && strlen($password) < 8) {
            fwrite(STDERR, "No password (8 characters or more) in {$argv[3]}\n");

            exit(1);
        }

        if ($command === 'new-config') {
            $text = adguardhome_new_config($password);
        } elseif ($command === 'set-password') {
            $text = adguardhome_set_line($text, 'users', '(?<=^  - name: '.ADGUARDHOME_ADMIN.'\n)    password: .*$',
                '    password: '.password_hash($password, PASSWORD_BCRYPT));
        } else {
            $host = $argv[3] === '0.0.0.0' ? '0.0.0.0' : '127.0.0.1';
            $line = '  address: '.$host.':'.ADGUARDHOME_WEB_PORT;
            $text = adguardhome_set_line($text, 'http', '^  address: .*$', $line);
        }

        if ($text === null) {
            fwrite(STDERR, "Its settings file has no such setting (changed by hand?): {$file}\n");

            exit(1);
        }

        // Written whole, then moved into place: AdGuard Home never reads half a file - and still its own (the file's
        // owner kept: this runs as root)
        $owner = is_file($file) ? [fileowner($file), filegroup($file)] : null;
        $fail  = file_put_contents($file.'.tmp', $text) === false || !chmod($file.'.tmp', 0600)
            || ($owner !== null && (!chown($file.'.tmp', $owner[0]) || !chgrp($file.'.tmp', $owner[1])));

        if ($fail || !rename($file.'.tmp', $file)) {
            fwrite(STDERR, "Could not write {$file}\n");

            exit(1);
        }

        exit(0);
    }

    fwrite(STDERR, "Usage: php adguardhome.php url <apps path> | new-config|set-password <file> <password file>"
        ." | set-web <file> <host>\n");

    exit(2);
}
