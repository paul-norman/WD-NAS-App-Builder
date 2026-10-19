<?php
// Mailpit management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('mailpit');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path = dirname(__DIR__);
$mailpit_url = 'http://127.0.0.1:8025';

$action = isset($_GET['action']) ? $_GET['action'] : 'status';

if ($action === 'status') {
	$running = manage_pid_running('/var/run/mailpit.pid');
	list($status, $body) = $running ? manage_http_get($mailpit_url . '/api/v1/messages?limit=1') : [0, ''];
	$messages = $status === 200 ? json_decode($body, true) : null;
	$rc = (string)@file_get_contents($app_path . '/apkg.rc');
	manage_json([
		'running' => $running,
		'answering' => is_array($messages),
		'version' => preg_match('/^Version:[ \t]*(\S+)/m', $rc, $m) ? $m[1] : '',
		'total' => isset($messages['messages_count']) ? (int)$messages['messages_count'] : (isset($messages['total']) ? (int)$messages['total'] : 0),
		'unread' => isset($messages['unread']) ? (int)$messages['unread'] : 0,
	]);
}

manage_require_action('mailpit');

if ($action === 'restart') {
	manage_run(['/bin/sh', $app_path . '/stop.sh', $app_path]);
	list($code, $output) = manage_run(['/bin/sh', $app_path . '/start.sh', $app_path]);
	if ($code !== 0) {
		manage_fail(500, 'Mailpit could not be started: ' . $output);
	}
	manage_json([]);
}

if ($action === 'delete_all') {
	// Without a list of messages, Mailpit deletes them all
	list($status, $body) = manage_http_request('DELETE', $mailpit_url . '/api/v1/messages', '{}');
	if ($status !== 200) {
		manage_fail(500, 'Mailpit did not delete the messages' . ($body !== '' ? ': ' . $body : ' - is it running?'));
	}
	manage_json([]);
}

manage_fail(400, 'Unknown action');
