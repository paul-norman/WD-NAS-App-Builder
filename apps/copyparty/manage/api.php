<?php
// CopyParty management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('copyparty');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path      = dirname(__DIR__);
$apps_path     = dirname($app_path);
$data_path     = $apps_path.'/_copyparty';
$settings_file = $data_path.'/settings.json';
$ctl           = $app_path.'/cpp_ctl.sh';

require $app_path.'/lib/cpp.php';

// Access levels, as cpp_conf.py turns them into copyparty's permissions ('*' is everyone, without logging in: read or upload only)
const CPP_LEVELS           = ['read', 'upload', 'write', 'full', 'admin'];
const CPP_ANONYMOUS_LEVELS = ['read', 'upload'];

/**
 * The settings (users with their passwords, shared folders, options), as cpp_conf.py writes and reads them - failing
 * the request if they can't be read.
 *
 * @param string $file settings.json
 *
 * @return array<string, mixed> The settings
 */
function cpp_settings(string $file): array
{
    $settings = json_decode((string)@file_get_contents($file), true);

    if (!is_array($settings) || !isset($settings['users'], $settings['folders'])) {
        manage_fail(500, 'copyparty\'s settings could not be read: '.$file);
    }

    return $settings + ['listen' => 'all', 'sftp' => false, 'tags' => false];
}

/**
 * Saves the settings, failing the request if they can't be saved.
 *
 * @param string               $file     settings.json
 * @param array<string, mixed> $settings The settings
 *
 * @return void
 */
function cpp_save(string $file, array $settings): void
{
    if (!manage_write_file($file, json_encode($settings, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES)."\n")) {
        manage_fail(500, 'The settings could not be saved');
    }
}

/**
 * Restarts copyparty with its control script (stop, then start), failing the request if it doesn't start.
 *
 * @param string $ctl The app's control script
 *
 * @return void
 */
function cpp_restart(string $ctl): void
{
    manage_run(['/bin/sh', $ctl, 'stop']);

    list($code, $output) = manage_run(['/bin/sh', $ctl, 'start']);

    if ($code !== 0) {
        manage_fail(500, 'copyparty could not be started: '.$output);
    }
}

/**
 * A generated password: 20 letters and digits.
 *
 * @return string The password
 */
function cpp_new_password(): string
{
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    $password = '';

    for ($i = 0; $i < 20; $i++) {
        $password .= $alphabet[random_int(0, strlen($alphabet) - 1)];
    }

    return $password;
}

/**
 * Where a user is in the settings.
 *
 * @param array<string, mixed> $settings The settings
 * @param mixed                $name     The user's name
 *
 * @return int Their index, or -1
 */
function cpp_user_index(array $settings, $name): int
{
    foreach ($settings['users'] as $i => $user) {
        if ($user['name'] === $name) {
            return $i;
        }
    }

    return -1;
}

/**
 * What copyparty's user can do in a folder.
 *
 * @param string $ctl  The app's control script
 * @param mixed  $path The folder
 *
 * @return 'write'|'read'|'none' Its access
 */
function cpp_folder_access(string $ctl, $path): string
{
    list($code) = manage_run(['/bin/sh', $ctl, 'check-folder', $path]);

    return $code === 0 ? 'write' : ($code === 1 ? 'read' : 'none');
}

/**
 * Checks a folder that may be shared: on the NAS's volumes (or a USB drive) - really, symbolic links followed - but not
 * the apps' folder (Nas_Prog: apps' data, passwords included) or the volumes' system folders.
 *
 * @param mixed $path The folder
 *
 * @return string '' or the error
 */
function cpp_check_path($path): string
{
    if (!preg_match('#^/mnt/(HD/HD_[a-z][0-9]+|USB/[^/]+)(/[^\x00-\x1f]*)?$#', $path) || preg_match('#/\.\.?(/|$)#', $path)) {
        return 'The folder must be on the NAS\'s volumes, e.g. /mnt/HD/HD_a2/Public/Photos';
    }

    if (!is_dir($path)) {
        return 'No such folder: '.$path;
    }

    // Where it really is, symbolic links followed
    $real = realpath($path);

    if ($real === false || !preg_match('#^/mnt/(HD/HD_[a-z][0-9]+|USB/[^/]+)(/|$)#', $real)) {
        return 'The folder must be on the NAS\'s volumes, e.g. /mnt/HD/HD_a2/Public/Photos';
    }

    if (preg_match('#^/mnt/HD/HD_[a-z][0-9]+/(Nas_Prog|lost\+found|otaclient|restsdk-data|restsdk-info|\.[^/]*)(/|$)#', $real)) {
        return 'That folder holds the NAS\'s or its apps\' own files, so it can\'t be shared';
    }

    return '';
}

$settings = cpp_settings($settings_file);
$action   = $_GET['action'] ?? 'status';

