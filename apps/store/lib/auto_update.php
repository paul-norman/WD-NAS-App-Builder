<?php
// The nightly automatic updates (from root's crontab at 04:30 - see init.sh): updates the apps and recipes ticked
// "Update automatically" on their pages, as a job (job.php's auto_update), so the page's Activity tab shows its log.
// Nothing is started when none of them has a newer version: what was found is only recorded. Run with the NAS's PHP
// CLI:
//     php auto_update.php
require __DIR__.'/store.php';

if (PHP_SAPI !== 'cli') {
    exit(1);
}

$settings = store_auto_settings();

if (!$settings['apps'] && !$settings['recipes']) {
    exit(0);
}

// The daily check (04:25) has normally just run: only if it didn't
if (store_repos_stale(store_repos_loaded())) {
    foreach (store_refresh_all() as $url => $error) {
        fwrite(STDERR, $url.': '.$error."\n");
    }
}

$plan    = store_auto_plan();
$pending = array_filter($plan, function (array $item): bool {
    return $item['state'] === 'update';
});

if (!$pending) {
    store_auto_record(array_map(function (array $item): array {
        return $item + ['message' => ''];
    }, $plan));

    exit(0);
}

// One job at a time: an install started from the page goes first (waited for up to an hour)
$jobs = store_data_path().'/jobs';

store_mkdir($jobs);

// Close-on-exec (e): the programs it starts mustn't inherit the lock (see job.php)
$lock = fopen($jobs.'/lock', 'ce');

for ($i = 0; $i < 60 && $lock && !flock($lock, LOCK_EX | LOCK_NB); $i++) {
    sleep(60);
}

if (!$lock || $i === 60) {
    fwrite(STDERR, "Another job is still running - the automatic updates will be tried tomorrow\n");

    exit(1);
}

flock($lock, LOCK_UN);
fclose($lock);

$spec = [
    'id'     => bin2hex(random_bytes(8)),
    'action' => 'auto_update',
    'target' => '',
    'title'  => 'Automatic updates ('.count($pending).' to install)',
];
$file = $jobs.'/job-'.$spec['id'].'.json';

if (!store_write_json($file, $spec)) {
    exit(1);
}

@unlink($jobs.'/status.json');

$env = ['PATH' => '/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin', 'HOME' => getenv('HOME') ?: '/root'];

if (getenv('STORE_TEST_VOLUME')) {
    $env['STORE_TEST_VOLUME'] = getenv('STORE_TEST_VOLUME');
}

// Waited for: the job runs in this process's place (it carries on if the Store updates itself)
list($code) = store_run([PHP_BINARY, __DIR__.'/job.php', $file], $env);

exit($code === 0 ? 0 : 1);
