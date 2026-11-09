<?php
require_once dirname(__DIR__).'/manage/manage_helpers.php';

// The tasks: their settings (tasks.json), scripts (scripts/<id>.sh) and last runs (status/<id>.json and .log, written
// by tasks_ctl.sh). Used by the management page, and by tasks_ctl.sh through the NAS's PHP CLI (WD's PHP 7.4, or the
// PHP app's 8.5), so it must work on both:
//     php tasks.php ids <data path> <trigger>      - the IDs of the switched-on tasks with that trigger, one per line
//     php tasks.php cron <data path>               - each switched-on scheduled task: its ID, a tab, its schedule
//     php tasks.php field <data path> <id> <field> - one of a task's settings (name, timeout...)
//     php tasks.php seed <data path> <examples>    - the example tasks (switched off), when there are no tasks yet
//     php tasks.php notify <data path> <id>        - tells the ntfy app's topic how the task's last run went, if asked
const TASKS_TRIGGERS     = ['boot', 'schedule', 'shutdown', 'manual'];
const TASKS_NOTIFY       = ['never', 'failed', 'always'];
const TASKS_SCRIPT_BYTES = 65536;

/**
 * The tasks (tasks.json, root's), in the order they run in.
 *
 * @param string $data_path The app's data folder
 *
 * @return list<array{ id: string, name: string, trigger: string, schedule: string, enabled: bool, timeout: int, notify: string }>
 *         The tasks (timeout in minutes)
 */
function tasks_list(string $data_path): array
{
    $tasks = json_decode((string)@file_get_contents($data_path.'/tasks.json'), true);
    $list  = [];

    foreach (is_array($tasks) ? $tasks : [] as $task) {
        if (!is_array($task) || !isset($task['id'], $task['name']) || !preg_match('/^[0-9a-f]{8}$/', (string)$task['id'])) {
            continue;
        }

        $list[] = [
            'id'       => (string)$task['id'],
            'name'     => (string)$task['name'],
            'trigger'  => in_array($task['trigger'] ?? '', TASKS_TRIGGERS, true) ? $task['trigger'] : 'manual',
            'schedule' => (string)($task['schedule'] ?? ''),
            'enabled'  => !empty($task['enabled']),
            'timeout'  => max(1, min(1440, (int)($task['timeout'] ?? 30))),
            'notify'   => in_array($task['notify'] ?? '', TASKS_NOTIFY, true) ? $task['notify'] : 'never',
        ];
    }

    return $list;
}

/**
 * Saves the tasks (root's only).
 *
 * @param string                     $data_path The app's data folder
 * @param list<array<string, mixed>> $tasks     The tasks
 *
 * @return bool Whether they were saved
 */
function tasks_save(string $data_path, array $tasks): bool
{
    return manage_write_file($data_path.'/tasks.json', json_encode(array_values($tasks), JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES)."\n");
}

/**
 * One of the tasks.
 *
 * @param string $data_path The app's data folder
 * @param string $id        Its ID
 *
 * @return array<string, mixed>|null The task, or null if there's no such task
 */
function tasks_find(string $data_path, string $id): ?array
{
    foreach (tasks_list($data_path) as $task) {
        if ($task['id'] === $id) {
            return $task;
        }
    }

    return null;
}

/**
 * A task's script (scripts/<id>.sh).
 *
 * @param string $data_path The app's data folder
 * @param string $id        The task's ID
 *
 * @return string The script ('' if it has none)
 */
function tasks_script(string $data_path, string $id): string
{
    return (string)@file_get_contents($data_path.'/scripts/'.$id.'.sh');
}

/**
 * Checks one field of a schedule: *, a number, a range, or a list of them, each with an optional step (e.g. 0, 1-5,
 * star-slash-15, 0,30).
 *
 * @param string $field The field
 * @param int    $min   Its smallest value
 * @param int    $max   Its largest value
 *
 * @return bool Whether it's valid
 */
function tasks_check_field(string $field, int $min, int $max): bool
{
    foreach (explode(',', $field) as $item) {
        if (!preg_match('/^(\*|([0-9]{1,2})(-([0-9]{1,2}))?)(\/([0-9]{1,2}))?$/', $item, $m)) {
            return false;
        }

        if (isset($m[2]) && $m[2] !== '') {
            $from = (int)$m[2];
            $to   = isset($m[4]) && $m[4] !== '' ? (int)$m[4] : $from;

            if ($from < $min || $to > $max || $from > $to) {
                return false;
            }
        }

        if (isset($m[6]) && ((int)$m[6] < 1 || (int)$m[6] > $max)) {
            return false;
        }
    }

    return true;
}