if ($action === 'status') {
    $running = manage_pid_running('/var/run/copyparty.pid');

    list($code) = $running ? manage_http_get(CPP_TARGET.'/?ls', 3) : [0];

    $answering = $code > 0;
    $version   = '';

    foreach (glob($app_path.'/binaries/python/lib/python3*/site-packages/copyparty-*.dist-info') ?: [] as $info) {
        $version = preg_replace('/^copyparty-(.*)\.dist-info$/', '$1', basename($info));
    }

    $site    = manage_nginx_site($apps_path, CPP_TARGET);
    $host    = isset($_SERVER['HTTP_HOST']) ? preg_replace('/:\d+$/', '', $_SERVER['HTTP_HOST']) : '';
    $folders = [];

    foreach ($settings['folders'] as $folder) {
        $folders[] = [
            'name'   => $folder['name'],
            'path'   => $folder['path'],
            'access' => (object)$folder['access'],
            'can'    => is_dir($folder['path']) ? cpp_folder_access($ctl, $folder['path']) : 'missing'
        ];
    }

    $log = array_values(array_filter(@file($data_path.'/copyparty.log', FILE_IGNORE_NEW_LINES) ?: [], function (string $line) {
        return trim($line) !== '';
    }));

    manage_json([
        'running'   => $running,
        'answering' => $answering,
        'version'   => $version,
        'site'      => $site,
        'local_url' => $host !== '' ? 'http://'.$host.':3923/' : '',
        'host'      => $host,
        'users'     => array_map(function (array $user) { return $user['name']; }, $settings['users']),
        'folders'   => $folders,
        'listen'    => $settings['listen'] === 'local' ? 'local' : 'all',
        'sftp'      => (bool)$settings['sftp'],
        'tags'      => (bool)$settings['tags'],
        'log'       => array_slice($log, -30),
    ]);
}

manage_require_action('copyparty');

$name = isset($_POST['name']) ? trim((string)$_POST['name']) : '';

if ($action === 'password') {
    $i = cpp_user_index($settings, $name);

    if ($i < 0) {
        manage_fail(404, 'No such user: '.$name);
    }

    manage_json(['password' => $settings['users'][$i]['password']]);
}

if ($action === 'new_password' || $action === 'add_user') {
    $i = cpp_user_index($settings, $name);

    if ($action === 'add_user') {
        if (!preg_match('/^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$/', $name)) {
            manage_fail(400, 'User names are up to 32 letters, digits, dots, dashes and underscores (starting with a letter or digit)');
        }

        if ($i >= 0) {
            manage_fail(400, 'There\'s already a user called '.$name);
        }

        $settings['users'][] = [
            'name'     => $name,
            'password' => '',
            'hash'     => '',
        ];

        $i = count($settings['users']) - 1;
    } elseif ($i < 0) {
        manage_fail(404, 'No such user: '.$name);
    }

    // Hashed by cpp_conf.py when copyparty starts
    $settings['users'][$i]['password'] = cpp_new_password();
    $settings['users'][$i]['hash']     = '';

    cpp_save($settings_file, $settings);
    cpp_restart($ctl);
    manage_json(['password' => $settings['users'][$i]['password']]);
}

if ($action === 'remove_user') {
    $i = cpp_user_index($settings, $name);

    if ($i < 0) {
        manage_fail(404, 'No such user: '.$name);
    }

    if (count($settings['users']) === 1) {
        manage_fail(400, 'copyparty needs at least one user');
    }

    array_splice($settings['users'], $i, 1);

    foreach ($settings['folders'] as &$folder) {
        unset($folder['access'][$name]);
    }

    unset($folder);

    cpp_save($settings_file, $settings);
    cpp_restart($ctl);
    manage_json();
}

if ($action === 'save_folder') {
    // The folder's address: /<name>/
    $old    = isset($_POST['old_name']) ? (string)$_POST['old_name'] : '';
    $path   = isset($_POST['path']) ? rtrim(trim((string)$_POST['path']), '/') : '';
    $access = json_decode(isset($_POST['access']) ? (string)$_POST['access'] : '', true);

    if (!preg_match('/^[a-z0-9][a-z0-9._-]{0,39}$/', $name)) {
        manage_fail(400, 'Folder names (their address) are up to 40 lower case letters, digits, dots, dashes and underscores');
    }

    $error = cpp_check_path($path);

    if ($error !== '') {
        manage_fail(400, $error);
    }

    if (!is_array($access)) {
        manage_fail(400, 'Who may use the folder is missing');
    }

    $users = array_map(function (array $user) { return $user['name']; }, $settings['users']);
    $clean = [];

    foreach ($access as $who => $level) {
        if ($level === 'none') {
            continue;
        }

        $known = $who === '*' ? in_array($level, CPP_ANONYMOUS_LEVELS, true) : in_array($who, $users, true) && in_array($level, CPP_LEVELS, true);

        if (!$known) {
            manage_fail(400, 'Unknown access for '.($who === '*' ? 'everyone' : $who).': '.$level);
        }

        $clean[$who] = $level;
    }

    $index = -1;

    foreach ($settings['folders'] as $i => $folder) {
        if ($folder['name'] === $old) {
            $index = $i;
        } elseif ($folder['name'] === $name) {
            manage_fail(400, 'Another folder is already called '.$name);
        }
    }

    $entry = [
        'name'   => $name,
        'path'   => $path,
        'access' => (object)$clean
    ];

    if ($index >= 0) {
        $settings['folders'][$index] = $entry;
    } else {
        $settings['folders'][] = $entry;
    }

    cpp_save($settings_file, $settings);
    cpp_restart($ctl);
    manage_json(['can' => cpp_folder_access($ctl, $path)]);
}

if ($action === 'remove_folder') {
    $settings['folders'] = array_values(array_filter($settings['folders'], function (array $folder) use ($name): bool {
        return $folder['name'] !== $name;
    }));

    cpp_save($settings_file, $settings);
    cpp_restart($ctl);
    manage_json();
}

if ($action === 'settings') {
    $settings['listen'] = isset($_POST['listen']) && $_POST['listen'] === 'local' ? 'local' : 'all';
    $settings['sftp']   = !empty($_POST['sftp']);
    $settings['tags']   = !empty($_POST['tags']);

    cpp_save($settings_file, $settings);
    cpp_restart($ctl);
    manage_json();
}

if ($action === 'restart') {
    cpp_restart($ctl);
    manage_json();
}

manage_fail(400, 'Unknown action');
