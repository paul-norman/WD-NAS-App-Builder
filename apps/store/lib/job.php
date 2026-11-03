<?php
// The Store's background jobs - installs, updates and removals, which take minutes (downloads, WD's installer, docker
// compose). Started by api.php, detached from the web request:
//     php job.php <job file>
// The job file (root-only, deleted once read) holds the action and its arguments, including the wizard's answers. One
// job runs at a time; its progress goes to jobs/job.log and its state to jobs/status.json, which the page follows.
// Everything is loaded before the job starts, so it can finish even if it removes the Store's own files (e.g. its
// own update).

require __DIR__.'/store.php';

if (PHP_SAPI !== 'cli' || !isset($argv[1])) {
    exit(1);
}

$jobs = store_data_path().'/jobs';
$spec = store_read_json($argv[1]);

@unlink($argv[1]);

if ($spec === null) {
    exit(1);
}

$lock = fopen($jobs.'/lock', 'c');

if (!$lock || !flock($lock, LOCK_EX | LOCK_NB)) {
    exit(1);
}

ignore_user_abort(true);
set_time_limit(0);
umask(022);

$GLOBALS['job_log'] = fopen($jobs.'/job.log', 'w');

chmod($jobs.'/job.log', 0600);

$status = [
    'id'       => $spec['id'],
    'action'   => $spec['action'],
    'target'   => $spec['target'] ?? '',
    'title'    => $spec['title'],
    'state'    => 'running',
    'started'  => store_now(),
    'finished' => '',
    'pid'      => getmypid(),
    'message'  => '',
];

store_write_json($jobs.'/status.json', $status);

/**
 * Adds a line to the job's log (jobs/job.log, which the page shows), with the time.
 *
 * @param string $message The line
 *
 * @return void
 */
function job_log(string $message): void
{
    fwrite($GLOBALS['job_log'], '['.date('H:i:s').'] '.$message."\n");
    fflush($GLOBALS['job_log']);
}

/**
 * Thrown to stop a job: its message is the job's outcome, shown on the page.
 */
class JobFailed extends Exception
{
}

// PHP's own warnings go into the job's log too (the job has no other output)
set_error_handler(function ($level, $message, $file, $line) {
    // Not those silenced with @
    if (!(error_reporting() & $level)) {
        return true;
    }

    job_log('PHP warning: '.$message.' ('.basename($file).':'.$line.')');

    return true;
});

/**
 * Stops the job, with why.
 *
 * @param string $message Why it failed, as the page shows it
 *
 * @return never
 *
 * @throws JobFailed Always
 */
function job_fail(string $message): void
{
    throw new JobFailed($message);
}

/**
 * Runs a command, copying its output into the job's log as it comes - only the last state of lines rewritten with
 * carriage returns (progress bars), and without the noise of WD's installer's OpenSSL warnings and Docker's progress
 * for each layer of an image.
 *
 * @param list<string>          $command The program and its arguments
 * @param array<string, string> $env     Extra environment variables (PATH and HOME are set unless given)
 * @param string|null           $cwd     The working folder, or null for the current one
 *
 * @return int Its exit code (-1 if it couldn't be run)
 */
function job_run(array $command, array $env = [], ?string $cwd = null): int
{
    $env    += ['PATH' => '/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin', 'HOME' => getenv('HOME') ?: '/root'];
    $process = @proc_open($command, [0 => ['file', '/dev/null', 'r'], 1 => ['pipe', 'w'], 2 => ['redirect', 1]], $pipes, $cwd, $env);

    if (!is_resource($process)) {
        job_log('Could not run: '.$command[0]);

        return -1;
    }

    while (($line = fgets($pipes[1])) !== false) {
        // Progress bars rewrite their line with carriage returns: only the last state of each line is kept
        $parts = explode("\r", rtrim($line, "\n"));
        $line  = trim(end($parts));

        // WD's installer decrypts packages with an old OpenSSL key derivation, and OpenSSL says so - harmless
        if (strpos($line, 'deprecated key derivation') !== false || strpos($line, 'Using -iter or -pbkdf2') !== false) {
            continue;
        }

        // Docker's progress for each layer of an image - thousands of lines for a stack: each image's "Pulling" and
        // "Pulled", and any errors, are kept
        if (preg_match('/^[0-9a-f]{12} (Waiting|Pulling fs layer|Downloading|Extracting|Verifying Checksum|Download complete|Pull complete|Already exists)\b/', $line)) {
            continue;
        }

        if ($line !== '') {
            fwrite($GLOBALS['job_log'], '    '.$line."\n");
            fflush($GLOBALS['job_log']);
        }
    }

    fclose($pipes[1]);

    return proc_close($process);
}

/**
 * Downloads an app's package with curl, logging its progress every 5 seconds, then checks its size and SHA256 (removing
 * it if either is wrong). It may take 10 minutes, or as long as 100KB/s needs.
 *
 * @param string       $url    The package's HTTPS URL
 * @param string       $file   Where to save it
 * @param positive-int $size   Its size in bytes, from the catalogue
 * @param string       $sha256 Its SHA256, from the catalogue
 *
 * @return void
 *
 * @throws JobFailed When it can't be downloaded, or isn't what the catalogue says
 */
