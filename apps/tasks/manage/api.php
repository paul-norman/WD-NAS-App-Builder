<?php
// The Tasks app's management actions (JSON), for NAS admins only - see manage_helpers.php. Its tasks' scripts run as
// root, so every change is a POST with the page's CSRF token
require __DIR__.'/manage_helpers.php';

manage_require_admin('tasks');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path  = dirname(__DIR__);
$apps_path = dirname($app_path);
$data_path = $apps_path.'/_tasks';
$ctl       = $app_path.'/tasks_ctl.sh';

require $app_path.'/lib/tasks.php';

/**
 * A task's ID from the request, if it's one of the tasks.
 *
 * @param string $data_path The app's data folder
 *
 * @return string The ID (the request fails if it isn't a task's)
 */
function tasks_requested(string $data_path): string
{
    $id = isset($_POST['id']) ? (string)$_POST['id'] : '';

    if (tasks_find($data_path, $id) === null) {
        manage_fail(404, 'No such task');
    }

    return $id;
}

/**
 * Brings cron in step with the tasks, while the app is switched on (it schedules them when it starts).
 *
 * @param string $ctl The app's control script
 *
 * @return void
 */
function tasks_reschedule(string $ctl): void
{
    if (!is_file('/var/run/tasks.active')) {
        return;
    }

    list($code, $output) = manage_run(['/bin/sh', $ctl, 'schedule']);

    if ($code !== 0) {
        manage_fail(500, 'Saved, but the schedule could not be updated: '.$output);
    }
}

$action = $_GET['action'] ?? 'status';

if ($action === 'status') {
    $tasks = [];

    foreach (tasks_list($data_path) as $task) {
        $tasks[] = $task + ['status' => tasks_status($data_path, $task['id']), 'running' => tasks_running($task['id'])];
    }

    $history = @file($data_path.'/history.log', FILE_IGNORE_NEW_LINES) ?: [];

    manage_json([
        'active'  => is_file('/var/run/tasks.active'),
        'tasks'   => $tasks,
        'history' => array_reverse(array_slice($history, -30)),
        'ntfy'    => [
            'installed' => tasks_ntfy_token($data_path) !== '',
            'topic'     => tasks_settings($data_path)['topic'],
        ],
    ]);
}

// Everything else is a POST with the page's CSRF token (scripts can hold secrets: reading one is too)
manage_require_action('tasks');

if ($action === 'script') {
    $id = tasks_requested($data_path);

    manage_json(['script' => tasks_script($data_path, $id)]);
}

if ($action === 'save') {
    if (isset($_POST['id']) && $_POST['id'] !== '') {
        tasks_requested($data_path);
    }

    list($id, $error) = tasks_save_task($data_path, $_POST);

    if ($error !== '') {
        manage_fail(400, $error);
    }

    tasks_reschedule($ctl);
    manage_json(['id' => $id]);
}

if ($action === 'enable') {
    $id = tasks_requested($data_path);

    if (!tasks_enable($data_path, $id, isset($_POST['enabled']) && $_POST['enabled'] === '1')) {
        manage_fail(500, 'The task could not be saved');
    }

    tasks_reschedule($ctl);
    manage_json();
}

if ($action === 'delete') {
    $id = tasks_requested($data_path);

    if (tasks_running($id)) {
        manage_fail(409, 'The task is running: stop it first');
    }

    if (!tasks_delete($data_path, $id)) {
        manage_fail(500, 'The task could not be removed');
    }

    tasks_reschedule($ctl);
    manage_json();
}

if ($action === 'run') {
    $id = tasks_requested($data_path);

    if (tasks_running($id)) {
        manage_fail(409, 'The task is already running');
    }

    // In the background: a task can take hours (its status and output show how it went)
    manage_run(['/bin/sh', '-c', 'nohup /bin/sh "$0" run "$1" manual > /dev/null 2>&1 &', $ctl, $id]);
    manage_json();
}

if ($action === 'stop') {
    $id = tasks_requested($data_path);

    list($code) = manage_run(['/bin/sh', $ctl, 'kill', $id]);

    if ($code !== 0) {
        manage_fail(409, 'The task isn\'t running');
    }

    manage_json();
}

if ($action === 'output') {
    $id    = tasks_requested($data_path);
    $lines = @file($data_path.'/status/'.$id.'.log', FILE_IGNORE_NEW_LINES) ?: [];

    manage_json(['output' => array_slice($lines, -300), 'cut' => count($lines) > 300]);
}

if ($action === 'settings') {
    $topic = trim((string)($_POST['topic'] ?? ''));

    if (!tasks_valid_topic($topic)) {
        manage_fail(400, 'Topics are 1-64 letters, digits, _ and -');
    }

    if (!manage_write_file($data_path.'/settings.json', json_encode(['topic' => $topic], JSON_PRETTY_PRINT)."\n")) {
        manage_fail(500, 'The settings could not be saved');
    }

    manage_json();
}

manage_fail(400, 'Unknown action');
