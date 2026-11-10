<?php
// Vikunja management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('vikunja');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path      = dirname(__DIR__);
$apps_path     = dirname($app_path);
$data_path     = $apps_path.'/_vikunja';
$settings_file = $data_path.'/settings';
$ctl           = $app_path.'/vikunja_ctl.sh';

require $app_path.'/lib/vikunja.php';

/**
 * The app's settings, with defaults.
 *
 * @param string $file The settings file (KEY=value lines, also read by the app's control script)
 *
 * @return array{ LISTEN: string, SIGNUPS: string, BACKUP_KEEP: string } The settings
 */
function vikunja_settings(string $file): array
{
    $settings = [
        'LISTEN'      => 'local',
        'SIGNUPS'     => '0',
        'BACKUP_KEEP' => '14',
    ];

    foreach (@file($file, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
        if (preg_match('/^([A-Z_]+)=(.*)$/', $line, $m) && isset($settings[$m[1]])) {
            $settings[$m[1]] = $m[2];
        }
    }

    return $settings;
}

/**
 * Restarts Vikunja with its control script (stop, then start), failing the request if it doesn't start.
 *
 * @param string $ctl The app's control script
 *
 * @return void
 */
function vikunja_restart(string $ctl): void
{
    manage_run(['/bin/sh', $ctl, 'stop']);

    list($code, $output) = manage_run(['/bin/sh', $ctl, 'start']);

    if ($code !== 0) {
        manage_fail(500, 'Vikunja could not be started: '.$output);
    }
}

/**
 * Vikunja's users, from its database (through the app's control script).
 *
 * @param string $ctl The app's control script
 *
 * @return list<array{ id: int, name: string, email: string }> The users
 */
function vikunja_users(string $ctl): array
{
    list($code, $output) = manage_run(['/bin/sh', $ctl, 'users']);

    $users = [];

    foreach ($code === 0 ? explode("\n", trim($output)) : [] as $line) {
        $fields = explode("\t", $line);

        if (count($fields) === 3 && ctype_digit($fields[0])) {
            $users[] = ['id' => (int)$fields[0], 'name' => $fields[1], 'email' => $fields[2]];
        }
    }

    return $users;
}

/**
 * The backups in Nas_Prog/_vikunja/backups, newest first.
 *
 * @param string $data_path The app's data folder
 *
 * @return list<array{ name: string, size: int, time: int }> Each backup's file name, size (bytes) and time (seconds
 *                                                           since 1970)
 */
function vikunja_backups(string $data_path): array
{
    $list = [];

    foreach (glob($data_path.'/backups/vikunja-*.tar.gz') ?: [] as $file) {
        $list[] = ['name' => basename($file), 'size' => (int)filesize($file), 'time' => (int)filemtime($file)];
    }

    usort($list, function (array $a, array $b): int {
        return strcmp($b['name'], $a['name']);
    });

    return $list;
}

/**
 * A user name from the request, if it's one of Vikunja's users.
 *
 * @param string $ctl The app's control script
 *
 * @return string The user name (the request fails if it isn't a user's)
 */
function vikunja_requested_user(string $ctl): string
{
    $name = isset($_POST['user']) ? (string)$_POST['user'] : '';

    foreach (vikunja_users($ctl) as $user) {
        if ($user['name'] === $name) {
            return $name;
        }
    }

    manage_fail(404, 'No such user');
}

$settings = vikunja_settings($settings_file);
$action   = $_GET['action'] ?? 'status';

if ($action === 'status') {
    $running = manage_pid_running('/var/run/vikunja.pid');

    list($code, $body) = $running ? manage_http_get(VIKUNJA_TARGET.'/api/v1/info') : [0, ''];

    // Its version and the address it runs with (set when it started - its links and emails use it)
    $info    = $code === 200 ? json_decode($body, true) : null;
    $address = is_array($info) ? (string)($info['frontend_url'] ?? '') : '';
    $site    = manage_nginx_site($apps_path, VIKUNJA_TARGET);
    $log     = @file($data_path.'/vikunja.log', FILE_IGNORE_NEW_LINES) ?: [];

    manage_json([
        'running'        => $running,
        'answering'      => is_array($info),
        'version'        => is_array($info) ? ltrim((string)($info['version'] ?? ''), 'v') : '',
        'address'        => $address,
        'site'           => $site,
        // The Nginx app's address changed since Vikunja started (it uses it for its links)
        'restart_needed' => $address !== '' && $site['url'] !== '' && rtrim($site['url'], '/') !== rtrim($address, '/'),
        'listen'         => $settings['LISTEN'] === 'all' ? 'all' : 'local',
        'signups'        => $settings['SIGNUPS'] === '1',
        'backup_keep'    => (int)$settings['BACKUP_KEEP'],
        'backups'        => array_slice(vikunja_backups($data_path), 0, 5),
        'users'          => vikunja_users($ctl),
        'log'            => array_slice($log, -20),
    ]);
}

manage_require_action('vikunja');

if ($action === 'password') {
    manage_json(['password' => trim((string)@file_get_contents($data_path.'/admin_password'))]);
}

if ($action === 'new_password') {
    $user = vikunja_requested_user($ctl);

    list($code, $output) = manage_run(['/bin/sh', $ctl, 'new-password', $user]);

    if ($code !== 0) {
        manage_fail(500, 'A new password could not be set: '.$output);
    }

    $password = $user === 'admin' ? trim((string)@file_get_contents($data_path.'/admin_password')) : trim($output);

    manage_json(['user' => $user, 'password' => $password]);
}

if ($action === 'add_user') {
    $name  = isset($_POST['name']) ? trim((string)$_POST['name']) : '';
    $email = isset($_POST['email']) ? trim((string)$_POST['email']) : '';

    if (!preg_match('/^[A-Za-z0-9._-]{1,60}$/', $name)) {
        manage_fail(400, 'User names are letters, digits, . _ and - (up to 60)');
    }

    if (filter_var($email, FILTER_VALIDATE_EMAIL) === false) {
        manage_fail(400, 'Give their email address (Vikunja needs one: it\'s not sent anything)');
    }

    list($code, $output) = manage_run(['/bin/sh', $ctl, 'add-user', $name, $email]);

    if ($code !== 0) {
        manage_fail(400, 'The user could not be added: '.$output);
    }

    manage_json(['user' => $name, 'password' => trim($output)]);
}

if ($action === 'settings') {
    $keep = isset($_POST['backup_keep']) ? (string)$_POST['backup_keep'] : '';

    if (!preg_match('/^[0-9]{1,2}$/', $keep) || (int)$keep < 1) {
        manage_fail(400, 'Keep 1 to 99 backups');
    }

    $text = 'LISTEN='.(isset($_POST['listen']) && $_POST['listen'] === 'all' ? 'all' : 'local')."\n"
        .'SIGNUPS='.(empty($_POST['signups']) ? 0 : 1)."\n"
        .'BACKUP_KEEP='.(int)$keep."\n";

    if (!manage_write_file($settings_file, $text)) {
        manage_fail(500, 'The settings could not be saved');
    }

    vikunja_restart($ctl);
    manage_json();
}

if ($action === 'backup') {
    list($code, $output) = manage_run(['/bin/sh', $ctl, 'backup']);

    if ($code !== 0) {
        manage_fail(500, 'The backup failed: '.$output);
    }

    manage_json(['backups' => array_slice(vikunja_backups($data_path), 0, 5)]);
}

if ($action === 'restart') {
    vikunja_restart($ctl);
    manage_json();
}

manage_fail(400, 'Unknown action');