function job_download_package(string $url, string $file, int $size, string $sha256): void
{
    if (!store_is_https_url($url)) {
        job_fail('Not an HTTPS address: '.$url);
    }

    @unlink($file);

    // At least 100KB/s, and never less than 10 minutes
    $timeout = max(600, (int)($size / 102400));
    $command = ['curl', '-sS', '-f', '-L', '--proto', '=https', '--proto-redir', '=https', '--max-redirs', '5',
        '--connect-timeout', '15', '-m', (string)$timeout, '--max-filesize', (string)$size, '-A', 'WD-NAS-Store/1', '-o', $file, $url];
    $env     = ['PATH' => '/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin', 'HOME' => getenv('HOME') ?: '/root'];
    $process = @proc_open($command, [0 => ['file', '/dev/null', 'r'], 1 => ['pipe', 'w'], 2 => ['redirect', 1]], $pipes, null, $env);

    if (!is_resource($process)) {
        job_fail('Could not run curl');
    }

    stream_set_blocking($pipes[1], false);

    $output = '';
    $last   = 0;

    while (true) {
        $state   = proc_get_status($process);
        $output .= (string)stream_get_contents($pipes[1]);

        if (!$state['running']) {
            break;
        }

        if (time() - $last >= 5) {
            clearstatcache();

            $done = is_file($file) ? filesize($file) : 0;

            job_log('Downloaded '.store_size($done).' of '.store_size($size));

            $last = time();
        }

        usleep(250000);
    }

    $output .= (string)stream_get_contents($pipes[1]);

    fclose($pipes[1]);
    proc_close($process);

    $code = $state['exitcode'];

    if ($code !== 0) {
        @unlink($file);
        job_fail('The download failed: '.(trim($output) !== '' ? trim($output) : 'curl exit code '.$code));
    }

    clearstatcache();

    if (filesize($file) !== $size) {
        @unlink($file);
        job_fail('The download isn\'t the expected size - it may have been changed');
    }

    if (!hash_equals($sha256, hash_file('sha256', $file))) {
        @unlink($file);
        job_fail('The download doesn\'t match its checksum - it may have been changed');
    }

    job_log('Downloaded and checked ('.store_size($size).', SHA256 matches)');
}

/**
 * An app's name, from the catalogue, for messages.
 *
 * @param mixed $id The app's id
 *
 * @return mixed Its name, or its id if no repository lists it
 */
function job_app_label($id)
{
    foreach (store_repos_loaded() as $repo) {
        foreach ($repo['store'] !== null && isset($repo['store']['apps']) ? $repo['store']['apps'] : [] as $app) {
            if (isset($app['id']) && $app['id'] === $id) {
                return $app['name'];
            }
        }
    }

    return $id;
}

/**
 * Checks requirements before installing (see store_check_requires()): warnings go in the log, and the first error stops
 * the job.
 *
 * @param mixed $requires The requirements, from the catalogue or recipe.json
 *
 * @return void
 *
 * @throws JobFailed When a requirement isn't met
 */
