<?php
// Logs app (Loki + Vector) management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('loki');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path = dirname(__DIR__);
$data_path = dirname($app_path) . '/_loki';
$settings_file = $data_path . '/settings';
$ctl = $app_path . '/loki_ctl.sh';
$loki = 'http://127.0.0.1:3100';

// The settings file (KEY=value lines, also read by loki_ctl.sh), with defaults
function loki_settings($file)
{
	$settings = ['RETENTION_DAYS' => '30', 'SYSTEM_LOGS' => '1', 'APP_LOGS' => '1', 'DOCKER_LOGS' => '1'];
	foreach (@file($file, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
		if (preg_match('/^([A-Z_]+)=(.*)$/', $line, $m) && isset($settings[$m[1]])) {
			$settings[$m[1]] = $m[2];
		}
	}
	return $settings;
}

function loki_tail($file)
{
	return array_slice(@file($file, FILE_IGNORE_NEW_LINES) ?: [], -20);
}

$settings = loki_settings($settings_file);
$action = isset($_GET['action']) ? $_GET['action'] : 'status';

if ($action === 'status') {
	$loki_running = manage_pid_running('/var/run/loki.pid');
	list($ready_code, $ready) = $loki_running ? manage_http_get($loki . '/ready') : [0, ''];
	list(, $loki_version) = manage_run([$app_path . '/binaries/loki', '--version']);
	list(, $vector_version) = manage_run([$app_path . '/binaries/vector', '--version']);
	list(, $du) = manage_run(['du', '-sk', $data_path . '/data']);

	// What has been collected in the last 24 hours: lines per log, from Loki itself
	$logs = [];
	if ($ready_code === 200) {
		$query = 'sum by (source, app) (count_over_time({source=~".+"}[24h]))';
		list($code, $body) = manage_http_get($loki . '/loki/api/v1/query?' . http_build_query(['query' => $query]), 10);
		$json = $code === 200 ? json_decode($body, true) : null;
		foreach (isset($json['data']['result']) ? $json['data']['result'] : [] as $row) {
			$logs[] = [
				'source' => isset($row['metric']['source']) ? $row['metric']['source'] : '',
				'app' => isset($row['metric']['app']) ? $row['metric']['app'] : '',
				'lines' => (int)$row['value'][1],
			];
		}
		usort($logs, function ($a, $b) { return strcmp($a['source'] . $a['app'], $b['source'] . $b['app']); });
	}

	manage_json([
		'loki_running' => $loki_running,
		'loki_ready' => $ready_code === 200,
		'loki_state' => trim($ready),
		'vector_running' => manage_pid_running('/var/run/loki-vector.pid'),
		'loki_version' => preg_match('/version (\S+)/', $loki_version, $m) ? $m[1] : '',
		'vector_version' => preg_match('/^vector (\S+)/', $vector_version, $m) ? $m[1] : '',
		'storage' => preg_match('/^(\d+)/', $du, $m) ? (int)$m[1] * 1024 : 0,
		'retention_days' => (int)$settings['RETENTION_DAYS'],
		'system_logs' => $settings['SYSTEM_LOGS'] === '1',
		'app_logs' => $settings['APP_LOGS'] === '1',
		'docker_logs' => $settings['DOCKER_LOGS'] === '1',
		'docker_running' => file_exists('/var/run/docker.sock'),
		'grafana' => is_dir(dirname($app_path) . '/grafana'),
		'logs' => $logs,
		'loki_log' => loki_tail($data_path . '/loki.log'),
		'vector_log' => loki_tail($data_path . '/vector.log'),
	]);
}

manage_require_action('loki');

if ($action === 'settings') {
	$days = isset($_POST['retention_days']) ? (int)$_POST['retention_days'] : 0;
	if ($days < 1 || $days > 3650) {
		manage_fail(400, 'Keep between 1 and 3650 days of logs');
	}
	$text = 'RETENTION_DAYS=' . $days . "\n";
	foreach (['SYSTEM_LOGS' => 'system_logs', 'APP_LOGS' => 'app_logs', 'DOCKER_LOGS' => 'docker_logs'] as $key => $field) {
		$text .= $key . '=' . (empty($_POST[$field]) ? 0 : 1) . "\n";
	}
	if (!manage_write_file($settings_file, $text)) {
		manage_fail(500, 'The settings could not be saved');
	}
	list($code, $output) = manage_run(['/bin/sh', $ctl, 'restart']);
	if ($code !== 0) {
		manage_fail(500, 'The logs app could not be started: ' . $output);
	}
	manage_json([]);
}

if ($action === 'restart') {
	list($code, $output) = manage_run(['/bin/sh', $ctl, 'restart']);
	if ($code !== 0) {
		manage_fail(500, 'The logs app could not be started: ' . $output);
	}
	manage_json([]);
}

manage_fail(400, 'Unknown action');
