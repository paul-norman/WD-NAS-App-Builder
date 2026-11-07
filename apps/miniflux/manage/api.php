<?php
// Miniflux management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('miniflux');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path      = dirname(__DIR__);
$apps_path     = dirname($app_path);
$data_path     = $apps_path.'/_miniflux';
$settings_file = $data_path.'/settings';
$password_file = $data_path.'/password';
$ctl           = $app_path.'/miniflux_ctl.sh';
$target        = 'http://127.0.0.1:8099';

/**
 * The app's settings, with defaults.
 *
 * @param string $file The settings file (KEY=value lines, also read by the app's control script)
 *
 * @return array{ LISTEN: string, BACKUP_DIR: string, BACKUP_KEEP: string, PRIVATE_FEEDS: string } The settings
 */
function miniflux_settings(string $file): array
{
    $settings = [
        'LISTEN'        => 'local',
        'BACKUP_DIR'    => '',
        'BACKUP_KEEP'   => '7',
        // Feeds on the local network (e.g. other apps'): off - feeds can't reach into it
        'PRIVATE_FEEDS' => 'off',
    ];

    foreach (@file($file, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
        if (preg_match('/^([A-Z_]+)=(.*)$/', $line, $m) && isset($settings[$m[1]])) {
            $settings[$m[1]] = $m[2];
        }
    }

    return $settings;
}

/**
 * Saves the settings (KEY=value lines).
 *
 * @param string                $file     The settings file (KEY=value lines, also read by the app's control script)
 * @param array<string, string> $settings The settings
 *
 * @return bool Whether they were saved
 */
function miniflux_save_settings(string $file, array $settings): bool
{
    $text = '';

    foreach ($settings as $key => $value) {
        $text .= $key.'='.$value."\n";
    }

    return manage_write_file($file, $text);
}

/**
 * Restarts Miniflux with its control script (stop, then start), failing the request if it doesn't start.
 *
 * @param string $ctl The app's control script
 *
 * @return void
 */
function miniflux_restart(string $ctl): void
{
    manage_run(['/bin/sh', $ctl, 'stop']);

    list($code, $output) = manage_run(['/bin/sh', $ctl, 'start']);

    if ($code !== 0) {
        manage_fail(500, 'Miniflux could not be started: '.$output);
    }
}

$settings   = miniflux_settings($settings_file);
$backup_dir = $settings['BACKUP_DIR'] !== '' ? $settings['BACKUP_DIR'] : $data_path.'/backups';
$action     = isset($_GET['action']) ? $_GET['action'] : 'status';

if ($action === 'status') {
    $running = manage_pid_running('/var/run/miniflux.pid');

    // Its health check (OK once it's serving), and its version
    list($code, $health) = $running ? manage_http_get($target.'/healthcheck', 5) : [0, ''];
    // (its own /version page needs a login: the program says it)
    $version             = manage_run([$app_path.'/binaries/miniflux', '-version'])[1];

    $log     = @file($data_path.'/miniflux.log', FILE_IGNORE_NEW_LINES) ?: [];
    // How setting up its database last went: ok|failed <time> <message>
    $db      = explode(' ', trim((string)@file_get_contents($data_path.'/db.status')), 3);
    $backups = [];

    foreach (glob($backup_dir.'/miniflux-*.dump') ?: [] as $file) {
        $backups[] = [
            'name' => basename($file),
            'time' => (int)filemtime($file),
            'size' => (int)filesize($file),
        ];
    }

    usort($backups, function (array $a, array $b): int {
        return $b['time'] - $a['time'];
    });

    manage_json([
        'running'            => $running,
        'answering'          => $code === 200 && trim($health) === 'OK',
        'version'            => preg_match('/^\d+(\.\d+)+$/', trim($version)) ? trim($version) : '',
        'postgresql'         => is_dir($apps_path.'/postgresql'),
        'db'                 => ['state' => $db[0], 'message' => isset($db[2]) ? $db[2] : ''],
        'listen'             => $settings['LISTEN'] === 'all' ? 'all' : 'local',
        'private_feeds'      => $settings['PRIVATE_FEEDS'] === 'on',
        'site'               => manage_nginx_site($apps_path, $target),
        'backup_dir'         => $settings['BACKUP_DIR'],
        'backup_dir_default' => $data_path.'/backups',
        'backup_keep'        => (int)$settings['BACKUP_KEEP'],
        'backups'            => array_slice($backups, 0, 30),
        // Its warnings and errors
        'log'                => array_values(array_slice(preg_grep('/level=(WARN|ERROR)/', $log), -20)),
    ]);
}

manage_require_action('miniflux');

if ($action === 'password') {
    manage_json(['password' => trim((string)@file_get_contents($password_file))]);
}

if ($action === 'set_password') {
    // A new password: the one given (letters, digits and . _ ~ - only, like the other apps), or a random one - in use
    // at once
    $new = isset($_POST['password']) ? trim((string)$_POST['password']) : '';

    if ($new === '') {
        $new = substr(str_replace(['+', '/', '='], '', base64_encode(random_bytes(48))), 0, 20);
    } elseif (!preg_match('/^[A-Za-z0-9._~-]{12,72}$/', $new)) {
        manage_fail(400, 'Passwords must be 12-72 characters: letters, digits and . _ ~ -');
    }

    list($code, $output) = manage_run(['/bin/sh', $ctl, 'set-password'], [], $new."\n");

    if ($code !== 0) {
        manage_fail(500, 'The password could not be saved: '.$output);
    }

    manage_json(['password' => $new]);
}

if ($action === 'listen') {
    $settings['LISTEN']        = isset($_POST['listen']) && $_POST['listen'] === 'all' ? 'all' : 'local';
    $settings['PRIVATE_FEEDS'] = isset($_POST['private_feeds']) && $_POST['private_feeds'] === 'on' ? 'on' : 'off';

    if (!miniflux_save_settings($settings_file, $settings)) {
        manage_fail(500, 'The setting could not be saved');
    }

    miniflux_restart($ctl);
    manage_json();
}

if ($action === 'backup_settings') {
    $dir  = isset($_POST['dir']) ? rtrim(trim((string)$_POST['dir']), '/') : '';
    $keep = isset($_POST['keep']) ? (int)$_POST['keep'] : 0;

    if ($keep < 1 || $keep > 365) {
        manage_fail(400, 'Keep between 1 and 365 backups');
    }

    if ($dir !== '') {
        // On the NAS's volumes or USB drives (no line breaks or quotes, which miniflux_ctl.sh couldn't take), in a folder
        // that exists or can be created in one that does
        if (!preg_match('#^/(mnt/HD|mnt/USB|shares)/[^"\'\\\\\x00-\x1f]+$#', $dir)) {
            manage_fail(400, 'Backups go in a folder on the NAS\'s volumes or USB drives, e.g. /mnt/HD/HD_a2/Backups/Miniflux');
        }

        $existing = is_dir($dir) ? $dir : dirname($dir);

        if (!is_dir($existing) || !preg_match('#^/(mnt/HD|mnt/USB)/#', realpath($existing).'/')) {
            manage_fail(400, 'No such folder (its parent folder must exist): '.$dir);
        }
    }

    $settings['BACKUP_DIR']  = $dir;
    $settings['BACKUP_KEEP'] = (string)$keep;

    if (!miniflux_save_settings($settings_file, $settings)) {
        manage_fail(500, 'The settings could not be saved');
    }

    manage_json();
}

if ($action === 'backup_now') {
    list($code, $output) = manage_run(['/bin/sh', $ctl, 'backup']);

    if ($code !== 0) {
        manage_fail(500, $output !== '' ? $output : 'The backup failed (see /tmp/debug_apkg)');
    }

    manage_json(['message' => 'Backed up.']);
}

if ($action === 'restart') {
    miniflux_restart($ctl);
    manage_json();
}

manage_fail(400, 'Unknown action');
