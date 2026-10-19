<?php
// Entware management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('entware');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path = dirname(__DIR__);
$data_path = dirname($app_path) . '/_entware';
$opkg = '/opt/bin/opkg';
$init_path = '/opt/etc/init.d';
$job_pid_file = '/var/run/entware_manage_job.pid';
$job_log_file = '/var/run/entware_manage_job.log';
// Entware's own core, which the page won't remove (doing so would break Entware itself)
$core_packages = ['opkg', 'entware-opt', 'entware-release', 'entware-upgrade', 'libc', 'libgcc', 'libpthread', 'librt',
	'libssp', 'libstdcpp', 'ld.so', 'wget-ssl', 'ca-bundle'];
// Package scripts expect Entware's own commands first in the PATH
$opkg_env = ['PATH' => '/opt/bin:/opt/sbin:/usr/bin:/bin:/usr/sbin:/sbin'];

// Whether a package job (update, upgrade, install, remove) started from this page is still going
function entware_job_running($pid_file)
{
	$pid = (int)@file_get_contents($pid_file);
	return $pid > 0 && file_exists('/proc/' . $pid);
}

// Starts a package job in the background (detached from this request), logging to $log_file. $script runs with $opkg set
// and the packages as "$@"; afterwards the number of updates is saved for check_update.sh's alerts
function entware_start_job($pid_file, $log_file, $count_file, $opkg, $script, array $packages, array $env)
{
	$job = 'pid_file="$1"; log_file="$2"; count_file="$3"; opkg="$4"; shift 4; echo $$ > "$pid_file"; '
		. '{ ' . $script . '; } > "$log_file" 2>&1; echo "Finished (exit code $?)" >> "$log_file"; '
		. '"$opkg" list-upgradable 2>/dev/null | wc -l > "$count_file"; rm -f "$pid_file"';
	manage_run(array_merge(['/bin/sh', '-c', '"$0" -c "$@" > /dev/null 2>&1 < /dev/null &', '/bin/sh', $job, 'job',
		$pid_file, $log_file, $count_file, $opkg], $packages), $env);

	// Wait briefly for it to start, so that the next status already shows the job
	for ($i = 0; $i < 20 && !entware_job_running($pid_file); $i++) {
		usleep(100000);
	}
}

// Package names from the page: letters, digits and . + _ - only (they are passed to opkg as separate arguments)
function entware_packages()
{
	$names = preg_split('/[\s,]+/', isset($_POST['packages']) ? trim((string)$_POST['packages']) : '', -1, PREG_SPLIT_NO_EMPTY);
	if (!$names) {
		manage_fail(400, 'No package given');
	}
	foreach ($names as $name) {
		if (!preg_match('/^[A-Za-z0-9][A-Za-z0-9.+_-]{0,99}$/', $name)) {
			manage_fail(400, 'Not a package name: ' . $name);
		}
	}
	return $names;
}

// Entware's services: the S* scripts in /opt/etc/init.d (started and stopped with the app)
function entware_services($init_path)
{
	$services = [];
	foreach (glob($init_path . '/S*') ?: [] as $script) {
		if (is_file($script) && is_executable($script)) {
			$services[] = basename($script);
		}
	}
	return $services;
}

// Runs a service script's command. Its output goes to a temporary file rather than a pipe: a daemon it starts could
// otherwise keep the pipe (and so this request) open
function entware_service_run($script, $command, array $env)
{
	$output_file = tempnam(sys_get_temp_dir(), 'entware');
	list($code) = manage_run(['/bin/sh', '-c', '"$0" "$1" > "$2" 2>&1 < /dev/null', $script, $command, $output_file], $env);
	$output = (string)@file_get_contents($output_file);
	@unlink($output_file);
	return [$code, trim(preg_replace('/\e\[[0-9;]*m/', '', $output))];
}

// Whether a service is running: true, false or null (unknown). Scripts using Entware's rc.func answer "check" with
// "alive" or "dead"; others (e.g. dropbear's) may only have "status", printing e.g. "dropbear is not running"
function entware_service_running($script, array $env)
{
	foreach (['check', 'status'] as $command) {
		list(, $output) = entware_service_run($script, $command, $env);
		if (preg_match('/\b(dead|not running|stopped)\b/i', $output)) {
			return false;
		}
		if (preg_match('/\b(alive|running)\b/i', $output)) {
			return true;
		}
	}
	return null;
}

$action = isset($_GET['action']) ? $_GET['action'] : 'status';

