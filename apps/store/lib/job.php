<?php
// The Store's background jobs - installs, updates and removals, which take minutes (downloads, WD's installer, docker
// compose). Started by api.php, detached from the web request:
//     php job.php <job file>
// The job file (root-only, deleted once read) holds the action and its arguments, including the wizard's answers. One job
// runs at a time; its progress goes to jobs/job.log and its state to jobs/status.json, which the page follows.
// Everything is loaded before the job starts, so it can finish even if it removes the Store's own files (updating itself).

require __DIR__ . '/store.php';

if (PHP_SAPI !== 'cli' || !isset($argv[1])) {
	exit(1);
}
$jobs = store_data_path() . '/jobs';
$spec = store_read_json($argv[1]);
@unlink($argv[1]);
if ($spec === null) {
	exit(1);
}
$lock = fopen($jobs . '/lock', 'c');
if (!$lock || !flock($lock, LOCK_EX | LOCK_NB)) {
	exit(1);
}
ignore_user_abort(true);
set_time_limit(0);
umask(022);

$GLOBALS['job_log'] = fopen($jobs . '/job.log', 'w');
chmod($jobs . '/job.log', 0600);
$status = ['id' => $spec['id'], 'action' => $spec['action'], 'target' => isset($spec['target']) ? $spec['target'] : '', 'title' => $spec['title'], 'state' => 'running',
	'started' => store_now(), 'finished' => '', 'pid' => getmypid(), 'message' => ''];
store_write_json($jobs . '/status.json', $status);

function job_log($message)
{
	fwrite($GLOBALS['job_log'], '[' . date('H:i:s') . '] ' . $message . "\n");
	fflush($GLOBALS['job_log']);
}

class JobFailed extends Exception
{
}

// PHP's own warnings go into the job's log too (the job has no other output)
set_error_handler(function ($level, $message, $file, $line) {
	// (not those silenced with @)
	if (!(error_reporting() & $level)) {
		return true;
	}
	job_log('PHP warning: ' . $message . ' (' . basename($file) . ':' . $line . ')');
	return true;
});

function job_fail($message)
{
	throw new JobFailed($message);
}

// Runs a command, copying its output into the log as it comes. Returns its exit code
function job_run(array $command, array $env = [], $cwd = null)
{
	$env += ['PATH' => '/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin', 'HOME' => getenv('HOME') ?: '/root'];
	$process = @proc_open($command, [0 => ['file', '/dev/null', 'r'], 1 => ['pipe', 'w'], 2 => ['redirect', 1]], $pipes, $cwd, $env);
	if (!is_resource($process)) {
		job_log('Could not run: ' . $command[0]);
		return -1;
	}
	while (($line = fgets($pipes[1])) !== false) {
		// (progress bars rewrite their line with carriage returns: only the last state of each line is kept)
		$parts = explode("\r", rtrim($line, "\n"));
		$line = trim(end($parts));
		// (WD's installer decrypts packages with an old OpenSSL key derivation, and OpenSSL says so - harmless)
		if (strpos($line, 'deprecated key derivation') !== false || strpos($line, 'Using -iter or -pbkdf2') !== false) {
			continue;
		}
		if ($line !== '') {
			fwrite($GLOBALS['job_log'], '    ' . $line . "\n");
			fflush($GLOBALS['job_log']);
		}
	}
	fclose($pipes[1]);
	return proc_close($process);
}

