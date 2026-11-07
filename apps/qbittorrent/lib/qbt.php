<?php
require_once dirname(__DIR__).'/manage/manage_helpers.php';

// qBittorrent's settings and its Web API. Used by the management page, and by qbt_ctl.sh through the NAS's PHP CLI
// (WD's PHP 7.4, or the PHP app's 8.5), so it must work on both:
//     php qbt.php config <qBittorrent.conf> <settings file> <password file> <download dir> <log dir>
//         - writes the app's settings into qBittorrent's own (while it's stopped: it writes the file again when it stops)
const QBT_PORT = 8092;

/**
 * The app's settings (KEY=value lines, written by its management page and also read by its control script), with
 * defaults.
 *
 * @param string $file The settings file
 *
 * @return array{ DOWNLOAD_DIR: string, LISTEN: string, PEER_PORT: string, DOWN_LIMIT: string, UP_LIMIT: string }
 */
function qbt_settings(string $file): array
{
    $settings = [
        'DOWNLOAD_DIR' => '',
        'LISTEN'       => 'all',
        'PEER_PORT'    => '6882',
        'DOWN_LIMIT'   => '0',
        'UP_LIMIT'     => '0',
    ];

    foreach (@file($file, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
        if (preg_match('/^([A-Z_]+)=(.*)$/', $line, $m) && isset($settings[$m[1]])) {
            $settings[$m[1]] = $m[2];
        }
    }

    return $settings;
}

/**
 * A password as qBittorrent keeps it: PBKDF2 with SHA-512 (100,000 rounds, a 16-byte salt, 64 bytes), as Qt writes a
 * byte array.
 *
 * @param string $password The password
 *
 * @return string Its WebUI\Password_PBKDF2 value
 */
function qbt_password_hash(string $password): string
{
    $salt = random_bytes(16);
    $hash = hash_pbkdf2('sha512', $password, $salt, 100000, 64, true);

    return '"@ByteArray('.base64_encode($salt).':'.base64_encode($hash).')"';
}

/**
 * A value as Qt's INI files write it: quoted (with \ and " escaped) if it has anything Qt would read differently - a
 * comma would make it a list.
 *
 * @param string $value The value
 *
 * @return string It, ready for the file
 */
function qbt_ini_value(string $value): string
{
    if ($value === '' || preg_match('/^[A-Za-z0-9_.:\/@+-]+$/', $value)) {
        return $value;
    }

    return '"'.str_replace(['\\', '"'], ['\\\\', '\\"'], $value).'"';
}

/**
 * Sets keys in a Qt INI file's text (adding the sections and keys missing), keeping everything else.
 *
 * @param string                               $text   The file's text
 * @param array<string, array<string, string>> $values Each section's keys and their values (written as they are)
 *
 * @return string The new text
 */
function qbt_ini_set(string $text, array $values): string
{
    $lines   = $text === '' ? [] : preg_split('/\r?\n/', rtrim($text, "\r\n"));
    $section = '';
    $out     = [];
    $done    = [];

    // Each key's line replaced where it is; a section's missing keys added at its end
    $flush = function (string $section) use (&$out, &$done, $values): void {
        foreach ($values[$section] ?? [] as $key => $value) {
            if (!isset($done[$section][$key])) {
                $out[]                = $key.'='.$value;
                $done[$section][$key] = true;
            }
        }
    };

    foreach ($lines ?: [] as $line) {
        if (preg_match('/^\[(.+)\]\s*$/', $line, $m)) {
            $flush($section);

            // (a blank line between sections, as Qt writes them)
            if ($out && end($out) !== '') {
                $out[] = '';
            }

            $section = $m[1];
            $out[]   = $line;

            continue;
        }

        if ($line === '') {
            continue;
        }

        $key = strstr($line, '=', true);

        if ($key !== false && isset($values[$section][$key])) {
            if (!isset($done[$section][$key])) {
                $out[]                = $key.'='.$values[$section][$key];
                $done[$section][$key] = true;
            }

            continue;
        }

        $out[] = $line;
    }

    $flush($section);

    foreach ($values as $name => $keys) {
        if (!isset($done[$name]) && $keys) {
            if ($out) {
                $out[] = '';
            }

            $out[] = '['.$name.']';
            $flush($name);
        }
    }

    return implode("\n", $out)."\n";
}

/**
 * Writes the app's settings into qBittorrent's own qBittorrent.conf, keeping everything else in it - e.g. what was
 * changed in its web interface. Its login is user admin with the app's password (hashed afresh only when it's changed).
 *
 * @param string $conf          qBittorrent.conf
 * @param string $settings_file The app's settings
 * @param string $password_file The app's password
 * @param string $download_dir  The downloads folder (the settings', or the default)
 * @param string $log_dir       Where qBittorrent keeps its log
 *
 * @return bool Whether it was written
 */
function qbt_write_config(string $conf, string $settings_file, string $password_file, string $download_dir, string $log_dir): bool
{
    $settings = qbt_settings($settings_file);
    $password = trim((string)@file_get_contents($password_file));
    $text     = is_file($conf) ? (string)file_get_contents($conf) : '';

    if ($password === '') {
        return false;
    }

    // The password's hash, kept while it's still the app's password (a fresh salt every start would be pointless)
    $hash = '';

    if (preg_match('/^Password_PBKDF2=("@ByteArray\(([^:]+):([^)]+)\)")$/m', $text, $m)) {
        $salt = (string)base64_decode($m[2], true);

        if (hash_equals((string)base64_decode($m[3], true), hash_pbkdf2('sha512', $password, $salt, 100000, 64, true))) {
            $hash = $m[1];
        }
    }

    $down = (int)$settings['DOWN_LIMIT'];
    $up   = (int)$settings['UP_LIMIT'];

    $text = qbt_ini_set($text, [
        'LegalNotice' => ['Accepted' => 'true'],
        'Application' => [
            'FileLogger\\Enabled'      => 'true',
            'FileLogger\\Path'         => qbt_ini_value($log_dir),
            'FileLogger\\Backup'       => 'true',
            'FileLogger\\DeleteOld'    => 'true',
            'FileLogger\\MaxSizeBytes' => '1048576',
            'FileLogger\\Age'          => '1',
            'FileLogger\\AgeType'      => '1',
        ],
        'BitTorrent' => [
            'Session\\DefaultSavePath'    => qbt_ini_value($download_dir),
            'Session\\TempPathEnabled'    => 'false',
            'Session\\Port'               => (string)(int)$settings['PEER_PORT'],
            'Session\\GlobalDLSpeedLimit' => (string)max(0, $down),
            'Session\\GlobalUPSpeedLimit' => (string)max(0, $up),
        ],
        // (its own section since qBittorrent 5 - it moves [Preferences]' WebUI\ keys there)
        'WebUI' => [
            'Enabled'                    => 'true',
            'Address'                    => $settings['LISTEN'] === 'local' ? '127.0.0.1' : '*',
            'Port'                       => (string)QBT_PORT,
            'Username'                   => 'admin',
            'Password_PBKDF2'            => $hash !== '' ? $hash : qbt_password_hash($password),
            'LocalHostAuth'              => 'true',
            // Reached by the NAS's name, its address and the Nginx app's site: the login protects it, not the name used
            'HostHeaderValidation'       => 'false',
            // Behind the Nginx app: its visitors' own addresses (for failed logins' bans), not Nginx's
            'ReverseProxySupportEnabled' => 'true',
            'TrustedReverseProxiesList'  => '127.0.0.1',
            'UseUPnP'                    => 'false',
        ],
    ]);

    $temp = $conf.'.tmp';

    if (@file_put_contents($temp, $text) === false) {
        return false;
    }

    chmod($temp, 0600);

    return rename($temp, $conf);
}

/**
 * Calls qBittorrent's Web API on 127.0.0.1 with the app's login. The session is kept in a root-only file and reused,
 * so the page doesn't log in at every refresh; a new one is made when it has expired.
 *
 * @param string                     $data_path The app's data folder
 * @param string                     $path      The API's path (e.g. app/version)
 * @param array<string, string>|null $form      A form to post, or null for a GET
 *
 * @return array{ 0: int, 1: string } [HTTP status, body], or [0, ''] if it didn't answer
 */
function qbt_api(string $data_path, string $path, ?array $form = null): array
{
    $base     = 'http://127.0.0.1:'.QBT_PORT;
    $sid_file = $data_path.'/page_session';
    // (its CSRF protection: requests must say they come from itself)
    $headers  = ['Referer: '.$base.'/', 'Origin: '.$base];

    for ($try = 0; $try < 2; $try++) {
        $sid = trim((string)@file_get_contents($sid_file));

        if ($sid === '' || $try === 1) {
            $sid = qbt_login_sid($data_path, trim((string)@file_get_contents($data_path.'/password')));

            if ($sid === '') {
                return [0, ''];
            }
        }

        $method = $form === null ? 'GET' : 'POST';
        $body   = $form === null ? null : http_build_query($form);
        $result = manage_http_request($method, $base.'/api/v2/'.$path, $body, 5, array_merge($headers, ['Cookie: '.$sid]),
            'application/x-www-form-urlencoded');

        if ($result[0] !== 403) {
            return $result;
        }
    }

    return [403, ''];
}

/**
 * Logs in to qBittorrent's Web API and keeps its session ID (root's only).
 *
 * @param string $data_path The app's data folder
 * @param string $password  The app's password
 *
 * @return string The session's cookie (name=value), or '' if the login was refused
 */
function qbt_login_sid(string $data_path, string $password): string
{
    $base = 'http://127.0.0.1:'.QBT_PORT;

    // curl prints the response's headers (-i): the session is in its Set-Cookie
    list($code, $output) = manage_run(['curl', '-s', '-i', '-m', '5', '-H', 'Referer: '.$base.'/', '--data-urlencode', 'username=admin',
        '--data-urlencode', 'password@-', $base.'/api/v2/auth/login'], [], $password);

    // (its name: SID, or QBT_SID_<port> since qBittorrent 5)
    if ($code !== 0 || !preg_match('/^Set-Cookie:\s*((?:QBT_)?SID(?:_\d+)?=[^;\s]+)/mi', $output, $m)) {
        return '';
    }

    manage_write_file($data_path.'/page_session', $m[1]);

    return $m[1];
}

if (PHP_SAPI === 'cli' && isset($argv[0]) && realpath($argv[0]) === __FILE__) {
    if (($argv[1] ?? '') !== 'config' || !isset($argv[6])) {
        fwrite(STDERR, "Usage: php qbt.php config <qBittorrent.conf> <settings file> <password file> <download dir> <log dir>\n");

        exit(2);
    }

    exit(qbt_write_config($argv[2], $argv[3], $argv[4], $argv[5], $argv[6]) ? 0 : 1);
}