if ($action === 'status') {
	$mounted = (bool)preg_match('# /opt #', (string)@file_get_contents('/proc/mounts'));
	$installed = is_executable($opkg);

	$packages = [];
	if ($installed) {
		list(, $output) = manage_run([$opkg, 'list-installed'], $opkg_env);
		foreach (explode("\n", $output) as $line) {
			if (preg_match('/^(\S+) - (\S+)/', $line, $m)) {
				$packages[] = ['name' => $m[1], 'version' => $m[2], 'core' => in_array($m[1], $core_packages, true)];
			}
		}
	}

	$services = [];
	foreach ($installed ? entware_services($init_path) : [] as $service) {
		$services[] = ['name' => $service, 'running' => entware_service_running($init_path . '/' . $service, $opkg_env)];
	}

	$conf = (string)@file_get_contents('/opt/etc/opkg.conf');
	$log = (string)@file_get_contents($job_log_file);
	manage_json([
		'mounted' => $mounted,
		'installed' => $installed,
		'arch' => preg_match('#bin\.entware\.net/([^/\s]+)#', $conf, $m) ? $m[1] : '',
		'https' => strpos($conf, 'https://bin.entware.net') !== false,
		'packages' => $packages,
		'services' => $services,
		'updates_last_check' => trim((string)@file_get_contents($data_path . '/last_update_alert')),
		'job_running' => entware_job_running($job_pid_file),
		'job_log' => strlen($log) > 20000 ? '…' . substr($log, -20000) : $log,
	]);
}

manage_require_action('entware');

if (!is_executable($opkg)) {
	manage_fail(500, 'Entware is not installed (or /opt is not mounted)');
}

if ($action === 'check_updates') {
	if (entware_job_running($job_pid_file)) {
		manage_fail(409, 'A package job is still running');
	}
	list($code, $output) = manage_run([$opkg, 'update'], $opkg_env);
	if ($code !== 0) {
		manage_fail(500, 'The package lists could not be downloaded: ' . $output);
	}
	list(, $output) = manage_run([$opkg, 'list-upgradable'], $opkg_env);
	$updates = [];
	foreach (explode("\n", $output) as $line) {
		if (preg_match('/^(\S+) - (\S+) - (\S+)/', $line, $m)) {
			$updates[] = ['name' => $m[1], 'version' => $m[2], 'new_version' => $m[3]];
		}
	}
	@file_put_contents($data_path . '/last_update_alert', count($updates) . "\n");
	manage_json(['updates' => $updates]);
}

if ($action === 'search') {
	// Matches package names (from the lists downloaded by the last update check)
	$term = isset($_POST['term']) ? trim((string)$_POST['term']) : '';
	if (!preg_match('/^[A-Za-z0-9.+_-]{2,50}$/', $term)) {
		manage_fail(400, 'Search for 2-50 letters, digits or . + _ -');
	}
	if (!glob('/opt/var/opkg-lists/*')) {
		manage_run([$opkg, 'update'], $opkg_env);
	}
	list(, $output) = manage_run([$opkg, 'find', '*' . $term . '*'], $opkg_env);
	$results = [];
	foreach (explode("\n", $output) as $line) {
		if (preg_match('/^(\S+) - (\S+)(?: - (.*))?$/', $line, $m)) {
			$results[] = ['name' => $m[1], 'version' => $m[2], 'description' => isset($m[3]) ? $m[3] : ''];
		}
	}
	manage_json(['results' => array_slice($results, 0, 200), 'more' => count($results) > 200]);
}

if (in_array($action, ['upgrade', 'install', 'remove', 'use_https'], true)) {
	if (entware_job_running($job_pid_file)) {
		manage_fail(409, 'Another package job is still running');
	}
	$scripts = [
		'upgrade' => '"$opkg" update && "$opkg" upgrade',
		'install' => '"$opkg" update && "$opkg" install "$@"',
		'remove' => '"$opkg" remove "$@"',
		'use_https' => '/bin/sh "$app_path/use_https.sh"',
	];
	$packages = in_array($action, ['install', 'remove'], true) ? entware_packages() : [];
	if ($action === 'remove' && array_intersect($packages, $core_packages)) {
		manage_fail(400, 'Entware\'s core packages can\'t be removed here: ' . implode(', ', array_intersect($packages, $core_packages)));
	}
	entware_start_job($job_pid_file, $job_log_file, $data_path . '/last_update_alert', $opkg, $scripts[$action], $packages, $opkg_env + ['app_path' => $app_path]);
	manage_json([]);
}

if ($action === 'service') {
	// Only the services that exist, and only these commands
	$service = isset($_POST['service']) ? (string)$_POST['service'] : '';
	$command = isset($_POST['command']) ? (string)$_POST['command'] : '';
	if (!in_array($service, entware_services($init_path), true) || !in_array($command, ['start', 'stop', 'restart'], true)) {
		manage_fail(400, 'Unknown service or command');
	}
	list(, $output) = entware_service_run($init_path . '/' . $service, $command, $opkg_env);
	manage_json(['output' => $output]);
}

manage_fail(400, 'Unknown action');
