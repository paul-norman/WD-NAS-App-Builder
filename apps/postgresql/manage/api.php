<?php
// PostgreSQL management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('postgresql');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path      = dirname(__DIR__);
$data_path     = dirname($app_path).'/_postgresql';
$bin           = $app_path.'/binaries/postgresql/bin';
$password_file = $data_path.'/postgres_password';

/**
 * Runs SQL as the `postgres` superuser: the SQL goes in on its standard input, the password in its environment.
 *
 * @param string $sql The SQL
 *
 * @return array{ 0: int, 1: string } [exit code, output]
 */
function pg_sql(string $sql): array
{
    global $bin, $password_file;

    return manage_run([$bin.'/psql', '-h', '/var/run/postgresql', '-U', 'postgres', '-d', 'postgres', '-X', '-q', '-A', '-t',
        '-F', "\t", '-v', 'ON_ERROR_STOP=1'], ['PGPASSWORD' => trim((string)@file_get_contents($password_file))], $sql);
}

/**
 * A password for a database user: the one given, if it's 12-128 letters, digits and . _ ~ - (else the request fails),
 * or a generated one.
 *
 * @param string $given The password given ('' for a generated one)
 *
 * @return string The password
 */
function pg_new_password(string $given): string
{
    if ($given === '') {
        return substr(str_replace(['+', '/', '='], '', base64_encode(random_bytes(48))), 0, 24);
    }

    if (!preg_match('/^[A-Za-z0-9._~-]{12,128}$/', $given)) {
        manage_fail(400, 'Passwords must be 12-128 characters: letters, digits and . _ ~ -');
    }

    return $given;
}

$action = $_GET['action'] ?? 'status';

if ($action === 'status') {
    list($code, $databases) = pg_sql("SELECT d.datname, pg_get_userbyid(d.datdba), pg_size_pretty(pg_database_size(d.oid)) FROM pg_database d WHERE NOT d.datistemplate ORDER BY 1;\n");
    list(, $version)        = manage_run([$bin.'/postgres', '--version']);

    $conf = (string)@file_get_contents($data_path.'/data/postgresql.conf');
    $list = [];

    foreach ($code === 0 ? explode("\n", $databases) : [] as $line) {
        $fields = explode("\t", $line);

        if (count($fields) === 3) {
            $list[] = ['name' => $fields[0], 'owner' => $fields[1], 'size' => $fields[2]];
        }
    }

    preg_match("/^shared_preload_libraries = '([^']*)'/m", $conf, $m);

    manage_json([
        'preload'   => isset($m[1]) && $m[1] !== '' ? explode(',', $m[1]) : [],
        'running'   => $code === 0,
        'version'   => preg_match('/(\d+\.\d+)/', $version, $m) ? $m[1] : '',
        'network'   => (bool)preg_match("/^listen_addresses = '\\*'/m", $conf),
        'databases' => $list,
        'error'     => $code === 0 ? '' : $databases,
    ]);
}

manage_require_action('postgresql');

if ($action === 'password') {
    manage_json(['password' => trim((string)@file_get_contents($password_file))]);
}

if ($action === 'set_password') {
    $new = pg_new_password(isset($_POST['password']) ? trim((string)$_POST['password']) : '');

    list($code, $output) = pg_sql("ALTER ROLE postgres PASSWORD '{$new}';\n");

    if ($code !== 0) {
        manage_fail(500, 'PostgreSQL refused the new password: '.$output);
    }

    if (!manage_write_file($password_file, $new)) {
        manage_fail(500, 'The password was changed, but could not be saved to: '.$password_file);
    }

    manage_json(['password' => $new]);
}

if ($action === 'create_database') {
    // A database with a user of its own (the owner) - names are lower case letters, digits and _ (no quoting needed)
    $name = strtolower(trim(isset($_POST['name']) ? (string)$_POST['name'] : ''));
    $user = strtolower(trim(isset($_POST['user']) ? (string)$_POST['user'] : ''));

    if ($user === '') {
        $user = $name;
    }

    foreach ([$name, $user] as $identifier) {
        if (!preg_match('/^[a-z_][a-z0-9_]{0,62}$/', $identifier) || preg_match('/^pg_/', $identifier)) {
            manage_fail(400, 'Names are lower case letters, digits and _ (not starting with a digit or pg_): '.$identifier);
        }
    }

    $password = pg_new_password(isset($_POST['password']) ? trim((string)$_POST['password']) : '');

    list($code, $output) = pg_sql("CREATE ROLE \"{$user}\" LOGIN PASSWORD '{$password}';\nCREATE DATABASE \"{$name}\" OWNER \"{$user}\";\n");

    if ($code !== 0) {
        manage_fail(500, 'PostgreSQL refused: '.$output);
    }

    manage_json(['name' => $name, 'user' => $user, 'password' => $password]);
}

if ($action === 'preload') {
    // Only the extensions that need loading at start-up
    $wanted = array_values(array_intersect(['pg_cron', 'pgaudit'], isset($_POST['extensions']) ? (array)$_POST['extensions'] : []));

    list($code, $output) = manage_run(['/bin/sh', $app_path.'/pgsql_ctl.sh', 'preload', implode(',', $wanted)]);

    if ($code !== 0) {
        manage_fail(500, 'PostgreSQL could not restart: '.$output);
    }

    manage_json(['preload' => $wanted]);
}

if ($action === 'network') {
    $on = !empty($_POST['on']);

    list($code, $output) = manage_run(['/bin/sh', $app_path.'/pgsql_ctl.sh', 'network', $on ? 'on' : 'off']);

    if ($code !== 0) {
        manage_fail(500, 'PostgreSQL could not restart: '.$output);
    }

    manage_json(['network' => $on]);
}

manage_fail(400, 'Unknown action');
