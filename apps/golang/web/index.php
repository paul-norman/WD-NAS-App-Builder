<?php
// Redirect to the app's own web server, on the host the NAS UI was opened with (minus the UI's own port)
$port = 30289;
$host = preg_replace('/:\d+$/', '', $_SERVER['HTTP_HOST'] ?? '');
if (!preg_match('/^(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9.-]+)$/', $host)) {
	http_response_code(400);
	exit('Invalid host');
}
header('Location: http://' . $host . ':' . $port . '/');
