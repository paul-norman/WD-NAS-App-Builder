<?php
// MariaDB app management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('mariadb');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path  = dirname(__DIR__);
$data_path = dirname($app_path).'/_mariadb';
$socket    = '/var/lib/mysql/mysql.sock';

$action = $_GET['action'] ?? 'status';

if ($action === 'status') {
    // Which server runs: /usr/libexec/mariadbd leads (through /usr/local/mysql) into the app when it's 11.8
    $app_server = strpos((string)realpath('/usr/libexec/mariadbd'), $app_path.'/') === 0;
    // Asked with the matching client: WD's 10.5 one warns about 11.8's renamed character sets on every connection
    $client     = $app_server ? $app_path.'/binaries/mariadb/bin/mariadb' : 'mysql';

    list($code, $version) = manage_run(['/bin/sh', '-c', '"$0" --socket="$1" -uroot -N -e "SELECT VERSION()" 2>/dev/null', $client, $socket]);
    list(, $size)         = is_dir($data_path.'/data') ? manage_run(['du', '-sh', $data_path.'/data']) : [0, ''];

    $err = glob($data_path.'/data/*.err') ?: [];
    $log = $err ? file($err[0], FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) : [];

    // Only since the server last started
    foreach (array_reverse(array_keys($log)) as $i) {
        // 10.5: "... starting as process N", 11.x: "Starting MariaDB ... as process N"
        if (strpos($log[$i], ' as process ') !== false) {
            $log = array_slice($log, $i);

            break;
        }
    }

    $problems = array_values(array_filter($log, function (string $line) {
        return preg_match('/\[(ERROR|Warning)\]/', $line);
    }));

    manage_json([
        'running'    => $code === 0,
        'version'    => $code === 0 ? $version : '',
        'app_server' => $app_server,
        // wd: underneath WD's own MariaDB; own: by itself (the NAS has no MariaDB of its own)
        'mode'       => trim((string)@file_get_contents($data_path.'/mode')) ?: 'wd',
        'wd_datadir' => trim((string)@file_get_contents($data_path.'/wd_datadir')),
        'copy'       => $data_path.'/data',
        'copy_size'  => preg_match('/^(\S+)/', $size, $m) ? $m[1] : '',
        'problems'   => array_slice($problems, -20),
    ]);
}

manage_fail(400, 'Unknown action');
