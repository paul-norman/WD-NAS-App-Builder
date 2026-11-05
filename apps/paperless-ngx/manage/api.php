<?php
// Paperless-ngx management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('paperless-ngx');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path      = dirname(__DIR__);
$apps_path     = dirname($app_path);
$data_path     = $apps_path.'/_paperless-ngx';
$settings_file = $data_path.'/settings';
$ctl           = $app_path.'/pl_ctl.sh';

require $app_path.'/lib/paperless.php';

const PAPERLESS_LANGUAGES = ['eng', 'deu', 'eng+deu'];

/**
 * The app's settings, with defaults.
 *
 * @param string $file The settings file (KEY=value lines, also read by the app's control script)
 *
 * @return array{ CONSUME_DIR: string, OCR_LANGUAGE: string, LISTEN: string } The settings
 */
function pl_settings(string $file): array
{
    $settings = [
        'CONSUME_DIR'  => '',
        'OCR_LANGUAGE' => 'eng',
        'LISTEN'       => 'all',
    ];

    foreach (@file($file, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
        if (preg_match('/^([A-Z_]+)=(.*)$/', $line, $m) && isset($settings[$m[1]])) {
            $settings[$m[1]] = $m[2];
        }
    }

    return $settings;
}

/**
 * Whether a folder can be the consume folder: one on the NAS's volumes, in a share - not the apps' folder (Nas_Prog:
 * apps' data, passwords included) or the volumes' system folders.
 *
 * @param mixed $path The folder
 *
 * @return string '' or the error
 */
function pl_check_path($path): string
{
    if (!is_string($path) || !preg_match('#^/mnt/(HD/HD_[a-z][0-9]+|USB/[^/]+)(/[^\x00-\x1f]*)?$#', $path) || preg_match('#/\.\.?(/|$)#', $path)) {
        return 'The folder must be on the NAS\'s volumes, e.g. /mnt/HD/HD_a2/Public/Paperless';
    }

    if (!is_dir($path)) {
        return 'No such folder: '.$path;
    }

    // Where it really is, symbolic links followed
    $real = realpath($path);

    if ($real === false || !preg_match('#^/mnt/(HD/HD_[a-z][0-9]+|USB/[^/]+)/#', $real)) {
        return 'The folder must be inside one of the NAS\'s shares, e.g. /mnt/HD/HD_a2/Public/Paperless';
    }

    if (preg_match('#^/mnt/HD/HD_[a-z][0-9]+/(Nas_Prog|lost\+found|otaclient|restsdk-data|restsdk-info|\.[^/]*)(/|$)#', $real)) {
        return 'That folder holds the NAS\'s or its apps\' own files';
    }

    return '';
}

/**
 * Restarts Paperless with its control script, failing the request if it doesn't start.
 *
 * @param string $ctl The app's control script
 *
 * @return void
 */
function pl_restart(string $ctl): void
{
    list($code, $output) = manage_run(['/bin/sh', $ctl, 'restart']);

    if ($code !== 0) {
        manage_fail(500, 'Paperless could not be started: '.$output);
    }
}

$settings = pl_settings($settings_file);
$action   = $_GET['action'] ?? 'status';

if ($action === 'status') {
    $services = [];

    foreach (['web', 'consumer', 'worker', 'scheduler'] as $service) {
        $services[$service] = manage_pid_running('/var/run/paperless-ngx/'.$service.'.pid');
    }

    // Its login page answers once its web server is up
    list($code) = $services['web'] ? manage_http_get(PAPERLESS_TARGET.'/accounts/login/', 5) : [0, ''];

    $address = preg_match('/ src (\S+)/', manage_run(['ip', '-4', 'route', 'get', '1.1.1.1'])[1], $m) ? $m[1] : '';
    $log     = @file($data_path.'/paperless.log', FILE_IGNORE_NEW_LINES) ?: [];

    manage_json([
        'state'        => trim((string)@file_get_contents($data_path.'/state')),
        'launching'    => manage_pid_running('/var/run/paperless-ngx/launcher.pid'),
        'services'     => $services,
        'answering'    => $code === 200,
        'version'      => preg_match('/^Version:\s*(\S+)/m', (string)@file_get_contents($app_path.'/apkg.rc'), $v) ? preg_replace('/-\d+$/', '', $v[1]) : '',
        'valkey'       => is_file($apps_path.'/_valkey/valkey.conf'),
        'address'      => $address !== '' ? 'http://'.$address.':8040/' : '',
        'site'         => manage_nginx_site($apps_path, PAPERLESS_TARGET),
        'consume_dir'  => $settings['CONSUME_DIR'],
        'ocr_language' => $settings['OCR_LANGUAGE'],
        'listen'       => $settings['LISTEN'] === 'local' ? 'local' : 'all',
        'log'          => array_slice($log, -25),
    ]);
}

manage_require_action('paperless-ngx');

if ($action === 'password') {
    manage_json(['password' => trim((string)@file_get_contents($data_path.'/admin_password'))]);
}

if ($action === 'new_password') {
    list($code, $output) = manage_run(['/bin/sh', $ctl, 'new-password']);

    if ($code !== 0) {
        manage_fail(500, 'A new password could not be set: '.$output);
    }

    manage_json(['password' => trim((string)@file_get_contents($data_path.'/admin_password'))]);
}

if ($action === 'settings') {
    $folder = isset($_POST['consume_dir']) ? rtrim(trim((string)$_POST['consume_dir']), '/') : '';
    $error  = pl_check_path($folder);

    if ($error !== '') {
        manage_fail(400, $error);
    }

    $language = isset($_POST['ocr_language']) ? (string)$_POST['ocr_language'] : '';

    if (!in_array($language, PAPERLESS_LANGUAGES, true)) {
        manage_fail(400, 'Unknown OCR language');
    }

    $text = 'CONSUME_DIR='.$folder."\n"
        .'OCR_LANGUAGE='.$language."\n"
        .'LISTEN='.(isset($_POST['listen']) && $_POST['listen'] === 'local' ? 'local' : 'all')."\n";

    if (!manage_write_file($settings_file, $text)) {
        manage_fail(500, 'The settings could not be saved');
    }

    pl_restart($ctl);
    manage_json();
}

if ($action === 'restart') {
    pl_restart($ctl);
    manage_json();
}

manage_fail(400, 'Unknown action');
