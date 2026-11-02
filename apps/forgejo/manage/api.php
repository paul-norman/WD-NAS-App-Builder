<?php
// Forgejo management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('forgejo');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path      = dirname(__DIR__);
$apps_path     = dirname($app_path);
$data_path     = $apps_path.'/_forgejo';
$settings_file = $data_path.'/settings';
$backup_dir    = $data_path.'/backups';
$ctl           = $app_path.'/forgejo_ctl.sh';

require $app_path.'/lib/forgejo.php';

/**
 * The app's settings, with defaults.
 *
 * @param string $file The settings file (KEY=value lines, also read by the app's control script)
 *
 * @return array{
 *     LISTEN:      string,
 *     SSH:         string,
 *     BACKUP:      string,
 *     BACKUP_KEEP: string,
 * } The settings
 */
function forgejo_settings(string $file): array
{
    $settings = [
        'LISTEN'      => 'all',
        'SSH'         => '1',
        'BACKUP'      => 'weekly',
        'BACKUP_KEEP' => '4',
    ];

    foreach (@file($file, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
        if (preg_match('/^([A-Z_]+)=(.*)$/', $line, $m) && isset($settings[$m[1]])) {
            $settings[$m[1]] = $m[2];
        }
    }

    return $settings;
}

/**
 * Restarts Forgejo with its control script (stop, then start), failing the request if it doesn't start.
 *
 * @param string $ctl The app's control script
 *
 * @return void
 */
function forgejo_restart(string $ctl): void
{
    manage_run(['/bin/sh', $ctl, 'stop']);

    list($code, $output) = manage_run(['/bin/sh', $ctl, 'start']);

    if ($code !== 0) {
        manage_fail(500, 'Forgejo could not be started: '.$output);
    }
}

$settings = forgejo_settings($settings_file);
$action   = $_GET['action'] ?? 'status';

if ($action === 'status') {
    $running = manage_pid_running('/var/run/forgejo.pid');

    list($code, $health) = $running ? manage_http_get(FORGEJO_TARGET.'/api/healthz') : [0, ''];
    list(, $version) = manage_run([$app_path.'/binaries/forgejo', '--version']);

    // The address and SSH server Forgejo runs with (set when it started - clone URLs use them)
    $ini     = (string)@file_get_contents($data_path.'/custom/conf/app.ini');
    $base    = forgejo_ini_get($ini, 'server', 'ROOT_URL');
    $ssh     = forgejo_ini_get($ini, 'server', 'START_SSH_SERVER') === 'true';
    $site    = manage_nginx_site($apps_path, FORGEJO_TARGET);
    $backups = [];

    foreach (glob($backup_dir.'/forgejo-*.tar.gz') ?: [] as $file) {
        $backups[] = [
            'name' => basename($file),
            'size' => filesize($file),
            'time' => filemtime($file),
        ];
    }

    usort($backups, function (array $a, array $b): int {
        return strcmp($b['name'], $a['name']);
    });

    // Without the information Forgejo logs at every start
    $log = array_values(array_filter(@file($data_path.'/forgejo.log', FILE_IGNORE_NEW_LINES) ?: [], function (string $line): bool {
        return trim($line) !== '' && strpos($line, '] [I] ') === false;
    }));

    manage_json([
        'running'        => $running,
        'answering'      => $code === 200 && strpos($health, '"pass"') !== false,
        'version'        => preg_match('/version ([0-9][^+\s]*)/', $version, $m) ? $m[1] : '',
        'base_url'       => $base,
        'ssh_url'        => $ssh ? 'ssh://git@'.forgejo_ini_get($ini, 'server', 'SSH_DOMAIN').':'.FORGEJO_SSH_PORT.'/' : '',
        'site'           => $site,
        // The Nginx app's address changed since Forgejo started (its links and clone URLs use it)
        'restart_needed' => $running && $site['url'] !== '' && $site['url'] !== $base,
        'repositories'   => count(glob($data_path.'/repositories/*/*.git', GLOB_ONLYDIR) ?: []),
        'listen'         => $settings['LISTEN'] === 'local' ? 'local' : 'all',
        'ssh'            => $settings['SSH'] === '1',
        'backup'         => $settings['BACKUP'],
        'backup_keep'    => (int)$settings['BACKUP_KEEP'],
        'backup_dir'     => $backup_dir,
        'backup_running' => manage_pid_running('/var/run/forgejo-backup.pid'),
        'backups'        => $backups,
        'log'            => array_slice($log, -20),
    ]);
}

manage_require_action('forgejo');

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
    $backup = isset($_POST['backup']) && in_array($_POST['backup'], ['daily', 'weekly', 'off'], true) ? $_POST['backup'] : 'weekly';
    $keep   = isset($_POST['backup_keep']) ? (int)$_POST['backup_keep'] : 4;

    if ($keep < 1 || $keep > 30) {
        manage_fail(400, 'Keep 1-30 backups');
    }

    $text = 'LISTEN='.(isset($_POST['listen']) && $_POST['listen'] === 'local' ? 'local' : 'all')."\n"
       .'SSH='.(empty($_POST['ssh']) ? 0 : 1)."\n"
       .'BACKUP='.$backup."\n"
       .'BACKUP_KEEP='.$keep."\n";

    if (!manage_write_file($settings_file, $text)) {
        manage_fail(500, 'The settings could not be saved');
    }

    forgejo_restart($ctl);
    manage_json();
}

if ($action === 'backup') {
    // It can take a while (repositories can be large): run in the background, the page shows when it's done
    if (manage_pid_running('/var/run/forgejo-backup.pid')) {
        manage_fail(409, 'A backup is already running');
    }

    manage_run(['/bin/sh', '-c', 'sh "$0" backup > /dev/null 2>&1 &', $ctl]);
    manage_json();
}

if ($action === 'restart') {
    forgejo_restart($ctl);
    manage_json();
}

manage_fail(400, 'Unknown action');
