<?php
// ValKey management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('valkey');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path  = dirname(__DIR__);
$conf_file = dirname($app_path).'/_valkey/valkey.conf';
// The password as it is (root's only): what the other apps read - the config file has it quoted
$pass_file = dirname($app_path).'/_valkey/password';
$cli       = $app_path.'/binaries/valkey-cli';

/**
 * ValKey's password: from the password file, else (an install from before it) the configuration file's requirepass -
 * then always letters and digits, unquoted.
 *
 * @param string $conf_file The configuration file
 * @param string $pass_file The password file
 *
 * @return string The password, or ''
 */
function valkey_conf_password(string $conf_file, string $pass_file): string
{
    if (is_file($pass_file)) {
        return rtrim((string)@file_get_contents($pass_file), "\n");
    }

    return preg_match('/^requirepass[ \t]+(\S+)[ \t]*$/m', (string)@file_get_contents($conf_file), $m) ? trim($m[1], '"') : '';
}

/**
 * A value quoted as ValKey reads its configuration and valkey-cli its input: in double quotes, with its backslashes and
 * quotes escaped (a password may have any visible characters, spaces included).
 *
 * @param string $text The value
 *
 * @return string The quoted value
 */
function valkey_quote(string $text): string
{
    return '"'.str_replace(['\\', '"'], ['\\\\', '\\"'], $text).'"';
}

/**
 * Whether ValKey is running.
 *
 * @return bool Whether it is
 */
function valkey_running(): bool
{
    $pid = trim((string)@file_get_contents('/var/run/valkey.pid'));

    return ctype_digit($pid) && is_dir("/proc/{$pid}");
}

$action = $_GET['action'] ?? 'status';

if ($action === 'status') {
    list(, $version) = manage_run([$app_path.'/binaries/valkey-server', '--version']);

    $conf = (string)@file_get_contents($conf_file);

    manage_json([
        'running'      => valkey_running(),
        'version'      => preg_match('/v=(\S+)/', $version, $m) ? $m[1] : '',
        'port'         => preg_match('/^port[ \t]+(\d+)/m', $conf, $m) ? (int)$m[1] : 6379,
        'bind'         => preg_match('/^bind[ \t]+(.+)$/m', $conf, $m) ? trim($m[1]) : '',
        'has_password' => valkey_conf_password($conf_file, $pass_file) !== '',
    ]);
}

manage_require_action('valkey');

if ($action === 'password') {
    manage_json(['password' => valkey_conf_password($conf_file, $pass_file)]);
}

if ($action === 'set_password') {
    // A new password: the one given (any visible characters - quoted for the config file and valkey-cli), or a random
    // one
    $new = manage_new_password(isset($_POST['password']) ? (string)$_POST['password'] : '', 12, 128);

    $old = valkey_conf_password($conf_file, $pass_file);

    // Apply it to the running server first (the password goes in via stdin, not the command line)
    if (valkey_running()) {
        list($code, $output) = manage_run([$cli], ['REDISCLI_AUTH' => $old], 'CONFIG SET requirepass '.valkey_quote($new)."\n");

        if ($code !== 0 || $output !== 'OK') {
            manage_fail(500, 'ValKey refused the new password: '.$output);
        }
    }

    // Then save it to the config file (the real file in the persistent path, not the /etc symlink to it)
    $conf    = (string)@file_get_contents($conf_file);
    $line    = 'requirepass '.valkey_quote($new);
    $updated = preg_match('/^requirepass[ \t]/m', $conf)
        ? preg_replace_callback('/^requirepass[ \t].*$/m', function () use ($line): string {
            return $line;
        }, $conf)
        : rtrim($conf, "\n")."\n".$line."\n";

    if (!manage_write_file($conf_file, $updated) || !manage_write_file($pass_file, $new."\n")) {
        if (valkey_running()) {
            manage_run([$cli], ['REDISCLI_AUTH' => $new], 'CONFIG SET requirepass '.valkey_quote($old)."\n");
        }

        manage_fail(500, 'The config file could not be saved, so the password was not changed');
    }

    // The apps that log in to ValKey read its password when they start: those installed start again with the new one
    // (kvweb and Paperless-ngx restarted, the Redis exporter logging in again)
    $followers = [
        'kvweb/kvweb_ctl.sh'             => 'restart',
        'paperless-ngx/pl_ctl.sh'        => 'restart',
        'redis_exporter/exporter_ctl.sh' => 'login',
    ];

    foreach ($followers as $script => $command) {
        if (is_file(dirname($app_path).'/'.$script)) {
            manage_run(['/bin/sh', dirname($app_path).'/'.$script, $command]);
        }
    }

    manage_json(['password' => $new, 'applied' => valkey_running()]);
}

manage_fail(400, 'Unknown action');
