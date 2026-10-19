<?php
// Jellyfin management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('jellyfin');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path = dirname(__DIR__);
$encoding_file = dirname($app_path) . '/_jellyfin/config/encoding.xml';
$pid_file = '/var/run/jellyfin.pid';
$job_pid_file = '/var/run/jellyfin_manage_job.pid';
$jellyfin_url = 'http://127.0.0.1:8096';

// Whether a restart started from this page is still going
function jellyfin_job_running($pid_file)
{
	$pid = (int)@file_get_contents($pid_file);
	return $pid > 0 && file_exists('/proc/' . $pid);
}

// Fetches one of Jellyfin's own pages (on the NAS itself), or returns null
function jellyfin_get($url)
{
	list($status, $body) = manage_http_get($url);
	return $status === 200 ? $body : null;
}

// The GPU's recommended transcoding settings (from transcoding.sh, which asks vainfo): [driver, settings]
function jellyfin_recommended($app_path)
{
	list(, $output) = manage_run(['/bin/sh', $app_path . '/transcoding.sh', 'detect']);
	$driver = '';
	$settings = [];
	foreach (explode("\n", $output) as $line) {
		if (preg_match('/^([A-Za-z0-9]+)=(.*)$/', $line, $m)) {
			if ($m[1] === 'Driver') {
				$driver = $m[2];
			} else {
				$settings[$m[1]] = $m[1] === 'HardwareDecodingCodecs' ? array_values(array_filter(explode(',', $m[2]))) : $m[2];
			}
		}
	}
	return [$driver, $settings];
}

// The current values of the given settings in Jellyfin's encoding.xml (null where Jellyfin uses its default)
function jellyfin_current($file, array $names)
{
	$xml = (string)@file_get_contents($file);
	$current = [];
	foreach ($names as $name) {
		if ($name === 'HardwareDecodingCodecs') {
			if (preg_match('#<HardwareDecodingCodecs>(.*?)</HardwareDecodingCodecs>#s', $xml, $m)) {
				preg_match_all('#<string>([^<]*)</string>#', $m[1], $codecs);
				$current[$name] = $codecs[1];
			} else {
				$current[$name] = strpos($xml, '<HardwareDecodingCodecs />') !== false ? [] : null;
			}
		} elseif (preg_match('#<' . $name . '>([^<]*)</' . $name . '>#', $xml, $m)) {
			$current[$name] = html_entity_decode($m[1], ENT_XML1);
		} else {
			$current[$name] = strpos($xml, '<' . $name . ' />') !== false ? '' : null;
		}
	}
	return $current;
}

// Restarts Jellyfin in the background (detached from this request), optionally applying the recommended transcoding
// settings while it is stopped (Jellyfin only reads them when it starts)
function jellyfin_restart($app_path, $job_pid_file, $encoding_file, $apply)
{
	$job = 'echo $$ > "$1"; /bin/sh "$0/stop.sh" "$0"; '
		. 'if [ "$3" = apply ]; then /bin/sh "$0/transcoding.sh" apply "$2"; fi; '
		. '/bin/sh "$0/start.sh" "$0"; rm -f "$1"';
	manage_run(['/bin/sh', '-c', '/bin/sh -c "$0" "$1" "$2" "$3" "$4" > /dev/null 2>&1 < /dev/null &', $job, $app_path,
		$job_pid_file, $encoding_file, $apply ? 'apply' : '']);

	// Wait briefly for it to start, so that the next status already shows the restart
	for ($i = 0; $i < 20 && !jellyfin_job_running($job_pid_file); $i++) {
		usleep(100000);
	}
}

$action = isset($_GET['action']) ? $_GET['action'] : 'status';

if ($action === 'status') {
	$pid = (int)@file_get_contents($pid_file);
	$running = $pid > 0 && file_exists('/proc/' . $pid);
	$info = $running ? json_decode((string)jellyfin_get($jellyfin_url . '/System/Info/Public'), true) : null;
	manage_json([
		'running' => $running,
		'restarting' => jellyfin_job_running($job_pid_file),
		'health' => $running ? trim((string)jellyfin_get($jellyfin_url . '/health')) : '',
		'version' => isset($info['Version']) ? $info['Version'] : '',
		'server_name' => isset($info['ServerName']) ? $info['ServerName'] : '',
		'wizard_done' => !empty($info['StartupWizardCompleted']),
	]);
}

if ($action === 'transcoding') {
	list($driver, $recommended) = jellyfin_recommended($app_path);
	$current = jellyfin_current($encoding_file, array_keys($recommended));
	// (the order of the codecs doesn't matter)
	$matches = true;
	foreach ($recommended as $name => $value) {
		$now = $current[$name];
		if (is_array($value) && is_array($now)) {
			sort($value);
			sort($now);
		}
		if ($now !== $value) {
			$matches = false;
		}
	}
	manage_json([
		'driver' => $driver,
		'recommended' => $recommended,
		'current' => $current,
		'configured' => is_file($encoding_file),
		'matches' => $matches,
	]);
}

manage_require_action('jellyfin');

if ($action === 'restart' || $action === 'apply') {
	if (jellyfin_job_running($job_pid_file)) {
		manage_fail(409, 'Jellyfin is already restarting');
	}
	jellyfin_restart($app_path, $job_pid_file, $encoding_file, $action === 'apply');
	manage_json([]);
}

manage_fail(400, 'Unknown action');
