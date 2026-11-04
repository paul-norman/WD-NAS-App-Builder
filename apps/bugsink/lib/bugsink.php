<?php
require_once dirname(__DIR__).'/manage/manage_helpers.php';

// Bugsink's address, and its settings file (bugsink_conf.py - a Python module), written by the app at every start. Used
// by the management page, and by bugsink_ctl.sh through the NAS's PHP CLI (WD's PHP 7.4, or the PHP app's 8.5), so it
// must work on both:
//     php bugsink.php conf <apps path> <listen: all|local> <nas ip> <nas name>
//         - writes Nas_Prog/_bugsink/conf/bugsink_conf.py (its secret key: Nas_Prog/_bugsink/secret_key, made once)
const BUGSINK_TARGET = 'http://127.0.0.1:8000';
const BUGSINK_PORT   = 8000;

/**
 * Bugsink's address: the Nginx app's site for it, else the NAS's own address on its port. Bugsink builds the addresses
 * it gives other programs (their DSNs) from it.
 *
 * @param string $apps_path Nas_Prog
 * @param string $ip        The NAS's address
 *
 * @return string The address, without a trailing /
 */
function bugsink_base_url(string $apps_path, string $ip): string
{
    $site = manage_nginx_site($apps_path, BUGSINK_TARGET);

    return $site['url'] !== '' ? rtrim($site['url'], '/') : 'http://'.$ip.':'.BUGSINK_PORT;
}

/**
 * A value as a Python literal: strings (JSON's escapes are Python's too), lists of strings, booleans.
 *
 * @param mixed $value The value
 *
 * @return string The literal
 */
function bugsink_py($value): string
{
    if (is_bool($value)) {
        return $value ? 'True' : 'False';
    }

    if (is_array($value)) {
        return '['.implode(', ', array_map('bugsink_py', $value)).']';
    }

    return json_encode((string)$value, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
}

/**
 * Writes Bugsink's settings: its databases and folders in Nas_Prog/_bugsink/data, its address, the host names it
 * answers to (its address's, and the NAS's own on the network), no email (the NAS sends none), and only admins
 * inviting users. Secure cookies only when it's reachable over HTTPS alone (the Nginx app's site, LISTEN=local).
 *
 * @param string $apps_path Nas_Prog
 * @param string $listen    all or local
 * @param string $ip        The NAS's address
 * @param string $name      The NAS's name
 *
 * @return string '' or an error message
 */
function bugsink_conf(string $apps_path, string $listen, string $ip, string $name): string
{
    $base_path = $apps_path.'/_bugsink';
    $data      = $base_path.'/data';
    $secret    = $base_path.'/secret_key';

    if (!is_file($secret)) {
        $key = substr(str_replace(['+', '/', '='], '', base64_encode(random_bytes(96))), 0, 64);

        if (!manage_write_file($secret, $key."\n")) {
            return 'Could not write '.$secret;
        }
    }

    $base   = bugsink_base_url($apps_path, $ip);
    $parts  = parse_url($base);
    $host   = isset($parts['host']) ? $parts['host'] : $ip;
    $https  = isset($parts['scheme']) && $parts['scheme'] === 'https';
    $hosts  = array_values(array_unique(array_filter([$host, $ip, $name, '127.0.0.1', 'localhost'], 'strlen')));
    $origin = $parts['scheme'].'://'.$host.(isset($parts['port']) ? ':'.$parts['port'] : '');
    $direct = $listen === 'all' || !$https;
    $trust  = array_values(array_unique(array_filter([
        $origin,
        $direct ? 'http://'.$ip.':'.BUGSINK_PORT : '',
        $direct && $name !== '' ? 'http://'.$name.':'.BUGSINK_PORT : '',
    ], 'strlen')));
    $secure = $https && !$direct;
    $lines  = [
        '# Bugsink\'s settings: written by the Bugsink app at every start (changes here are overwritten) - see its README',
        'from bugsink.settings.default import *  # noqa',
        '',
        'SECRET_KEY = '.bugsink_py(trim((string)file_get_contents($secret))),
        'DATABASES["default"]["NAME"] = '.bugsink_py($data.'/db.sqlite3'),
        'DATABASES["snappea"]["NAME"] = '.bugsink_py($data.'/snappea.sqlite3'),
        '',
        '# Behind the Nginx app (HTTPS), or reached directly on the network',
        'SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")',
        'USE_X_REAL_IP = True',
        'SESSION_COOKIE_SECURE = '.bugsink_py($secure),
        'CSRF_COOKIE_SECURE = '.bugsink_py($secure),
        'ALLOWED_HOSTS = '.bugsink_py($hosts),
        'CSRF_TRUSTED_ORIGINS = '.bugsink_py($trust),
        '',
        'SENTRY_DSN = None',
        'TIME_ZONE = "UTC"',
        '',
        '# Its background worker (a process of its own): two workers, for the NAS',
        'SNAPPEA = {',
        '    "TASK_ALWAYS_EAGER": False,',
        '    "NUM_WORKERS": 2,',
        '    "PID_FILE": None,',
        '    "WAKEUP_CALLS_DIR": '.bugsink_py($data.'/snappea/wakeup').',',
        '    "STATS_RETENTION_MINUTES": 60 * 24 * 7,',
        '}',
        '',
        '# The NAS sends no email: none is sent (users are invited by links instead)',
        'EMAIL_BACKEND = "bugsink.email_backends.QuietConsoleEmailBackend"',
        'SERVER_EMAIL = DEFAULT_FROM_EMAIL = "Bugsink <bugsink@nas.invalid>"',
        '',
        'BUGSINK = {',
        '    "BASE_URL": '.bugsink_py($base).',',
        '    "SITE_TITLE": "Bugsink",',
        '    "SINGLE_USER": False,',
        '    "USER_REGISTRATION": "CB_ADMINS",',
        '    "USER_REGISTRATION_VERIFY_EMAIL": False,',
        '    "SINGLE_TEAM": False,',
        '    "TEAM_CREATION": "CB_MEMBERS",',
        '    "INGEST_STORE_BASE_DIR": '.bugsink_py($data.'/ingestion').',',
        '    "MINIMIZE_INFORMATION_EXPOSURE": False,',
        '}',
    ];
    $file = $base_path.'/conf/bugsink_conf.py';

    if (!is_dir(dirname($file)) || !manage_write_file($file, implode("\n", $lines)."\n")) {
        return 'Could not write '.$file;
    }

    return '';
}

if (PHP_SAPI === 'cli' && isset($argv[0]) && realpath($argv[0]) === __FILE__) {
    if (!isset($argv[5]) || $argv[1] !== 'conf' || !is_dir($argv[2])) {
        fwrite(STDERR, "Usage: php bugsink.php conf <apps path> <all|local> <nas ip> <nas name>\n");

        exit(2);
    }

    $error = bugsink_conf($argv[2], $argv[3], $argv[4], $argv[5]);

    if ($error !== '') {
        fwrite(STDERR, $error."\n");

        exit(1);
    }
}
