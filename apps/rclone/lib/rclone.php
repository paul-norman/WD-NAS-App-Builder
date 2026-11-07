<?php
require_once dirname(__DIR__).'/manage/manage_helpers.php';

// rclone's jobs and remotes. Used by the management page, and by rclone_ctl.sh through the NAS's PHP CLI (WD's PHP 7.4,
// or the PHP app's 8.5), so it must work on both:
//     php rclone.php due <data path> <hour>  - prints the IDs of the jobs to run at that hour (0-23), one per line
//     php rclone.php job <data path> <id>    - prints the job's mode, source and destination, one per line
const RCLONE_PORT = 5572;
const RCLONE_MODES = ['copy', 'sync'];

/**
 * The jobs (jobs.json, root's): each copies or syncs a source to a destination, at an hour of the day or only when run
 * from the page.
 *
 * @param string $data_path The app's data folder
 *
 * @return list<array{ id: string, name: string, mode: string, source: string, destination: string, hour: int }> The
 *         jobs (hour -1: only when run)
 */
function rclone_jobs(string $data_path): array
{
    $jobs = json_decode((string)@file_get_contents($data_path.'/jobs.json'), true);
    $list = [];

    foreach (is_array($jobs) ? $jobs : [] as $job) {
        if (is_array($job) && isset($job['id'], $job['name'], $job['mode'], $job['source'], $job['destination'], $job['hour'])) {
            $list[] = [
                'id'          => (string)$job['id'],
                'name'        => (string)$job['name'],
                'mode'        => (string)$job['mode'],
                'source'      => (string)$job['source'],
                'destination' => (string)$job['destination'],
                'hour'        => (int)$job['hour'],
            ];
        }
    }

    return $list;
}

/**
 * Saves the jobs (root's only).
 *
 * @param string                                                                                              $data_path The app's data folder
 * @param list<array{ id: string, name: string, mode: string, source: string, destination: string, hour: int }> $jobs      The jobs
 *
 * @return bool Whether they were saved
 */
function rclone_save_jobs(string $data_path, array $jobs): bool
{
    return manage_write_file($data_path.'/jobs.json', json_encode($jobs, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES)."\n");
}

/**
 * The remotes in rclone's config file (its sections), with their types.
 *
 * @param string $data_path The app's data folder
 *
 * @return array<string, string> Each remote's name and type (e.g. drive, s3)
 */
function rclone_remotes(string $data_path): array
{
    $remotes = [];
    $name    = '';

    foreach (@file($data_path.'/config/rclone.conf', FILE_IGNORE_NEW_LINES) ?: [] as $line) {
        if (preg_match('/^\[(.+)\]\s*$/', $line, $m)) {
            $name           = $m[1];
            $remotes[$name] = '';
        } elseif ($name !== '' && preg_match('/^\s*type\s*=\s*(\S+)/', $line, $m)) {
            $remotes[$name] = $m[1];
        }
    }

    return $remotes;
}

/**
 * Whether a folder on the NAS can be a job's source or destination: one in the shares, not the apps' folder (Nas_Prog:
 * apps' data, passwords included) or the volumes' system folders.
 *
 * @param string $path The folder
 *
 * @return string '' or the error
 */
function rclone_check_folder(string $path): string
{
    if (!preg_match('#^/mnt/(HD/HD_[a-z][0-9]+|USB/[^/]+)(/[^\x00-\x1f]*)?$#', $path) || preg_match('#/\.\.?(/|$)#', $path)) {
        return 'A folder on the NAS must be in its shares, e.g. /mnt/HD/HD_a2/Public/Photos';
    }

    if (!is_dir($path)) {
        return 'No such folder: '.$path;
    }

    // Where it really is, symbolic links followed
    $real = realpath($path);

    if ($real === false || !preg_match('#^/mnt/(HD/HD_[a-z][0-9]+|USB/[^/]+)/#', $real)) {
        return 'A folder on the NAS must be inside one of its shares, e.g. /mnt/HD/HD_a2/Public/Photos';
    }

    if (preg_match('#^/mnt/HD/HD_[a-z][0-9]+/(Nas_Prog|lost\+found|otaclient|restsdk-data|restsdk-info|\.[^/]*)(/|$)#', $real)) {
        return 'That folder holds the NAS\'s or its apps\' own files';
    }

    return '';
}