/**
 * Checks a schedule: cron's five fields (minute, hour, day of the month, month, day of the week), in numbers.
 *
 * @param string $schedule The schedule (e.g. 30 2 * * *)
 *
 * @return string '' or the error
 */
function tasks_check_schedule(string $schedule): string
{
    $fields = preg_split('/\s+/', trim($schedule));
    $ranges = [[0, 59, 'minute'], [0, 23, 'hour'], [1, 31, 'day of the month'], [1, 12, 'month'], [0, 6, 'day of the week (0 is Sunday)']];

    if (count($fields) !== 5) {
        return 'A schedule has five parts: minute, hour, day of the month, month and day of the week (e.g. 30 2 * * *)';
    }

    foreach ($fields as $i => $field) {
        if (!tasks_check_field($field, $ranges[$i][0], $ranges[$i][1])) {
            return 'The schedule\'s '.$ranges[$i][2].' isn\'t valid: '.$field.' (from '.$ranges[$i][0].' to '.$ranges[$i][1].')';
        }
    }

    return '';
}

/**
 * Adds a task, or changes one, after checking it - and saves its script.
 *
 * @param string               $data_path The app's data folder
 * @param array<string, mixed> $input     The task: id ('' for a new one), name, trigger, schedule, enabled, timeout,
 *                                        notify, script
 *
 * @return array{ 0: string, 1: string } Its ID, and '' or the error
 */
function tasks_save_task(string $data_path, array $input): array
{
    $id       = (string)($input['id'] ?? '');
    $name     = trim((string)($input['name'] ?? ''));
    $trigger  = (string)($input['trigger'] ?? '');
    $schedule = preg_replace('/\s+/', ' ', trim((string)($input['schedule'] ?? '')));
    $timeout  = (string)($input['timeout'] ?? '');
    $notify   = (string)($input['notify'] ?? 'never');
    // Browsers send a text box's lines ending in CR LF: the shell would see the CRs
    $script   = str_replace(["\r\n", "\r"], "\n", (string)($input['script'] ?? ''));
    $tasks    = tasks_list($data_path);

    if (!preg_match('/^[^\x00-\x1f]{1,60}$/u', $name)) {
        return [$id, 'Give the task a name (up to 60 characters)'];
    }

    if (!in_array($trigger, TASKS_TRIGGERS, true)) {
        return [$id, 'A task runs at boot, on a schedule, at shutdown or only when run from this page'];
    }

    if ($trigger === 'schedule') {
        $error = tasks_check_schedule($schedule);

        if ($error !== '') {
            return [$id, $error];
        }
    } else {
        $schedule = '';
    }

    if (!preg_match('/^[0-9]{1,4}$/', $timeout) || (int)$timeout < 1 || (int)$timeout > 1440) {
        return [$id, 'A task can run for 1 to 1440 minutes (a day) before it\'s stopped'];
    }

    if (!in_array($notify, TASKS_NOTIFY, true)) {
        return [$id, 'Unknown notification setting'];
    }

    if (trim($script) === '') {
        return [$id, 'The task needs a script'];
    }

    if (strlen($script) > TASKS_SCRIPT_BYTES) {
        return [$id, 'The script is too long (up to 64 KB)'];
    }

    if (strpos($script, "\0") !== false) {
        return [$id, 'The script isn\'t text'];
    }

    $task = [
        'id'       => $id,
        'name'     => $name,
        'trigger'  => $trigger,
        'schedule' => $schedule,
        'enabled'  => !empty($input['enabled']) && $input['enabled'] !== '0' && $input['enabled'] !== 'false',
        'timeout'  => (int)$timeout,
        'notify'   => $notify,
    ];
    $found = false;

    foreach ($tasks as $i => $existing) {
        if ($id !== '' && $existing['id'] === $id) {
            $tasks[$i] = $task;
            $found     = true;
        }
    }

    if ($id !== '' && !$found) {
        return [$id, 'No such task'];
    }

    if (!$found) {
        $id         = bin2hex(random_bytes(4));
        $task['id'] = $id;
        $tasks[]    = $task;
    }

    $scripts = $data_path.'/scripts';

    if (!is_dir($scripts) && !@mkdir($scripts, 0700, true)) {
        return [$id, 'The scripts folder could not be made'];
    }

    $file = $scripts.'/'.$id.'.sh';

    if (!manage_write_file($file, rtrim($script, "\n")."\n") || !chmod($file, 0700)) {
        return [$id, 'The script could not be saved'];
    }

    return [$id, tasks_save($data_path, $tasks) ? '' : 'The task could not be saved'];
}

