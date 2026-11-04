<?php
// Ruby management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('ruby');

// Manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path  = dirname(__DIR__);
$data_path = dirname($app_path).'/_ruby';
$bin       = $app_path.'/binaries/bin';

$action = $_GET['action'] ?? 'status';

if ($action === 'status') {
    list($code, $version) = manage_run([$bin.'/ruby', '-e', 'print RUBY_VERSION, " ", Gem::VERSION, " ", (require "bundler"; Bundler::VERSION)']);

    $versions = $code === 0 ? explode(' ', $version) : [];
    $gems     = [];

    // The gems installed since (in its data folder - Ruby's own are in the app's folder), by their specifications
    foreach (glob($data_path.'/gems/*/specifications/*.gemspec') ?: [] as $spec) {
        $gems[] = basename($spec, '.gemspec');
    }

    $running = manage_pid_running('/var/run/ruby_test_server.pid');

    list($status) = $running ? manage_http_get('http://127.0.0.1:30291/') : [0];

    manage_json([
        'ruby'        => $versions[0] ?? '',
        'rubygems'    => $versions[1] ?? '',
        'bundler'     => $versions[2] ?? '',
        'gems'        => $gems,
        'gems_path'   => $data_path,
        'test_server' => $running ? ($status === 200 ? 'running' : 'starting') : 'stopped',
    ]);
}

manage_require_action('ruby');

if ($action === 'restart') {
    manage_run(['/bin/sh', $app_path.'/stop.sh', $app_path]);

    list($code, $output) = manage_run(['/bin/sh', $app_path.'/start.sh', $app_path]);

    if ($code !== 0) {
        manage_fail(500, 'The test server could not be started: '.$output);
    }

    manage_json();
}

manage_fail(400, 'Unknown action');