/**
 * Checks one end of a job: a folder in the NAS's shares, or a remote's path (remote:path, the remote set up in rclone).
 *
 * @param string                $place   What was given
 * @param array<string, string> $remotes The remotes set up
 *
 * @return string '' or the error
 */
function rclone_check_place(string $place, array $remotes): string
{
    if ($place === '' || preg_match('/[\x00-\x1f]/', $place)) {
        return 'Each job needs a source and a destination';
    }

    if ($place[0] === '/') {
        return rclone_check_folder(rtrim($place, '/'));
    }

    if (!preg_match('/^([^:\/]+):/', $place, $m) || !isset($remotes[$m[1]])) {
        return 'Not a folder on the NAS (/mnt/...) or a remote set up in rclone (name:path): '.$place;
    }

    return '';
}

/**
 * Adds a job, after checking it.
 *
 * @param string               $data_path The app's data folder
 * @param array<string, mixed> $input     The job: name, mode, source, destination, hour (-1 or 0-23)
 *
 * @return string '' or the error
 */
function rclone_add_job(string $data_path, array $input): string
{
    $name        = trim((string)($input['name'] ?? ''));
    $mode        = (string)($input['mode'] ?? '');
    $source      = trim((string)($input['source'] ?? ''));
    $destination = trim((string)($input['destination'] ?? ''));
    $hour        = (string)($input['hour'] ?? '');
    $remotes     = rclone_remotes($data_path);

    if (!preg_match('/^[^\x00-\x1f]{1,60}$/', $name)) {
        return 'Give the job a name (up to 60 characters)';
    }

    if (!in_array($mode, RCLONE_MODES, true)) {
        return 'A job copies or syncs';
    }

    foreach ([$source, $destination] as $place) {
        $error = rclone_check_place($place, $remotes);

        if ($error !== '') {
            return $error;
        }
    }

    if (rtrim($source, '/') === rtrim($destination, '/')) {
        return 'The source and the destination are the same';
    }

    if (!preg_match('/^(-1|[0-9]|1[0-9]|2[0-3])$/', $hour)) {
        return 'A job runs at an hour of the day (0-23), or only when run from this page';
    }

    $jobs   = rclone_jobs($data_path);
    $jobs[] = [
        'id'          => bin2hex(random_bytes(4)),
        'name'        => $name,
        'mode'        => $mode,
        'source'      => $source,
        'destination' => $destination,
        'hour'        => (int)$hour,
    ];

    return rclone_save_jobs($data_path, $jobs) ? '' : 'The job could not be saved';
}

/**
 * A job's last run (status/<id>.json, written by rclone_ctl.sh).
 *
 * @param string $data_path The app's data folder
 * @param string $id        The job's ID
 *
 * @return array<string, mixed> Its state (running, ok or failed), when it started and finished, or [] if never run
 */
function rclone_job_status(string $data_path, string $id): array
{
    $status = json_decode((string)@file_get_contents($data_path.'/status/'.$id.'.json'), true);

    return is_array($status) ? $status : [];
}

if (PHP_SAPI === 'cli' && isset($argv[0]) && realpath($argv[0]) === __FILE__) {
    $command = $argv[1] ?? '';

    if (!in_array($command, ['due', 'job'], true) || !isset($argv[3]) || !is_dir($argv[2])) {
        fwrite(STDERR, "Usage: php rclone.php due <data path> <hour> | job <data path> <id>\n");

        exit(2);
    }

    foreach (rclone_jobs($argv[2]) as $job) {
        if ($command === 'due' && $job['hour'] === (int)$argv[3] && $argv[3] !== '') {
            echo $job['id']."\n";
        }

        if ($command === 'job' && $job['id'] === $argv[3]) {
            echo $job['mode']."\n".$job['source']."\n".$job['destination']."\n";

            exit(0);
        }
    }

    exit($command === 'job' ? 1 : 0);
}