/**
 * Switches a task on or off.
 *
 * @param string $data_path The app's data folder
 * @param string $id        The task's ID
 * @param bool   $enabled   Whether it's on
 *
 * @return bool Whether it was saved
 */
function tasks_enable(string $data_path, string $id, bool $enabled): bool
{
    $tasks = tasks_list($data_path);

    foreach ($tasks as $i => $task) {
        if ($task['id'] === $id) {
            $tasks[$i]['enabled'] = $enabled;
        }
    }

    return tasks_save($data_path, $tasks);
}

/**
 * Removes a task, its script and its last run.
 *
 * @param string $data_path The app's data folder
 * @param string $id        The task's ID
 *
 * @return bool Whether it was removed
 */
function tasks_delete(string $data_path, string $id): bool
{
    $tasks = array_filter(tasks_list($data_path), function (array $task) use ($id): bool {
        return $task['id'] !== $id;
    });

    if (!tasks_save($data_path, $tasks)) {
        return false;
    }

    foreach ([$data_path.'/scripts/'.$id.'.sh', $data_path.'/status/'.$id.'.json', $data_path.'/status/'.$id.'.log'] as $file) {
        @unlink($file);
    }

    return true;
}

/**
 * Whether a task is running now (its lock, made by tasks_ctl.sh, with its process alive).
 *
 * @param string $id The task's ID
 *
 * @return bool Whether it's running
 */
function tasks_running(string $id): bool
{
    $pid = (int)@file_get_contents('/var/run/tasks-'.$id.'.lock/pid');

    return $pid > 0 && is_dir('/proc/'.$pid);
}

/**
 * A task's last run (status/<id>.json, written by tasks_ctl.sh).
 *
 * @param string $data_path The app's data folder
 * @param string $id        The task's ID
 *
 * @return array<string, mixed> Its state (running, ok, failed, timeout or interrupted), why it ran, when it started and
 *                              finished (seconds since 1970) and its exit code - or [] if it's never run
 */
function tasks_status(string $data_path, string $id): array
{
    $status = json_decode((string)@file_get_contents($data_path.'/status/'.$id.'.json'), true);

    if (!is_array($status)) {
        return [];
    }

    // A run that never finished (the NAS restarted, or it was killed) has no live lock
    if (($status['state'] ?? '') === 'running' && !tasks_running($id)) {
        $status['state'] = 'interrupted';
    }

    return $status;
}

/**
 * The app's settings (settings.json): the ntfy topic told about tasks' runs.
 *
 * @param string $data_path The app's data folder
 *
 * @return array{ topic: string } The settings
 */
function tasks_settings(string $data_path): array
{
    $settings = json_decode((string)@file_get_contents($data_path.'/settings.json'), true);
    $topic    = is_array($settings) && isset($settings['topic']) ? (string)$settings['topic'] : '';

    return ['topic' => tasks_valid_topic($topic) ? $topic : ''];
}

/**
 * Whether a string is an ntfy topic: 1-64 letters, digits, _ and - ('' is no topic).
 *
 * @param string $topic The topic
 *
 * @return bool Whether it's valid
 */
function tasks_valid_topic(string $topic): bool
{
    return $topic === '' || preg_match('/^[A-Za-z0-9_-]{1,64}$/', $topic) === 1;
}

/**
 * The ntfy app's token, when it's installed (Nas_Prog/ntfy, its token in Nas_Prog/_ntfy/token).
 *
 * @param string $data_path The app's data folder
 *
 * @return string The token ('' when the ntfy app isn't installed)
 */
function tasks_ntfy_token(string $data_path): string
{
    $apps = dirname($data_path);

    return is_dir($apps.'/ntfy') ? trim((string)@file_get_contents($apps.'/_ntfy/token')) : '';
}

