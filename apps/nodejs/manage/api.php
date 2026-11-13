<?php
// Node.js management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('nodejs');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path = dirname(__DIR__);
$bin_path = $app_path.'/binaries/bin';

// npm (and pnpm on the ARM models) are scripts run by node, which they find in the PATH
$env = ['PATH' => $bin_path.':/usr/bin:/bin:/usr/sbin:/sbin'];

$action = $_GET['action'] ?? 'status';

if ($action === 'status') {
    $versions = [];

    foreach (['node', 'npm', 'pnpm'] as $tool) {
        list($code, $output) = manage_run([$bin_path.'/'.$tool, '--version'], $env);

        $versions[$tool] = $code === 0 ? ltrim($output, 'v') : '';
    }

    $running = manage_pid_running('/var/run/nodejs_test_server.pid');

    list($status) = $running ? manage_http_get('http://127.0.0.1:30290/') : [0];

    manage_json([
        'versions'    => $versions,
        'test_server' => $running ? ($status === 200 ? 'running' : 'starting') : 'stopped',
    ]);
}

manage_require_action('nodejs');

if ($action === 'restart') {
    manage_run(['/bin/sh', $app_path.'/stop.sh', $app_path]);

    list($code, $output) = manage_run(['/bin/sh', $app_path.'/start.sh', $app_path]);

    if ($code !== 0) {
        manage_fail(500, 'The test server could not be started: '.$output);
    }

    manage_json();
}

manage_fail(400, 'Unknown action');