function job_requires($requires): void
{
    $problems = store_check_requires($requires, 'job_app_label');

    foreach ($problems as $problem) {
        if ($problem['level'] === 'warning') {
            job_log('Warning: '.$problem['message']);
        }
    }

    foreach ($problems as $problem) {
        if ($problem['level'] === 'error') {
            job_fail($problem['message']);
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------------
// Native apps

/**
 * Installs or updates a native app with the NAS's own installer (upload_apkg), as the dashboard does: its package
 * downloaded and checked, the installed version removed first on an update (its data folder stays) - and put back and
 * started if the new one doesn't install.
 *
 * @param array<string, mixed> $spec   The job: the repository (repo) and the app's id (target)
 * @param bool                 $update Whether it's an update of an installed app
 *
 * @return string The outcome, for the page
 *
 * @throws JobFailed When it can't be installed
 */
function job_app_install(array $spec, bool $update): string
{
    list($repo, $app) = store_find('apps', $spec['repo'], $spec['target']);

    if ($app === null) {
        job_fail('The app isn\'t in that repository any more - refresh the repositories');
    }

    $id        = $app['id'];
    $nas       = store_nas();
    $installed = isset($nas['apps'][$id]);

    if ($update && !$installed) {
        job_fail($app['name'].' isn\'t installed');
    }

    if (!$update && $installed) {
        job_fail($app['name'].' is already installed');
    }

    if ($update && empty($app['keeps_data'])) {
        job_fail($app['name'].' can\'t be updated by the Store (it would lose its settings) - update it by hand');
    }

    if ($id === 'store' && !$update) {
        job_fail('The Store is already installed');
    }

    $package = null;

    foreach ($app['packages'] as $candidate) {
        if ($candidate['model'] === $nas['model']) {
            $package = $candidate;
        }
    }

    if ($package === null) {
        job_fail($app['name'].' has no package for this NAS ('.($nas['model'] ?: 'unknown model').')');
    }

    job_requires($app['requires'] ?? []);

    $url = store_resolve_url($package['url'], $repo['base']);

    if ($url === '') {
        job_fail('The package\'s address isn\'t allowed');
    }

    if ($nas['disk_mb'] * 1048576 < $package['size'] * 2 + (100 << 20)) {
        job_fail('There isn\'t enough free space for the package');
    }

    job_log('Downloading '.$app['name'].' '.$app['version'].' for '.$nas['model'].' ('.store_size($package['size']).')');
    store_mkdir(STORE_UPLOAD_PATH, 0755);

    $temp = STORE_UPLOAD_PATH.'/.store-download.part';

    job_download_package($url, $temp, $package['size'], $package['sha256']);

    $name = preg_replace('/[^A-Za-z0-9._-]/', '_', "{$id}_{$app['version']}_{$nas['model']}.bin");

    if (!rename($temp, STORE_UPLOAD_PATH.'/'.$name)) {
        job_fail('Could not prepare the package');
    }

    // The app's files as they are, put back (and started) if the new version doesn't install: kept as hard links (the
    // same volume - nothing copied), as removing the old version only deletes their names
    $folder   = store_apps_path().'/'.$id;
    $previous = store_data_path().'/previous/'.$id;
    $kept     = false;

    try {
        store_rmtree($previous);
        store_mkdir(dirname($previous));

        if ($update) {
            $kept = is_dir($folder) && job_run(['cp', '-al', $folder, $previous]) === 0;

            if (!$kept) {
                job_log('Warning: could not keep a copy of the installed version, to put back if the new one doesn\'t install');
            }

            job_log('Removing the installed version ('.$nas['apps'][$id]['version'].') - its data folder stays');
            job_run(['del_apkg', $id]);

            for ($i = 0; $i < 120 && isset(store_installed_apps()[$id]); $i++) {
                sleep(1);
            }

            if (isset(store_installed_apps()[$id])) {
                job_fail('The installed version could not be removed');
            }
        } elseif (is_dir($folder)) {
            // Its files without the NAS knowing it's installed - e.g. put back after an update that failed, until the
            // NAS restarts: WD's installer can't install over them
            job_log('Its files are already in Nas_Prog/'.$id.', but the NAS doesn\'t list it as installed: stopping them and setting them aside');

            if (is_file($folder.'/stop.sh')) {
                job_run(['sh', $folder.'/stop.sh', $folder]);
            }

            $kept = rename($folder, $previous);

            if (!$kept) {
                job_fail('Could not set aside the files in Nas_Prog/'.$id);
            }
        }

        job_log('Installing with the NAS\'s own installer');
        @unlink('/tmp/upload_apkg_status');

        $debug_size = (int)@filesize('/tmp/debug_apkg');

        job_run(['upload_apkg', '-m', '-p', $name, '-t', '2'], [], STORE_UPLOAD_PATH);

        $result = trim((string)@file_get_contents('/tmp/upload_apkg_status'));

        if ($result === '4') {
            job_fail('The NAS says it\'s already installed');
        }

        if ($result !== '1') {
            job_installer_log($debug_size);
            job_fail('The NAS\'s installer failed: '.job_installer_reason($result).($kept ? job_put_back($id, $folder, $previous) : ''));
        }
    } finally {
        @unlink(STORE_UPLOAD_PATH.'/'.$name);
    }

    store_rmtree($previous);
    store_record_app($id, $repo['url'], $app['version']);

    $apps = store_installed_apps();

    // Unless WD's list says it's switched off - the NAS starts apps once they're installed; its list can lag
    $ready = (isset($apps[$id]) && $apps[$id]['enabled'] === false) || job_wait_web($app['web'] ?? null, 'its page in the NAS dashboard, and /tmp/debug_apkg');

    return $app['name'].' '.(isset($apps[$id]) ? $apps[$id]['version'] : $app['version']).($ready ? ' is installed' : ' is installed but still starting')
       .(!empty($app['data_folder']) && $update ? ' (its data in '.$app['data_folder'].' was kept)' : '');
}

/**
 * Removes a native app with the NAS's own uninstaller (del_apkg). Its data folder stays. The Store can remove itself:
 * this job's code is already loaded, and its log is in the Store's data folder.
 *
 * @param array<string, mixed> $spec The job: the app's id (target)
 *
 * @return string The outcome, for the page
 *
 * @throws JobFailed When it isn't installed, or isn't removed
 */
function job_app_uninstall(array $spec): string
{
    $id   = $spec['target'];
    $apps = store_installed_apps();

    if (!isset($apps[$id])) {
        job_fail('It isn\'t installed');
    }

    // The Store can remove itself: this job's code is already loaded, and its log is in the Store's data folder, which
    // stays - the NAS's own Apps page comes back as the Store stops
    job_log('Removing '.($apps[$id]['name'] ?: $id).' with the NAS\'s own uninstaller'
       .($id === 'store' ? ' - everything it installed stays installed, and the NAS\'s own Apps page comes back' : ''));
    job_run(['del_apkg', $id]);

    for ($i = 0; $i < 120 && isset(store_installed_apps()[$id]); $i++) {
        sleep(1);
    }

    if (isset(store_installed_apps()[$id])) {
        job_fail('It could not be removed');
    }

    store_record_app($id, null, null);

    $folder = store_apps_path().'/_'.$id;

    return ($apps[$id]['name'] ?: $id).' was removed'.(is_dir($folder) ? ' - its data stays in '.$folder.' (delete it by hand if you no longer need it)' : '');
}

// ---------------------------------------------------------------------------------------------------------------------
// Recipes

/**
 * Downloads a recipe's files from its repository into a staging folder, and checks them (see store_fetch_recipe() and
 * store_load_recipe()).
 *
 * @param array<string, mixed> $repo  The repository, as store_repos_loaded() gives it
 * @param array<string, mixed> $entry The recipe in the repository's catalogue
 *
 * @return array{ 0: array<string, mixed>, 1: string } [recipe, staging folder]
 *
 * @throws JobFailed When they can't be downloaded or aren't valid
 */
function job_recipe_files(array $repo, array $entry): array
{
    $staging = store_data_path().'/staging/'.$entry['id'];

    store_rmtree($staging);
    job_log('Downloading the recipe ('.count($entry['files']).' files) and checking their checksums');

    $error = store_fetch_recipe($repo, $entry, $staging);

    if ($error !== '') {
        job_fail($error);
    }

    list($recipe, $error) = store_load_recipe($staging, $entry);

    if ($recipe === null) {
        job_fail($error);
    }

    return [$recipe, $staging];
}

/**
 * Runs Docker Compose in a recipe's folder, where it reads compose.yaml and compose.override.yaml by itself.
 *
 * @param array<string, mixed> $recipe The recipe
 * @param string               $data   Its folder
 * @param list<string>         $args   Compose's command and its arguments (e.g. ['up', '-d'])
 *
 * @return int Compose's exit code
 */
function job_compose(array $recipe, string $data, array $args): int
{
    return job_run(array_merge(['docker', 'compose', '--progress', 'plain', '-p', $recipe['project']], $args), [], $data);
}

/**
 * Downloads a recipe's images, trying again on failure: registries refuse bursts of requests for a moment
 * ("toomanyrequests"), and connections drop during multi-gigabyte downloads (what was downloaded is kept).
 *
 * @param array<string, mixed> $recipe The recipe
 * @param string               $data   Its folder
 *
 * @return bool Whether they were all downloaded
 */
function job_pull(array $recipe, string $data): bool
{
    foreach ([0, 20, 60] as $attempt => $wait) {
        if ($wait) {
            job_log('Trying again in '.$wait.' seconds');
            sleep($wait);
        }

        if (job_compose($recipe, $data, ['pull']) === 0) {
            return true;
        }
    }

    return false;
}

/**
 * Runs one of a recipe's hooks (from its files in .store/recipe), in its folder, with .env's values and the Store's
 * details in its environment.
 *
 * @param array<string, mixed>  $recipe The recipe
 * @param string                $data   Its folder
 * @param string                $hook   The hook (e.g. post_install)
 * @param array<string, string> $env    .env's values
 * @param array<string, string> $extra  The Store's details (STORE_ACTION, STORE_VERSION...)
 *
 * @return int Its exit code (0 if the recipe has no such hook)
 */
function job_hook(array $recipe, string $data, string $hook, array $env, array $extra): int
{
    if (empty($recipe['hooks'][$hook])) {
        return 0;
    }

    job_log('Running its '.$hook.' step');

    $script = $data.'/.store/recipe/'.$recipe['hooks'][$hook];

    return job_run(['sh', $script], $env + $extra + ['STORE_DATA' => $data], $data);
}

/**
 * Writes a recipe's files into its folder: compose.yaml, recipe.json, .store/recipe (its files, for its hooks), .env
 * and compose.override.yaml.
 *
 * @param array<string, mixed>  $recipe  The recipe
 * @param string|null           $staging Where its downloaded files are, or null to only write .env and
 *                                       compose.override.yaml (a change of settings)
 * @param string                $data    Its folder
 * @param array<string, string> $env     .env's values
 * @param array<string, mixed>  $values  The options' values
 *
 * @return void
 *
 * @throws JobFailed When its files can't be written
 */
function job_write_recipe(array $recipe, ?string $staging, string $data, array $env, array $values): void
{
    store_mkdir($data.'/.store');

    if ($staging !== null) {
        store_rmtree($data.'/.store/recipe.new');

        if (!job_copy_tree($staging, $data.'/.store/recipe.new')) {
            job_fail('Could not copy the recipe\'s files');
        }

        store_rmtree($data.'/.store/recipe');
        rename($data.'/.store/recipe.new', $data.'/.store/recipe');

        if (!copy($staging.'/'.$recipe['compose'], $data.'/compose.yaml.tmp') || !rename($data.'/compose.yaml.tmp', $data.'/compose.yaml')) {
            job_fail('Could not write compose.yaml');
        }

        chmod($data.'/compose.yaml', 0644);
        copy($staging.'/recipe.json', $data.'/recipe.json');
    }

    if (!store_write($data.'/.env', store_env_text($env, $recipe['name']), 0600)) {
        job_fail('Could not write .env');
    }

    $override = store_override_text($recipe, $values);

    if ($override !== '') {
        store_write($data.'/compose.override.yaml', $override, 0644);

        foreach (store_mounts($recipe, $values) as $mount) {
            job_log($mount[0].': '.$mount[1].' is '.$mount[2].' in '.$recipe['name']);
        }
    } else {
        @unlink($data.'/compose.override.yaml');
    }
}

/**
 * Copies a folder and everything in it.
 *
 * @param string $from The folder
 * @param string $to   Where to copy it (created)
 *
 * @return bool Whether it was all copied
 */
function job_copy_tree(string $from, string $to): bool
{
    if (!store_mkdir($to)) {
        return false;
    }

    foreach (scandir($from) ?: [] as $name) {
        if ($name === '.' || $name === '..') {
            continue;
        }

        $ok = is_dir($from.'/'.$name) ? job_copy_tree($from.'/'.$name, $to.'/'.$name) : copy($from.'/'.$name, $to.'/'.$name);

        if (!$ok) {
            return false;
        }
    }

    return true;
}

/**
 * Creates the folders of a recipe's options marked create.
 *
 * @param array<string, mixed> $recipe The recipe
 * @param array<string, mixed> $values The options' values
 *
 * @return void
 *
 * @throws JobFailed When one can't be created
 */
function job_create_folders(array $recipe, array $values): void
{
    foreach ($recipe['options'] as $option) {
        if ($option['type'] !== 'folder' || empty($option['create'])) {
            continue;
        }

        foreach ((array)$values[$option['key']] as $folder) {
            if ($folder !== '' && !is_dir($folder)) {
                job_log('Creating '.$folder);

                if (!mkdir($folder, 0755, true)) {
                    job_fail('Could not create '.$folder);
                }
            }
        }
    }
}

/**
 * Waits for a web interface (if there's one: web's port, or local_port where it only listens on the NAS itself) to
 * answer on the NAS, so that the job ends once it can be used - not with a 502 from the Nginx app when it's opened:
 * programs and containers are "started" long before they're ready (Immich takes 20-30 seconds). Any HTTP answer below
 * 500 counts (e.g. a login page's 401), not a 502 / 503 from a proxy in front of a server still starting.
 *
 * @param mixed  $web  The app's or recipe's web details (port or local_port, path, ready_timeout), or null
 * @param string $hint Where to look if it doesn't answer, for the log
 *
 * @return bool Whether it answered (true if there's no web interface)
 */
function job_wait_web($web, string $hint): bool
{
    $port = $web['port'] ?? ($web['local_port'] ?? 0);

    if (!$port) {
        return true;
    }

    $url     = 'http://127.0.0.1:'.$port.($web['path'] ?? '/');
    $timeout = $web['ready_timeout'] ?? 300;

    job_log('Waiting for it to be ready (up to '.($timeout >= 120 ? round($timeout / 60).' minutes' : $timeout.' seconds').')');

    $start = time();

    while (true) {
        list(, $status) = store_run(['curl', '-s', '-o', '/dev/null', '-w', '%{http_code}', '--max-time', '5', $url]);

        if ((int)$status >= 100 && (int)$status < 500) {
            job_log('It\'s ready (answered after '.(time() - $start).' seconds)');

            return true;
        }

        if (time() - $start >= $timeout) {
            job_log('Warning: it hasn\'t answered on port '.$port.' yet - it may still be starting ('.$hint.')');

            return false;
        }

        sleep(3);
    }
}

/**
 * Waits for a recipe's web interface (see job_wait_web()).
 *
 * @param array<string, mixed> $recipe The recipe
 *
 * @return bool Whether it answered
 */
function job_wait_ready(array $recipe): bool
{
    return job_wait_web($recipe['web'] ?? null, 'its logs: docker compose -p '.$recipe['project'].' logs');
}

/**
 * Updates a recipe's site in the Nginx app, if it's installed. Nginx apps that read the recipes' sites from their
 * recipe.json themselves (sites_declared) only need to write their sites again - once the recipe's install record is
 * written, or removed. Older ones are given the site (add-app / remove-app).
 *
 * @param array<string, mixed> $recipe The recipe
 * @param bool                 $remove Whether the recipe is being removed
 *
 * @return string The site's address, or ''
 */
function job_nginx(array $recipe, bool $remove): string
{
    $sites = store_apps_path().'/nginx/lib/sites.php';
    $data  = store_apps_path().'/_nginx';

    if (empty($recipe['web']['nginx']) || !is_file($sites) || !is_dir($data.'/sites')) {
        return '';
    }

    $nginx = $recipe['web']['nginx'];

    if (strpos((string)file_get_contents($sites), 'function sites_declared(') !== false) {
        job_log($remove ? 'Removing its site from the Nginx app' : 'Updating its site in the Nginx app ('.$nginx['name'].')');

        list($code, $output) = store_run(['php', $sites, 'generate', $data]);

        if ($code !== 0) {
            job_log('Warning: the Nginx app didn\'t write its sites: '.$output);

            return '';
        }
    } elseif ($remove) {
        job_log('Removing its site from the Nginx app');
        store_run(['php', $sites, 'remove-app', $data, $nginx['name']]);
    } else {
        job_log('Adding its site to the Nginx app ('.$nginx['name'].')');

        $command = ['php', $sites, 'add-app', $data, $nginx['name'], 'http://127.0.0.1:'.$recipe['web']['port'], $recipe['name']];

        if (!empty($nginx['uploads'])) {
            $command[] = '--uploads';
        }

        if (!empty($nginx['stream'])) {
            $command[] = '--stream';
        }

        if (!empty($recipe['web']['path']) && $recipe['web']['path'] !== '/') {
            // Its start page: the app has the whole site, as its pages may use other paths - e.g. Pi-hole's /api
            $command[] = '--start='.$recipe['web']['path'];
        }

        list($code, $output) = store_run($command);

        if ($code !== 0) {
            job_log('Warning: the Nginx app didn\'t add its site: '.$output);

            return '';
        }
    }

    store_run(['sh', store_apps_path().'/nginx/nginx_ctl.sh', 'reload']);

    if ($remove) {
        return '';
    }

    list($code, $url) = store_run(['php', $sites, 'url', $data, $nginx['name']]);

    return $code === 0 ? trim($url) : '';
}

/**
 * What WD's installer's status (/tmp/upload_apkg_status) says about a failed installation.
 *
 * @param string $result The status
 *
 * @return string Why it failed, for the page
 */
function job_installer_reason(string $result): string
{
    if ($result === '') {
        return 'it stopped without saying how it went';
    }

    if ($result === '100') {
        return 'it unpacked the package, but didn\'t finish installing it';
    }

    if ($result === '3') {
        // Seen when the NAS's app service was stuck: after unpacking, nothing ran for 2 minutes - a restart cured it
        return 'it unpacked the package, then gave up without running its install steps (status 3) - if it happens again, restart the NAS before trying again';
    }

    return 'status '.$result.' - see /tmp/debug_apkg';
}

/**
 * Copies the last lines the app's own installation steps logged (in /tmp/debug_apkg) since the installer started
 * into the job's log.
 *
 * @param int $from The size of /tmp/debug_apkg before the installer started
 *
 * @return void
 */
function job_installer_log(int $from): void
{
    $log   = (string)@file_get_contents('/tmp/debug_apkg', false, null, $from);
    $lines = array_slice(array_filter(array_map('trim', explode("\n", $log)), 'store_not_empty'), -20);

    job_log($lines ? 'Its install steps logged:' : 'None of its install steps ran (nothing in /tmp/debug_apkg)');

    foreach ($lines as $line) {
        job_log('    '.$line);
    }
}

/**
 * Puts an app's files back after a failed install, and starts them (as the NAS does when it starts).
 *
 * @param string $id       The app's id
 * @param string $folder   Its folder in Nas_Prog
 * @param string $previous Where its files were kept
 *
 * @return string ' - ' and what was done, for the failure's message
 */
function job_put_back(string $id, string $folder, string $previous): string
{
    if (file_exists($folder) || !is_dir($previous) || !rename($previous, $folder)) {
        return ' - the previous version could not be put back (it\'s kept in '.$previous.')';
    }

    job_log('Putting the previous version back and starting it');

    $ok = (!is_file($folder.'/init.sh') || job_run(['sh', $folder.'/init.sh', $folder]) === 0)
        && (!is_file($folder.'/start.sh') || job_run(['sh', $folder.'/start.sh', $folder]) === 0);

    return ' - the previous version was put back'.($ok ? ' and started' : ', but didn\'t start (see /tmp/debug_apkg)')
        .'. The NAS\'s app list may only show it again after the NAS restarts';
}

/**
 * The Store's details given to a recipe's hooks.
 *
 * @param array<string, mixed> $spec     The job
 * @param string               $data     The recipe's folder
 * @param mixed                $version  The recipe's version
 * @param mixed                $previous The version installed before (updates), or null
 *
 * @return array<string, string> STORE_ACTION, STORE_DATA, STORE_VERSION and STORE_PREVIOUS_VERSION
 */
function job_store_env(array $spec, string $data, $version, $previous = null): array
{
    $actions = [
        'recipe_install'   => 'install',
        'recipe_update'    => 'update',
        'recipe_change'    => 'change',
        'recipe_uninstall' => 'uninstall',
    ];

    return [
            'STORE_ACTION'  => $actions[$spec['action']] ?? 'update',
            'STORE_DATA'    => $data,
            'STORE_VERSION' => (string)$version,
    ] + ($previous !== null ? ['STORE_PREVIOUS_VERSION' => (string)$previous] : []);
}

/**
 * Installs a recipe: its files downloaded and checked, its settings checked (reusing those of a previous install whose
 * data was kept), its folder written, its images downloaded and its containers started, with its hooks - then its site
 * in the Nginx app. A failed installation is undone.
 *
 * @param array<string, mixed> $spec The job: the repository (repo), the recipe's id (target) and the wizard's answers
 *
 * @return string The outcome, for the page
 *
 * @throws JobFailed When it can't be installed
 */
function job_recipe_install(array $spec): string
{
    list($repo, $entry) = store_find('recipes', $spec['repo'], $spec['target']);

    if ($entry === null) {
        job_fail('The recipe isn\'t in that repository any more - refresh the repositories');
    }

    if (isset(store_installed_recipes()[$entry['id']])) {
        job_fail($entry['name'].' is already installed');
    }

    list($recipe, $staging) = job_recipe_files($repo, $entry);

    job_requires($recipe['requires'] ?? []);

    $data = store_apps_path().'/'.$recipe['data_folder'];

    list($current, $error) = store_existing_settings($recipe);

    if ($error !== '') {
        job_fail($error);
    }

    list($values, $errors) = store_answers($recipe, $spec['answers'] ?? [], $current, 'install');

    if ($errors) {
        job_fail('Some settings aren\'t valid: '.implode('; ', array_map(function (string $key, string $error): string {
            return $key.': '.$error;
        }, array_keys($errors), $errors)));
    }

    $env     = store_env_values($recipe, $values);
    $created = !is_dir($data);

    try {
        store_mkdir($data);
        chmod($data, 0700);
        job_create_folders($recipe, $values);
        job_write_recipe($recipe, $staging, $data, $env, $values);

        $store_env = job_store_env($spec, $data, $recipe['version']);

        if (job_hook($recipe, $data, 'pre_install', $env, $store_env) !== 0) {
            job_fail('Its pre_install step failed');
        }

        job_log('Downloading its images (this can take a while the first time)');

        if (!job_pull($recipe, $data)) {
            job_fail('Docker could not download its images');
        }

        job_log('Starting it');

        if (job_compose($recipe, $data, ['up', '-d']) !== 0) {
            job_fail('Docker could not start it');
        }
    } catch (JobFailed $exception) {
        job_log('Undoing the install');

        if (is_file($data.'/compose.yaml')) {
            job_compose($recipe, $data, ['down']);
        }

        if ($created) {
            store_rmtree($data);
        } else {
            @unlink($data.'/.store/installed.json');
        }

        throw $exception;
    }

    if (job_hook($recipe, $data, 'post_install', $env, $store_env) !== 0) {
        job_log('Warning: its post_install step failed');
    }

    store_write_json($data.'/.store/installed.json', [
        'id'        => $recipe['id'],
        'name'      => $recipe['name'],
        'repo'      => $repo['url'],
        'version'   => $recipe['version'],
        'project'   => $recipe['project'],
        'installed' => store_now(),
        'updated'   => store_now(),
        'values'    => store_public_values($recipe, $values)
    ]);

    $url = job_nginx($recipe, false);

    store_rmtree($staging);

    $ready = job_wait_ready($recipe);

    return $recipe['name'].($ready ? ' is installed and ready' : ' is installed but still starting').($url !== '' ? ' - '.$url : (isset($recipe['web']['port']) ? ' - http://'.store_nas()['ip'].':'.$recipe['web']['port'].'/' : ''));
}

/**
 * An installed recipe's record and the recipe it was installed from.
 *
 * @param string $id The recipe's id
 *
 * @return array{ 0: array<string, mixed>, 1: array<string, mixed> } [record (as store_installed_recipes() gives it), recipe]
 *
 * @throws JobFailed When it isn't installed, or its files are missing
 */
function job_installed_recipe(string $id): array
{
    $installed = store_installed_recipes();

    if (!isset($installed[$id])) {
        job_fail('It isn\'t installed');
    }

    $record = $installed[$id];
    $recipe = store_read_json($record['data'].'/.store/recipe/recipe.json');

    if ($recipe === null) {
        job_fail('Its recipe files are missing from '.$record['data'].'/.store');
    }

    return [$record, $recipe];
}

/**
 * Updates a recipe to its repository's version: its files, its settings (only new options are asked), its images and
 * containers, with its hooks.
 *
 * @param array<string, mixed> $spec The job: the recipe's id (target), the wizard's answers, and defaults (true to
 *                                   give new options their defaults - unattended)
 *
 * @return string The outcome, for the page
 *
 * @throws JobFailed When it can't be updated
 */
function job_recipe_update(array $spec): string
{
    list($record, $old) = job_installed_recipe($spec['target']);
    list($repo, $entry) = store_find('recipes', $record['repo'], $record['id']);

    if ($entry === null) {
        job_fail('It isn\'t in its repository any more ('.$record['repo'].')');
    }

    if (store_version_compare($entry['version'], $record['version']) <= 0) {
        job_fail('It\'s already up to date');
    }

    list($recipe, $staging) = job_recipe_files($repo, $entry);

    if ($recipe['data_folder'] !== $old['data_folder'] || $recipe['project'] !== $old['project']) {
        job_fail('The new version moves its folder or project - reinstall it instead');
    }

    job_requires($recipe['requires'] ?? []);

    $data    = $record['data'];
    $current = store_recipe_values($record, $old);
    $answers = $spec['answers'] ?? [];

    // Unattended (the automatic updates): new options take the values the page would offer - one without a usable
    // default (e.g. a new password) still needs the user
    if (!empty($spec['defaults'])) {
        foreach (store_wizard($recipe, $current, 'update') as $field) {
            if (!array_key_exists($field['key'], $answers)) {
                $answers[$field['key']] = $field['value'];
            }
        }
    }

    list($values, $errors) = store_answers($recipe, $answers, $current, 'update');

    if ($errors) {
        job_fail('Some settings aren\'t valid: '.implode('; ', $errors));
    }

    $env       = store_env_values($recipe, $values);
    $store_env = job_store_env($spec, $data, $recipe['version'], $record['version']);

    job_log('Updating from '.$record['version'].' to '.$recipe['version']);
    job_create_folders($recipe, $values);
    job_write_recipe($recipe, $staging, $data, $env, $values);

    if (job_hook($recipe, $data, 'pre_update', $env, $store_env) !== 0) {
        job_fail('Its pre_update step failed');
    }

    if (!job_pull($recipe, $data)) {
        job_fail('Docker could not download its images');
    }

    if (job_compose($recipe, $data, ['up', '-d', '--remove-orphans']) !== 0) {
        job_fail('Docker could not start it');
    }

    if (job_hook($recipe, $data, 'post_update', $env, $store_env) !== 0) {
        job_log('Warning: its post_update step failed');
    }

    job_nginx($recipe, false);

    $record['version'] = $recipe['version'];
    $record['name']    = $recipe['name'];
    $record['updated'] = store_now();
    $record['values']  = store_public_values($recipe, $values);

    unset($record['data']);

    store_write_json($data.'/.store/installed.json', $record);
    store_rmtree($staging);

    return $recipe['name'].' was updated to '.$recipe['version'].(job_wait_ready($recipe) ? '' : ' (still starting)');
}

/**
 * Changes an installed recipe's settings: .env and compose.override.yaml rewritten, its containers recreated as needed,
 * its post_change hook run, and its sites in the Nginx app written again (they can depend on its settings).
 *
 * @param array<string, mixed> $spec The job: the recipe's id (target) and the wizard's answers
 *
 * @return string The outcome, for the page
 *
 * @throws JobFailed When the settings aren't valid, or can't be applied
 */
function job_recipe_change(array $spec): string
{
    list($record, $recipe) = job_installed_recipe($spec['target']);

    $data    = $record['data'];
    $current = store_recipe_values($record, $recipe);

    list($values, $errors) = store_answers($recipe, $spec['answers'] ?? [], $current, 'change');

    if ($errors) {
        job_fail('Some settings aren\'t valid: '.implode('; ', $errors));
    }

    $env = store_env_values($recipe, $values);

    job_create_folders($recipe, $values);
    job_write_recipe($recipe, null, $data, $env, $values);
    job_log('Applying the settings');

    if (job_compose($recipe, $data, ['up', '-d']) !== 0) {
        job_fail('Docker could not apply them');
    }

    if (job_hook($recipe, $data, 'post_change', $env, job_store_env($spec, $data, $record['version'])) !== 0) {
        job_log('Warning: its post_change step failed');
    }

    $record['updated'] = store_now();
    $record['values']  = store_public_values($recipe, $values);

    unset($record['data']);

    store_write_json($data.'/.store/installed.json', $record);
    job_nginx($recipe, false); // Its sites in the Nginx app can depend on its settings - web.sites' if

    return 'The settings of '.$recipe['name'].' were changed'.(job_wait_ready($recipe) ? '' : ' (still starting)');
}

/**
 * Removes a recipe: its containers, its site in the Nginx app, and the folders chosen for deletion - only those the
 * Store created, never those the recipe keeps. Its own folder stays unless delete_data is set.
 *
 * @param array<string, mixed> $spec The job: the recipe's id (target), delete (the options whose folders go) and
 *                                   delete_data
 *
 * @return string The outcome, for the page
 *
 * @throws JobFailed When it can't be removed
 */
function job_recipe_uninstall(array $spec): string
{
    list($record, $recipe) = job_installed_recipe($spec['target']);

    $data   = $record['data'];
    $values = store_recipe_values($record, $recipe);
    $env    = store_env_values($recipe, $values);

    if (job_hook($recipe, $data, 'pre_uninstall', $env, job_store_env($spec, $data, $record['version'])) !== 0) {
        job_fail('Its pre_uninstall step failed');
    }

    job_log('Stopping and removing its containers');

    if (job_compose($recipe, $data, ['down']) !== 0) {
        job_fail('Docker could not remove its containers');
    }

    @unlink($data.'/.store/installed.json');
    job_nginx($recipe, true);

    $kept = [];

    // The folders chosen for deletion (only those the Store created, never those kept by the recipe)
    $keep   = isset($recipe['uninstall']['keep']) && is_array($recipe['uninstall']['keep']) ? $recipe['uninstall']['keep'] : [];
    $delete = isset($spec['delete']) && is_array($spec['delete']) ? $spec['delete'] : [];

    foreach ($recipe['options'] as $option) {
        if ($option['type'] !== 'folder' || empty($option['create'])) {
            continue;
        }

        foreach ((array)$values[$option['key']] as $folder) {
            $inside = strpos($folder.'/', $data.'/') === 0;

            if (in_array($option['key'], $delete, true) && !in_array($option['key'], $keep, true) && !$inside && is_dir($folder)) {
                job_log('Deleting '.$folder);
                store_rmtree($folder);
            } elseif (!$inside && is_dir($folder)) {
                $kept[] = $folder;
            }
        }
    }

    if (!empty($spec['delete_data'])) {
        job_log('Deleting '.$data);
        store_rmtree($data);
    } else {
        $kept[] = $data.' (its settings - installing it again reuses them)';
    }

    return $recipe['name'].' was removed'.($kept ? '. Kept: '.implode(', ', $kept) : '');
}

// ---------------------------------------------------------------------------------------------------------------------
// Automatic updates

/**
 * The nightly automatic updates (started by lib/auto_update.php): each ticked app and recipe with a newer version is
 * updated as its page's Update does - one at a time, the Store itself last (see store_auto_plan()). One failing doesn't
 * stop the others; what happened to each is recorded, and the ntfy app told (store_auto_record()).
 *
 * @param array<string, mixed> $spec The job
 *
 * @return string The outcome, for the page
 *
 * @throws JobFailed When one of them failed (after all were tried)
 */
function job_auto_update(array $spec): string
{
    $results = [];
    $counts  = ['updated' => 0, 'failed' => 0, 'skip' => 0];

    foreach (store_auto_plan() as $item) {
        if ($item['state'] === 'current') {
            $results[] = $item + ['message' => ''];

            continue;
        }

        if ($item['state'] === 'skip') {
            job_log('Not updating '.$item['name'].($item['to'] !== '' ? ' to '.$item['to'] : '').': '.$item['reason']);

            $results[] = $item + ['message' => ''];
            $counts['skip']++;

            continue;
        }

        job_log('== Updating '.$item['name'].' from '.$item['from'].' to '.$item['to']);

        try {
            if ($item['kind'] === 'apps') {
                $message = job_app_install(['repo' => $item['repo'], 'target' => $item['id']], true);
            } else {
                $message = job_recipe_update(['action' => 'recipe_update', 'target' => $item['id'], 'answers' => [], 'defaults' => true]);
            }

            job_log($message);

            $results[] = ['state' => 'updated', 'message' => $message] + $item;
            $counts['updated']++;
        } catch (Exception $exception) {
            $message = $exception->getMessage();

            // A recipe whose new version asks for settings (before anything was changed): left for the user, who gives
            // them on its page - reported once, as other updates left for them are
            if ($item['kind'] === 'recipes' && strpos($message, 'Some settings aren\'t valid') === 0) {
                $reason = 'its new version needs settings - update it from its page ('.$message.')';

                job_log('Not updating '.$item['name'].' to '.$item['to'].': '.$reason);

                $results[] = ['state' => 'skip', 'reason' => $reason, 'message' => ''] + $item;
                $counts['skip']++;

                continue;
            }

            job_log('Failed: '.$message);

            $results[] = ['state' => 'failed', 'message' => $message] + $item;
            $counts['failed']++;
        }
    }

    store_auto_record($results);

    $parts = [];

    foreach (['updated' => '%d updated', 'failed' => '%d failed', 'skip' => '%d skipped'] as $state => $format) {
        if ($counts[$state]) {
            $parts[] = sprintf($format, $counts[$state]);
        }
    }

    $summary = 'Automatic updates: '.($parts ? implode(', ', $parts) : 'nothing to update');

    if ($counts['failed']) {
        job_fail($summary.' - see the log');
    }

    return $summary;
}

// ---------------------------------------------------------------------------------------------------------------------

try {
    $actions = [
        'app_install'      => function (array $spec): string { return job_app_install($spec, false); },
        'app_update'       => function (array $spec): string { return job_app_install($spec, true); },
        'app_uninstall'    => 'job_app_uninstall',
        'recipe_install'   => 'job_recipe_install',
        'recipe_update'    => 'job_recipe_update',
        'recipe_change'    => 'job_recipe_change',
        'recipe_uninstall' => 'job_recipe_uninstall',
        'auto_update'      => 'job_auto_update',
    ];

    if (!isset($actions[$spec['action']])) {
        job_fail('Unknown action');
    }

    job_log($spec['title']);

    $message = call_user_func($actions[$spec['action']], $spec);

    job_log($message);

    $status['state'] = 'done';
    $status['message'] = $message;
} catch (Exception $exception) {
    job_log('Failed: '.$exception->getMessage());

    $status['state']   = 'failed';
    $status['message'] = $exception->getMessage();
}

$status['finished'] = store_now();

store_write_json($jobs.'/status.json', $status);