/**
 * Tells the ntfy app's topic how a task's last run went, if the task asks for that (always, or when it fails).
 *
 * @param string $data_path The app's data folder
 * @param string $id        The task's ID
 *
 * @return bool Whether a message was sent
 */
function tasks_notify(string $data_path, string $id): bool
{
    $task   = tasks_find($data_path, $id);
    $status = tasks_status($data_path, $id);
    $topic  = tasks_settings($data_path)['topic'];
    $token  = tasks_ntfy_token($data_path);

    if ($task === null || !isset($status['state']) || $topic === '' || $token === '') {
        return false;
    }

    $good = $status['state'] === 'ok';

    if ($task['notify'] === 'never' || ($task['notify'] === 'failed' && $good)) {
        return false;
    }

    $seconds = max(0, (int)($status['finished'] ?? 0) - (int)($status['started'] ?? 0));
    $states  = [
        'ok'      => 'done in '.$seconds.' s',
        'failed'  => 'failed (exit code '.(int)($status['code'] ?? 0).') after '.$seconds.' s',
        'timeout' => 'stopped after '.$task['timeout'].' minutes (its time limit)',
    ];
    $lines   = @file($data_path.'/status/'.$id.'.log', FILE_IGNORE_NEW_LINES) ?: [];
    $body    = ucfirst($states[$status['state']] ?? $status['state']).' ('.($status['reason'] ?? 'run').')';

    if ($lines) {
        $body .= ":\n".implode("\n", array_slice($lines, -10));
    }

    list($code) = manage_run(['curl', '-sS', '-f', '--max-time', '10', '-H', 'Authorization: Bearer '.$token,
        '-H', 'Title: Tasks: '.$task['name'], '-H', 'Tags: '.($good ? 'white_check_mark' : 'warning'),
        '--data-binary', '@-', 'http://127.0.0.1:2586/'.$topic], [], $body);

    return $code === 0;
}

/**
 * Adds the example tasks (switched off) when there are no tasks yet (no tasks.json): examples/examples.json lists them,
 * each with its script's file.
 *
 * @param string $data_path The app's data folder
 * @param string $examples  The examples' folder
 *
 * @return void
 */
function tasks_seed(string $data_path, string $examples): void
{
    if (is_file($data_path.'/tasks.json')) {
        return;
    }

    $list = json_decode((string)@file_get_contents($examples.'/examples.json'), true);

    tasks_save($data_path, []);

    foreach (is_array($list) ? $list : [] as $example) {
        $script = (string)@file_get_contents($examples.'/'.basename((string)($example['file'] ?? '')));

        if ($script !== '') {
            tasks_save_task($data_path, ['script' => $script, 'enabled' => false] + $example);
        }
    }
}

if (PHP_SAPI === 'cli' && isset($argv[0]) && realpath($argv[0]) === __FILE__) {
    $command = $argv[1] ?? '';
    $data    = $argv[2] ?? '';
    $usage   = "Usage: php tasks.php ids <data path> <trigger> | cron <data path> | field <data path> <id> <field>"
        ." | seed <data path> <examples> | notify <data path> <id>\n";

    if (!in_array($command, ['ids', 'cron', 'field', 'seed', 'notify'], true) || !is_dir($data)) {
        fwrite(STDERR, $usage);

        exit(2);
    }

    if ($command === 'seed') {
        tasks_seed($data, $argv[3] ?? '');

        exit(0);
    }

    if ($command === 'notify') {
        exit(tasks_notify($data, $argv[3] ?? '') ? 0 : 1);
    }

    foreach (tasks_list($data) as $task) {
        if ($command === 'ids' && $task['enabled'] && $task['trigger'] === ($argv[3] ?? '')) {
            echo $task['id']."\n";
        }

        if ($command === 'cron' && $task['enabled'] && $task['trigger'] === 'schedule' && tasks_check_schedule($task['schedule']) === '') {
            echo $task['id']."\t".$task['schedule']."\n";
        }

        if ($command === 'field' && $task['id'] === ($argv[3] ?? '') && isset($task[$argv[4] ?? ''])) {
            echo is_bool($task[$argv[4]]) ? ($task[$argv[4]] ? '1' : '0') : $task[$argv[4]];
            echo "\n";

            exit(0);
        }
    }

    exit($command === 'field' ? 1 : 0);
}
