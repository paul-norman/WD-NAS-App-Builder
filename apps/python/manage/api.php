<?php
// Python app management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('python');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path  = dirname(__DIR__);
$swap      = $app_path.'/python_swap.sh';
$wd_python = '/usr/local/modules/python39/bin/python3.9';

$action = $_GET['action'] ?? 'status';

if ($action === 'status') {
    $target = (string)@realpath('/usr/bin/python3');

    list(, $active) = manage_run(['/usr/bin/python3', '--version']);
    list(, $app)    = manage_run([$app_path.'/binaries/python/bin/python3', '--version']);
    list(, $wd)     = manage_run([$wd_python, '--version']);
    list(, $uv)     = manage_run([$app_path.'/binaries/python/bin/uv', '--version']);
    list(, $pip)    = manage_run([$app_path.'/binaries/python/bin/python3', '-m', 'pip', '--version']);

    // The Python wsdd (Windows network discovery) runs on: WD starts it at boot, before the apps
    $wsdd = '';

    foreach (glob('/proc/[0-9]*/cmdline') ?: [] as $file) {
        $args = explode("\0", (string)@file_get_contents($file));

        if (isset($args[1]) && basename($args[1]) === 'wsdd') {
            $wsdd = (string)@readlink(dirname($file).'/exe');

            break;
        }
    }

    manage_json([
        'app_active'  => strpos($target, $app_path.'/') === 0,
        'active'      => $active,
        'active_path' => $target,
        'app_version' => $app,
        'wd_version'  => $wd,
        'uv'          => $uv,
        'pip'         => preg_match('/^(pip \S+)/', $pip, $m) ? $m[1] : '',
        'wsdd'        => $wsdd,
        'links'       => array_values(array_filter(['python3', 'python3.14', 'pip3', 'pip3.14', 'pydoc3', 'uv', 'uvx'], function (string $name) use ($app_path): bool {
            return strpos((string)@readlink('/usr/bin/'.$name), $app_path.'/') === 0;
        })),
    ]);
}

manage_require_action('python');

if ($action === 'use') {
    $which = isset($_POST['python']) && $_POST['python'] === 'wd' ? 'restore' : 'swap';

    list($code, $output) = manage_run(['/bin/sh', $swap, $which]);

    if ($code !== 0) {
        manage_fail(500, 'Could not switch: '.$output);
    }

    manage_json();
}

manage_fail(400, 'Unknown action');
