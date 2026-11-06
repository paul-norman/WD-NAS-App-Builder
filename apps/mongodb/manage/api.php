<?php
// MongoDB management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('mongodb');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path      = dirname(__DIR__);
$apps_path     = dirname($app_path);
$data_path     = $apps_path.'/_mongodb';
$settings_file = $data_path.'/settings';
$password_file = $data_path.'/password';
$ctl           = $app_path.'/mongodb_ctl.sh';

/**
 * The app's settings, with defaults.
 *
 * @param string $file The settings file (KEY=value lines, also read by the app's control script)
 *
 * @return array{ LISTEN: string, CACHE_MB: string, BACKUP_DIR: string, BACKUP_KEEP: string } The settings
 */
function mongodb_settings(string $file): array
{
    $settings = [
        'LISTEN'      => 'local',
        'CACHE_MB'    => '512',
        'BACKUP_DIR'  => '',
        'BACKUP_KEEP' => '7',
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
function mongodb_save_settings(string $file, array $settings): bool
{
    $text = '';

    foreach ($settings as $key => $value) {
        $text .= $key.'='.$value."\n";
    }

    return manage_write_file($file, $text);
}

/**
 * Restarts MongoDB with its control script (stop, then start), failing the request if it doesn't start.
 *
 * @param string $ctl The app's control script
 *
 * @return void
 */
function mongodb_restart(string $ctl): void
{
    manage_run(['/bin/sh', $ctl, 'stop']);

    list($code, $output) = manage_run(['/bin/sh', $ctl, 'start']);

    if ($code !== 0) {
        manage_fail(500, 'MongoDB could not be started: '.$output);
    }
}

$settings   = mongodb_settings($settings_file);
$backup_dir = $settings['BACKUP_DIR'] !== '' ? $settings['BACKUP_DIR'] : $data_path.'/backups';
$action     = isset($_GET['action']) ? $_GET['action'] : 'status';

if ($action === 'status') {
    $running   = manage_pid_running('/var/run/mongodb.pid');
    $databases = [];

    // Its databases (logged in as its administrator), which also says it answers
    if ($running) {
        list($code, $output) = manage_run(['/bin/sh', $ctl, 'databases']);

        foreach ($code === 0 ? explode("\n", trim($output)) : [] as $line) {
            if (preg_match('/^(\S+) (\d+)$/', $line, $m)) {
                $databases[] = ['name' => $m[1], 'size' => (int)$m[2]];
            }
        }
    }

    // The app's version, without its own packaging revision (e.g. 8.0.34-1)
    $version = preg_match('/^Version:\s*(\S+)/m', (string)@file_get_contents($app_path.'/apkg.rc'), $m) ? $m[1] : '';
    $backups = [];

    foreach (glob($backup_dir.'/mongodb-*.archive.gz') ?: [] as $file) {
        $backups[] = [
            'name' => basename($file),
            'time' => (int)filemtime($file),
            'size' => (int)filesize($file),
        ];
    }

    usort($backups, function (array $a, array $b): int {
        return $b['time'] - $a['time'];
    });

    // Its warnings and errors: its log has one JSON document per line ("s" its severity, "msg" its message)
    $log = [];

    foreach (array_slice(@file($data_path.'/log/mongod.log', FILE_IGNORE_NEW_LINES) ?: [], -2000) as $line) {
        $entry = json_decode($line, true);

        if (is_array($entry) && isset($entry['s'], $entry['msg']) && in_array($entry['s'], ['W', 'E', 'F'], true)) {
            $log[] = (isset($entry['t']['$date']) ? substr((string)$entry['t']['$date'], 0, 19).' ' : '').$entry['s'].' '.$entry['msg'];
        }
    }

    manage_json([
        'running'            => $running,
        'answering'          => $running && $databases !== [],
        'version'            => preg_replace('/-\d+$/', '', $version),
        'has_password'       => is_file($password_file) && filesize($password_file) > 0,
        'databases'          => $databases,
        'listen'             => $settings['LISTEN'] === 'all' ? 'all' : 'local',
        'cache_mb'           => (int)$settings['CACHE_MB'],
        'backup_dir'         => $settings['BACKUP_DIR'],
        'backup_dir_default' => $data_path.'/backups',
        'backup_keep'        => (int)$settings['BACKUP_KEEP'],
        'backups'            => array_slice($backups, 0, 30),
        'log'                => array_values(array_slice($log, -20)),
    ]);
}

manage_require_action('mongodb');

if ($action === 'password') {
    manage_json(['password' => trim((string)@file_get_contents($password_file))]);
}

if ($action === 'set_password') {
    // A new password: the one given (letters, digits and . _ ~ - only, like the other apps), or a random one - in use
    // at once
    $new = isset($_POST['password']) ? trim((string)$_POST['password']) : '';

    if ($new === '') {
        $new = substr(str_replace(['+', '/', '='], '', base64_encode(random_bytes(48))), 0, 24);
    } elseif (!preg_match('/^[A-Za-z0-9._~-]{12,128}$/', $new)) {
        manage_fail(400, 'Passwords must be 12-128 characters: letters, digits and . _ ~ -');
    }

    list($code, $output) = manage_run(['/bin/sh', $ctl, 'set-password'], [], $new."\n");

    if ($code !== 0) {
        manage_fail(500, 'The password could not be changed: '.$output);
    }

    manage_json(['password' => $new]);
}

if ($action === 'create_db') {
    $name = isset($_POST['name']) ? trim((string)$_POST['name']) : '';

    if (!preg_match('/^[A-Za-z0-9_-]{1,60}$/', $name) || in_array($name, ['admin', 'local', 'config'], true)) {
        manage_fail(400, 'Database names are 1-60 letters, digits, _ and - (not admin, local or config)');
    }

    list($code, $output) = manage_run(['/bin/sh', $ctl, 'create-db', $name]);

    if ($code !== 0 || !preg_match('/^(\S+) (\S+)$/m', trim($output), $m)) {
        manage_fail(500, 'The database could not be made: '.$output);
    }

    manage_json(['user' => $m[1], 'password' => $m[2]]);
}

if ($action === 'settings') {
    $settings['LISTEN']   = isset($_POST['listen']) && $_POST['listen'] === 'all' ? 'all' : 'local';
    $cache                = isset($_POST['cache_mb']) ? (int)$_POST['cache_mb'] : 512;
    $settings['CACHE_MB'] = (string)(in_array($cache, [256, 512, 1024, 2048, 4096], true) ? $cache : 512);

    if (!mongodb_save_settings($settings_file, $settings)) {
        manage_fail(500, 'The settings could not be saved');
    }

    mongodb_restart($ctl);
    manage_json();
}

if ($action === 'backup_settings') {
    $dir  = isset($_POST['dir']) ? rtrim(trim((string)$_POST['dir']), '/') : '';
    $keep = isset($_POST['keep']) ? (int)$_POST['keep'] : 0;

    if ($keep < 1 || $keep > 365) {
        manage_fail(400, 'Keep between 1 and 365 backups');
    }

    if ($dir !== '') {
        // On the NAS's volumes or USB drives (no line breaks or quotes, which mongodb_ctl.sh couldn't take), in a
        // folder that exists or can be created in one that does
        if (!preg_match('#^/(mnt/HD|mnt/USB|shares)/[^"\'\\\\\x00-\x1f]+$#', $dir)) {
            manage_fail(400, 'Backups go in a folder on the NAS\'s volumes or USB drives, e.g. /mnt/HD/HD_a2/Backups/MongoDB');
        }

        $existing = is_dir($dir) ? $dir : dirname($dir);

        if (!is_dir($existing) || !preg_match('#^/(mnt/HD|mnt/USB)/#', realpath($existing).'/')) {
            manage_fail(400, 'No such folder (its parent folder must exist): '.$dir);
        }
    }

    $settings['BACKUP_DIR']  = $dir;
    $settings['BACKUP_KEEP'] = (string)$keep;

    if (!mongodb_save_settings($settings_file, $settings)) {
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
    mongodb_restart($ctl);
    manage_json();
}

manage_fail(400, 'Unknown action');