// Downloads a package with curl, logging its progress, then checks its size and SHA256
function job_download_package($url, $file, $size, $sha256)
{
	if (!store_is_https_url($url)) {
		job_fail('Not an HTTPS address: ' . $url);
	}
	@unlink($file);
	// (at least 100KB/s, and never less than 10 minutes)
	$timeout = max(600, (int)($size / 102400));
	$command = ['curl', '-sS', '-f', '-L', '--proto', '=https', '--proto-redir', '=https', '--max-redirs', '5',
		'--connect-timeout', '15', '-m', (string)$timeout, '--max-filesize', (string)$size, '-A', 'WD-NAS-Store/1', '-o', $file, $url];
	$env = ['PATH' => '/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin', 'HOME' => getenv('HOME') ?: '/root'];
	$process = @proc_open($command, [0 => ['file', '/dev/null', 'r'], 1 => ['pipe', 'w'], 2 => ['redirect', 1]], $pipes, null, $env);
	if (!is_resource($process)) {
		job_fail('Could not run curl');
	}
	stream_set_blocking($pipes[1], false);
	$output = '';
	$last = 0;
	while (true) {
		$state = proc_get_status($process);
		$output .= (string)stream_get_contents($pipes[1]);
		if (!$state['running']) {
			break;
		}
		if (time() - $last >= 5) {
			clearstatcache();
			$done = is_file($file) ? filesize($file) : 0;
			job_log('Downloaded ' . store_size($done) . ' of ' . store_size($size));
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
		job_fail('The download failed: ' . (trim($output) !== '' ? trim($output) : 'curl exit code ' . $code));
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
	job_log('Downloaded and checked (' . store_size($size) . ', SHA256 matches)');
}

// The name of an app, from the catalogue (for messages), or its id
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

function job_requires($requires)
{
	$problems = store_check_requires($requires, 'job_app_label');
	foreach ($problems as $problem) {
		if ($problem['level'] === 'warning') {
			job_log('Warning: ' . $problem['message']);
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

function job_app_install(array $spec, $update)
{
	list($repo, $app) = store_find('apps', $spec['repo'], $spec['target']);
	if ($app === null) {
		job_fail('The app isn\'t in that repository any more - refresh the repositories');
	}
	$id = $app['id'];
	$nas = store_nas();
	$installed = isset($nas['apps'][$id]);
	if ($update && !$installed) {
		job_fail($app['name'] . ' isn\'t installed');
	}
	if (!$update && $installed) {
		job_fail($app['name'] . ' is already installed');
	}
	if ($update && empty($app['keeps_data'])) {
		job_fail($app['name'] . ' can\'t be updated by the Store (it would lose its settings) - update it by hand');
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
		job_fail($app['name'] . ' has no package for this NAS (' . ($nas['model'] ?: 'unknown model') . ')');
	}
	job_requires(isset($app['requires']) ? $app['requires'] : []);
	$url = store_resolve_url($package['url'], $repo['base']);
	if ($url === '') {
		job_fail('The package\'s address isn\'t allowed');
	}
	if ($nas['disk_mb'] * 1048576 < $package['size'] * 2 + (100 << 20)) {
		job_fail('There isn\'t enough free space for the package');
	}

	job_log('Downloading ' . $app['name'] . ' ' . $app['version'] . ' for ' . $nas['model'] . ' (' . store_size($package['size']) . ')');
	store_mkdir(STORE_UPLOAD_PATH, 0755);
	$temp = STORE_UPLOAD_PATH . '/.store-download.part';
	job_download_package($url, $temp, $package['size'], $package['sha256']);
	$name = preg_replace('/[^A-Za-z0-9._-]/', '_', "{$id}_{$app['version']}_{$nas['model']}.bin");
	if (!rename($temp, STORE_UPLOAD_PATH . '/' . $name)) {
		job_fail('Could not prepare the package');
	}

	try {
		if ($update) {
			job_log('Removing the installed version (' . $nas['apps'][$id]['version'] . ') - its data folder stays');
			job_run(['del_apkg', $id]);
			for ($i = 0; $i < 120 && isset(store_installed_apps()[$id]); $i++) {
				sleep(1);
			}
			if (isset(store_installed_apps()[$id])) {
				job_fail('The installed version could not be removed');
			}
		}
		job_log('Installing with the NAS\'s own installer');
		@unlink('/tmp/upload_apkg_status');
		job_run(['upload_apkg', '-m', '-p', $name, '-t', '2'], [], STORE_UPLOAD_PATH);
		$result = trim((string)@file_get_contents('/tmp/upload_apkg_status'));
		if ($result === '4') {
			job_fail('The NAS says it\'s already installed');
		}
		if ($result !== '1') {
			job_fail('The NAS\'s installer failed (status ' . ($result !== '' ? $result : 'none') . ') - see /tmp/debug_apkg');
		}
	} finally {
		@unlink(STORE_UPLOAD_PATH . '/' . $name);
	}
	store_record_app($id, $repo['url'], $app['version']);
	$apps = store_installed_apps();
	// (unless WD's list says it's switched off - the NAS starts apps straight after installing them, and its list can lag)
	$ready = (isset($apps[$id]) && $apps[$id]['enabled'] === false) || job_wait_web(isset($app['web']) ? $app['web'] : null, 'its page in the NAS dashboard, and /tmp/debug_apkg');
	return $app['name'] . ' ' . (isset($apps[$id]) ? $apps[$id]['version'] : $app['version']) . ($ready ? ' is installed' : ' is installed but still starting')
		. (!empty($app['data_folder']) && $update ? ' (its data in ' . $app['data_folder'] . ' was kept)' : '');
}

function job_app_uninstall(array $spec)
{
	$id = $spec['target'];
	$apps = store_installed_apps();
	if (!isset($apps[$id])) {
		job_fail('It isn\'t installed');
	}
	// (the Store can remove itself: this job's code is already loaded, and its log is in the Store's data folder, which
	// stays - the NAS's own Apps page comes back as the Store stops)
	job_log('Removing ' . ($apps[$id]['name'] ?: $id) . ' with the NAS\'s own uninstaller'
		. ($id === 'store' ? ' - everything it installed stays installed, and the NAS\'s own Apps page comes back' : ''));
	job_run(['del_apkg', $id]);
	for ($i = 0; $i < 120 && isset(store_installed_apps()[$id]); $i++) {
		sleep(1);
	}
	if (isset(store_installed_apps()[$id])) {
		job_fail('It could not be removed');
	}
	store_record_app($id, null, null);
	$folder = store_apps_path() . '/_' . $id;
	return ($apps[$id]['name'] ?: $id) . ' was removed' . (is_dir($folder) ? ' - its data stays in ' . $folder . ' (delete it by hand if you no longer need it)' : '');
}

// ---------------------------------------------------------------------------------------------------------------------
// Recipes

// The recipe's files from its repository (into the staging folder), checked
function job_recipe_files(array $repo, array $entry)
{
	$staging = store_data_path() . '/staging/' . $entry['id'];
	store_rmtree($staging);
	job_log('Downloading the recipe (' . count($entry['files']) . ' files) and checking their checksums');
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

// Docker compose in the recipe's folder (compose.yaml and compose.override.yaml are read from there by themselves)
function job_compose(array $recipe, $data, array $args)
{
	return job_run(array_merge(['docker', 'compose', '--progress', 'plain', '-p', $recipe['project']], $args), [], $data);
}

// Downloads a recipe's images, trying again on failure: registries refuse bursts of requests for a moment
// ("toomanyrequests"), and connections drop during multi-gigabyte downloads (what was downloaded is kept)
function job_pull(array $recipe, $data)
{
	foreach ([0, 20, 60] as $attempt => $wait) {
		if ($wait) {
			job_log('Trying again in ' . $wait . ' seconds');
			sleep($wait);
		}
		if (job_compose($recipe, $data, ['pull']) === 0) {
			return true;
		}
	}
	return false;
}

function job_hook(array $recipe, $data, $hook, array $env, array $extra)
{
	if (empty($recipe['hooks'][$hook])) {
		return 0;
	}
	job_log('Running its ' . $hook . ' step');
	$script = $data . '/.store/recipe/' . $recipe['hooks'][$hook];
	return job_run(['sh', $script], $env + $extra + ['STORE_DATA' => $data], $data);
}

// Writes the recipe's files into its folder: compose.yaml, recipe.json, .store/recipe (its files, for its hooks), .env and
// compose.override.yaml
function job_write_recipe(array $recipe, $staging, $data, array $env, array $values)
{
	store_mkdir($data . '/.store');
	if ($staging !== null) {
		store_rmtree($data . '/.store/recipe.new');
		if (!job_copy_tree($staging, $data . '/.store/recipe.new')) {
			job_fail('Could not copy the recipe\'s files');
		}
		store_rmtree($data . '/.store/recipe');
		rename($data . '/.store/recipe.new', $data . '/.store/recipe');
		if (!copy($staging . '/' . $recipe['compose'], $data . '/compose.yaml.tmp') || !rename($data . '/compose.yaml.tmp', $data . '/compose.yaml')) {
			job_fail('Could not write compose.yaml');
		}
		chmod($data . '/compose.yaml', 0644);
		copy($staging . '/recipe.json', $data . '/recipe.json');
	}
	if (!store_write($data . '/.env', store_env_text($env, $recipe['name']), 0600)) {
		job_fail('Could not write .env');
	}
	$override = store_override_text($recipe, $values);
	if ($override !== '') {
		store_write($data . '/compose.override.yaml', $override, 0644);
		foreach (store_mounts($recipe, $values) as $mount) {
			job_log($mount[0] . ': ' . $mount[1] . ' is ' . $mount[2] . ' in ' . $recipe['name']);
		}
	} else {
		@unlink($data . '/compose.override.yaml');
	}
}

function job_copy_tree($from, $to)
{
	if (!store_mkdir($to)) {
		return false;
	}
	foreach (scandir($from) ?: [] as $name) {
		if ($name === '.' || $name === '..') {
			continue;
		}
		$ok = is_dir($from . '/' . $name) ? job_copy_tree($from . '/' . $name, $to . '/' . $name) : copy($from . '/' . $name, $to . '/' . $name);
		if (!$ok) {
			return false;
		}
	}
	return true;
}

// Creates the folders of the options marked create (and checks the others are still there)
function job_create_folders(array $recipe, array $values)
{
	foreach ($recipe['options'] as $option) {
		if ($option['type'] !== 'folder' || empty($option['create'])) {
			continue;
		}
		foreach ((array)$values[$option['key']] as $folder) {
			if ($folder !== '' && !is_dir($folder)) {
				job_log('Creating ' . $folder);
				if (!mkdir($folder, 0755, true)) {
					job_fail('Could not create ' . $folder);
				}
			}
		}
	}
}

// Waits for a web interface (if there's one: web's port, or local_port where it only listens on the NAS itself) to answer
// on the NAS, so that the job ends once it can be used - not with a 502 from the Nginx app when it's opened: programs
// and containers are "started" long before they're ready (Immich takes 20-30 seconds). Any HTTP answer below 500 counts
// (e.g. a login page's 401), not a 502/503 from a proxy in front of a server still starting. $hint: where to look if it
// doesn't answer. Returns whether it answered
function job_wait_web($web, $hint)
{
	$port = isset($web['port']) ? $web['port'] : (isset($web['local_port']) ? $web['local_port'] : 0);
	if (!$port) {
		return true;
	}
	$url = 'http://127.0.0.1:' . $port . (isset($web['path']) ? $web['path'] : '/');
	$timeout = isset($web['ready_timeout']) ? $web['ready_timeout'] : 300;
	job_log('Waiting for it to be ready (up to ' . ($timeout >= 120 ? round($timeout / 60) . ' minutes' : $timeout . ' seconds') . ')');
	$start = time();
	while (true) {
		list(, $status) = store_run(['curl', '-s', '-o', '/dev/null', '-w', '%{http_code}', '--max-time', '5', $url]);
		if ((int)$status >= 100 && (int)$status < 500) {
			job_log('It\'s ready (answered after ' . (time() - $start) . ' seconds)');
			return true;
		}
		if (time() - $start >= $timeout) {
			job_log('Warning: it hasn\'t answered on port ' . $port . ' yet - it may still be starting (' . $hint . ')');
			return false;
		}
		sleep(3);
	}
}

// A recipe's web interface (see job_wait_web)
function job_wait_ready(array $recipe)
{
	return job_wait_web(isset($recipe['web']) ? $recipe['web'] : null, 'its logs: docker compose -p ' . $recipe['project'] . ' logs');
}

// The recipe's site in the Nginx app, if installed
function job_nginx(array $recipe, $remove)
{
	$sites = store_apps_path() . '/nginx/lib/sites.php';
	$data = store_apps_path() . '/_nginx';
	if (empty($recipe['web']['nginx']) || !is_file($sites) || !is_dir($data . '/sites')) {
		return '';
	}
	$nginx = $recipe['web']['nginx'];
	if ($remove) {
		job_log('Removing its site from the Nginx app');
		store_run(['php', $sites, 'remove-app', $data, $nginx['name']]);
	} else {
		job_log('Adding its site to the Nginx app (' . $nginx['name'] . ')');
		$command = ['php', $sites, 'add-app', $data, $nginx['name'], 'http://127.0.0.1:' . $recipe['web']['port'], $recipe['name']];
		if (!empty($nginx['uploads'])) {
			$command[] = '--uploads';
		}
		if (!empty($nginx['stream'])) {
			$command[] = '--stream';
		}
		if (!empty($recipe['web']['path']) && $recipe['web']['path'] !== '/') {
			$command[] = '--path=' . rtrim($recipe['web']['path'], '/') . '/';
		}
		list($code, $output) = store_run($command);
		if ($code !== 0) {
			job_log('Warning: the Nginx app didn\'t add its site: ' . $output);
			return '';
		}
	}
	store_run(['sh', store_apps_path() . '/nginx/nginx_ctl.sh', 'reload']);
	if ($remove) {
		return '';
	}
	list($code, $url) = store_run(['php', $sites, 'url', $data, $nginx['name']]);
	return $code === 0 ? trim($url) : '';
}

function job_store_env(array $spec, $data, $version, $previous = null)
{
	$actions = ['recipe_install' => 'install', 'recipe_update' => 'update', 'recipe_change' => 'change', 'recipe_uninstall' => 'uninstall'];
	return ['STORE_ACTION' => isset($actions[$spec['action']]) ? $actions[$spec['action']] : 'update',
		'STORE_DATA' => $data, 'STORE_VERSION' => (string)$version] + ($previous !== null ? ['STORE_PREVIOUS_VERSION' => (string)$previous] : []);
}

function job_recipe_install(array $spec)
{
	list($repo, $entry) = store_find('recipes', $spec['repo'], $spec['target']);
	if ($entry === null) {
		job_fail('The recipe isn\'t in that repository any more - refresh the repositories');
	}
	if (isset(store_installed_recipes()[$entry['id']])) {
		job_fail($entry['name'] . ' is already installed');
	}
	list($recipe, $staging) = job_recipe_files($repo, $entry);
	job_requires(isset($recipe['requires']) ? $recipe['requires'] : []);
	$data = store_apps_path() . '/' . $recipe['data_folder'];
	list($current, $error) = store_existing_settings($recipe);
	if ($error !== '') {
		job_fail($error);
	}
	list($values, $errors) = store_answers($recipe, isset($spec['answers']) ? $spec['answers'] : [], $current, 'install');
	if ($errors) {
		job_fail('Some settings aren\'t valid: ' . implode('; ', array_map(function ($k, $e) {
			return $k . ': ' . $e;
		}, array_keys($errors), $errors)));
	}
	$env = store_env_values($recipe, $values);
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
	} catch (JobFailed $e) {
		job_log('Undoing the install');
		if (is_file($data . '/compose.yaml')) {
			job_compose($recipe, $data, ['down']);
		}
		if ($created) {
			store_rmtree($data);
		} else {
			@unlink($data . '/.store/installed.json');
		}
		throw $e;
	}
	if (job_hook($recipe, $data, 'post_install', $env, $store_env) !== 0) {
		job_log('Warning: its post_install step failed');
	}
	$url = job_nginx($recipe, false);
	store_write_json($data . '/.store/installed.json', ['id' => $recipe['id'], 'name' => $recipe['name'], 'repo' => $repo['url'],
		'version' => $recipe['version'], 'project' => $recipe['project'], 'installed' => store_now(), 'updated' => store_now(),
		'values' => store_public_values($recipe, $values)]);
	store_rmtree($staging);
	$ready = job_wait_ready($recipe);
	return $recipe['name'] . ($ready ? ' is installed and ready' : ' is installed but still starting') . ($url !== '' ? ' - ' . $url : (isset($recipe['web']['port']) ? ' - http://' . store_nas()['ip'] . ':' . $recipe['web']['port'] . '/' : ''));
}

function job_installed_recipe($id)
{
	$installed = store_installed_recipes();
	if (!isset($installed[$id])) {
		job_fail('It isn\'t installed');
	}
	$record = $installed[$id];
	$recipe = store_read_json($record['data'] . '/.store/recipe/recipe.json');
	if ($recipe === null) {
		job_fail('Its recipe files are missing from ' . $record['data'] . '/.store');
	}
	return [$record, $recipe];
}

function job_recipe_update(array $spec)
{
	list($record, $old) = job_installed_recipe($spec['target']);
	list($repo, $entry) = store_find('recipes', $record['repo'], $record['id']);
	if ($entry === null) {
		job_fail('It isn\'t in its repository any more (' . $record['repo'] . ')');
	}
	if (store_version_compare($entry['version'], $record['version']) <= 0) {
		job_fail('It\'s already up to date');
	}
	list($recipe, $staging) = job_recipe_files($repo, $entry);
	if ($recipe['data_folder'] !== $old['data_folder'] || $recipe['project'] !== $old['project']) {
		job_fail('The new version moves its folder or project - reinstall it instead');
	}
	job_requires(isset($recipe['requires']) ? $recipe['requires'] : []);
	$data = $record['data'];
	$current = store_recipe_values($record, $old);
	list($values, $errors) = store_answers($recipe, isset($spec['answers']) ? $spec['answers'] : [], $current, 'update');
	if ($errors) {
		job_fail('Some settings aren\'t valid: ' . implode('; ', $errors));
	}
	$env = store_env_values($recipe, $values);
	$store_env = job_store_env($spec, $data, $recipe['version'], $record['version']);
	job_log('Updating from ' . $record['version'] . ' to ' . $recipe['version']);
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
	$record['name'] = $recipe['name'];
	$record['updated'] = store_now();
	$record['values'] = store_public_values($recipe, $values);
	unset($record['data']);
	store_write_json($data . '/.store/installed.json', $record);
	store_rmtree($staging);
	return $recipe['name'] . ' was updated to ' . $recipe['version'] . (job_wait_ready($recipe) ? '' : ' (still starting)');
}

function job_recipe_change(array $spec)
{
	list($record, $recipe) = job_installed_recipe($spec['target']);
	$data = $record['data'];
	$current = store_recipe_values($record, $recipe);
	list($values, $errors) = store_answers($recipe, isset($spec['answers']) ? $spec['answers'] : [], $current, 'change');
	if ($errors) {
		job_fail('Some settings aren\'t valid: ' . implode('; ', $errors));
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
	$record['values'] = store_public_values($recipe, $values);
	unset($record['data']);
	store_write_json($data . '/.store/installed.json', $record);
	return 'The settings of ' . $recipe['name'] . ' were changed' . (job_wait_ready($recipe) ? '' : ' (still starting)');
}

function job_recipe_uninstall(array $spec)
{
	list($record, $recipe) = job_installed_recipe($spec['target']);
	$data = $record['data'];
	$values = store_recipe_values($record, $recipe);
	$env = store_env_values($recipe, $values);
	if (job_hook($recipe, $data, 'pre_uninstall', $env, job_store_env($spec, $data, $record['version'])) !== 0) {
		job_fail('Its pre_uninstall step failed');
	}
	job_log('Stopping and removing its containers');
	if (job_compose($recipe, $data, ['down']) !== 0) {
		job_fail('Docker could not remove its containers');
	}
	job_nginx($recipe, true);
	@unlink($data . '/.store/installed.json');
	$kept = [];
	// The folders chosen for deletion (only those the Store created, never those kept by the recipe)
	$keep = isset($recipe['uninstall']['keep']) && is_array($recipe['uninstall']['keep']) ? $recipe['uninstall']['keep'] : [];
	$delete = isset($spec['delete']) && is_array($spec['delete']) ? $spec['delete'] : [];
	foreach ($recipe['options'] as $option) {
		if ($option['type'] !== 'folder' || empty($option['create'])) {
			continue;
		}
		foreach ((array)$values[$option['key']] as $folder) {
			$inside = strpos($folder . '/', $data . '/') === 0;
			if (in_array($option['key'], $delete, true) && !in_array($option['key'], $keep, true) && !$inside && is_dir($folder)) {
				job_log('Deleting ' . $folder);
				store_rmtree($folder);
			} elseif (!$inside && is_dir($folder)) {
				$kept[] = $folder;
			}
		}
	}
	if (!empty($spec['delete_data'])) {
		job_log('Deleting ' . $data);
		store_rmtree($data);
	} else {
		$kept[] = $data . ' (its settings - installing it again reuses them)';
	}
	return $recipe['name'] . ' was removed' . ($kept ? '. Kept: ' . implode(', ', $kept) : '');
}

// ---------------------------------------------------------------------------------------------------------------------

try {
	$actions = [
		'app_install' => function ($spec) { return job_app_install($spec, false); },
		'app_update' => function ($spec) { return job_app_install($spec, true); },
		'app_uninstall' => 'job_app_uninstall',
		'recipe_install' => 'job_recipe_install',
		'recipe_update' => 'job_recipe_update',
		'recipe_change' => 'job_recipe_change',
		'recipe_uninstall' => 'job_recipe_uninstall',
	];
	if (!isset($actions[$spec['action']])) {
		job_fail('Unknown action');
	}
	job_log($spec['title']);
	$message = call_user_func($actions[$spec['action']], $spec);
	job_log($message);
	$status['state'] = 'done';
	$status['message'] = $message;
} catch (Exception $e) {
	job_log('Failed: ' . $e->getMessage());
	$status['state'] = 'failed';
	$status['message'] = $e->getMessage();
}
$status['finished'] = store_now();
store_write_json($jobs . '/status.json', $status);
