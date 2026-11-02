<?php
// Grafana management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('grafana');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path      = dirname(__DIR__);
$apps_path     = dirname($app_path);
$data_path     = $apps_path.'/_grafana';
$graf_data     = $data_path.'/data';
$settings_file = $data_path.'/settings';
$ctl           = $app_path.'/graf_ctl.sh';

require $app_path.'/lib/graf.php';

/**
 * The app's settings, with defaults.
 *
 * @param string $file The settings file (KEY=value lines, also read by the app's control script)
 *
 * @return array{
 *     LISTEN:      string,
 *     BACKUP_DIR:  string,
 *     BACKUP_KEEP: string,
 * } The settings
 */
function graf_settings(string $file): array
{
    $settings = [
        'LISTEN'      => 'all',
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
function graf_save_settings(string $file, array $settings): bool
{
    $text = '';

    foreach ($settings as $key => $value) {
        $text .= $key.'='.$value."\n";
    }

    return manage_write_file($file, $text);
}

/**
 * Runs one of the control script's commands.
 *
 * @param string $ctl     The app's control script
 * @param string $command The command (e.g. restart)
 * @param mixed  $input   What to give it on its standard input (e.g. a password)
 *
 * @return array{ 0: int, 1: string } [exit code, output]
 */
function graf_ctl(string $ctl, string $command, $input = ''): array
{
    return manage_run(['/bin/sh', $ctl, $command], [], $input);
}

$settings   = graf_settings($settings_file);
$backup_dir = $settings['BACKUP_DIR'] !== '' ? $settings['BACKUP_DIR'] : $data_path.'/backups';
$action     = $_GET['action'] ?? 'status';

if ($action === 'status') {
    $running = manage_pid_running('/var/run/grafana.pid');

    list($health)    = $running ? manage_http_get(GRAF_TARGET.'/api/health') : [0];
    list(, $version) = manage_run([$app_path.'/binaries/grafana/bin/grafana', '--version']);

    $backups = [];

    foreach (glob($backup_dir.'/grafana-*.tar.gz') ?: [] as $file) {
        $backups[] = [
            'name' => basename($file),
            'size' => filesize($file),
            'time' => filemtime($file),
        ];
    }

    usort($backups, function (array $a, array $b): int {
        return strcmp($b['name'], $a['name']);
    });

    $log = @file($data_path.'/grafana.log', FILE_IGNORE_NEW_LINES) ?: [];

    manage_json([
        'running'            => $running,
        'answering'          => $health === 200,
        'version'            => preg_match('/version (\S+)/', $version, $m) ? $m[1] : '',
        'listen'             => $settings['LISTEN'] === 'local' ? 'local' : 'all',
        'site'               => manage_nginx_site($apps_path, GRAF_TARGET),
        'prometheus'         => is_dir($apps_path.'/prometheus'),
        'backup_dir'         => $settings['BACKUP_DIR'],
        'backup_dir_default' => $data_path.'/backups',
        'backup_keep'        => (int)$settings['BACKUP_KEEP'],
        'backups'            => array_slice($backups, 0, 30),
        'has_db'             => is_file($graf_data.'/grafana.db'),
        'log'                => array_slice($log, -40),
    ]);
}

manage_require_action('grafana');

if ($action === 'listen') {
    $settings['LISTEN'] = isset($_POST['listen']) && $_POST['listen'] === 'local' ? 'local' : 'all';

    if (!graf_save_settings($settings_file, $settings)) {
        manage_fail(500, 'The setting could not be saved');
    }

    graf_ctl($ctl, 'restart');
    manage_json();
}

if ($action === 'password') {
    manage_json(['password' => trim((string)@file_get_contents($data_path.'/admin_password'))]);
}

if ($action === 'reset_password') {
    // A new random password (letters and digits), given to Grafana's own command on input
    $password = substr(str_replace(['+', '/', '='], '', base64_encode(random_bytes(48))), 0, 20);

    list($code, $output) = graf_ctl($ctl, 'reset-password', $password."\n");

    if ($code !== 0) {
        manage_fail(500, 'The password could not be reset: '.trim(preg_replace('/^.*?(Error: )/s', '$1', $output)));
    }

    manage_json(['password' => $password]);
}

if ($action === 'backup_settings') {
    $dir  = isset($_POST['dir'])  ? rtrim(trim((string)$_POST['dir']), '/') : '';
    $keep = isset($_POST['keep']) ? (int)$_POST['keep'] : 0;

    if ($keep < 1 || $keep > 365) {
        manage_fail(400, 'Keep between 1 and 365 backups');
    }

    if ($dir !== '') {
        // On the NAS's volumes or USB drives (no line breaks or quotes, which graf_ctl.sh couldn't take), in a folder
        // that exists or can be created in one that does
        if (!preg_match('#^/(mnt/HD|mnt/USB|shares)/[^"\'\\\\\x00-\x1f]+$#', $dir)) {
            manage_fail(400, 'Backups go in a folder on the NAS\'s volumes or USB drives, e.g. /mnt/HD/HD_a2/Backups/Grafana');
        }

        $existing = is_dir($dir) ? $dir : dirname($dir);

        if (!is_dir($existing) || !preg_match('#^/(mnt/HD|mnt/USB)/#', realpath($existing).'/')) {
            manage_fail(400, 'No such folder (its parent folder must exist): '.$dir);
        }
    }

    $settings['BACKUP_DIR'] = $dir;
    $settings['BACKUP_KEEP'] = (string)$keep;

    if (!graf_save_settings($settings_file, $settings)) {
        manage_fail(500, 'The settings could not be saved');
    }

    manage_json();
}

if ($action === 'backup_now') {
    list($code, $output) = graf_ctl($ctl, 'backup');

    if ($code !== 0) {
        manage_fail(500, $output !== '' ? $output : 'The backup failed (see /tmp/debug_apkg)');
    }

    manage_json(['message' => $output]);
}

if ($action === 'restart') {
    list($code, $output) = graf_ctl($ctl, 'restart');

    if ($code !== 0) {
        manage_fail(500, 'Grafana could not be started: '.$output);
    }

    manage_json();
}

manage_fail(400, 'Unknown action');
