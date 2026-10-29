<?php
// The Store's core (see store/SPEC.md in the project): repositories and their catalogues, downloads checked against their
// checksums and signatures, what the NAS has, requirements, and recipes' options. Used by the management page (api.php)
// and the background jobs (job.php), through WD's PHP 7.4 or the PHP app's 8.5 - so it must work on both.

const STORE_FORMAT = 1;            // the store_version this Store reads
// The recipe hooks this Store runs (section 4 of store/SPEC.md)
const STORE_HOOKS = ['pre_install', 'post_install', 'pre_update', 'post_update', 'post_change', 'pre_uninstall'];
const STORE_RECIPE_FORMAT = 1;     // the recipe_version it reads
const STORE_DEFAULT_REPO = 'https://github.com/paul-norman/WD-NAS-App-Builder';
const STORE_UPLOAD_PATH = '/usr/local/apps_upload';
const STORE_APKG_XML = '/var/www/xml/apkg_all.xml';
const STORE_MODEL_FILE = '/usr/local/modules/files/model';
// Safe relative paths: no empty, . or .. parts, nothing but letters, digits, . _ and -
const STORE_PATH_PATTERN = '#^(?!(.*/)?\.\.?(/|$))[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$#';
const STORE_CATEGORIES = ['media', 'music', 'photos', 'books', 'backup', 'files', 'monitoring', 'network', 'security', 'development',
	'databases', 'productivity', 'home', 'system'];

// The first volume (STORE_TEST_VOLUME only replaces it in the project's tests, where Docker needs the same paths as the
// test machine)
function store_volume()
{
	$test = getenv('STORE_TEST_VOLUME');
	return $test !== false && $test !== '' ? rtrim($test, '/') : '/mnt/HD/HD_a2';
}

function store_apps_path()
{
	return store_volume() . '/Nas_Prog';
}

// The Store's own data (repositories, cached catalogues, jobs)
function store_data_path()
{
	return store_apps_path() . '/_store';
}

// ---------------------------------------------------------------------------------------------------------------------
// Small helpers

// Runs a command without a shell, with optional extra environment and working folder. Returns [exit code, output] (-1 if it
// couldn't be run - e.g. a program this NAS doesn't have; PHP 8 would also warn about that, hence the @)
function store_run(array $command, array $env = [], $cwd = null, $input = '')
{
	$env += ['PATH' => '/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin', 'HOME' => getenv('HOME') ?: '/root'];
	// (a program given by name is found in that PATH: PHP looks for it in the web server's own environment, which PHP-FPM
	// clears - leaving only /bin:/usr/bin, without e.g. /sbin/ip)
	if (strpos($command[0], '/') === false) {
		foreach (explode(':', $env['PATH']) as $dir) {
			if ($dir !== '' && is_file($dir . '/' . $command[0]) && is_executable($dir . '/' . $command[0])) {
				$command[0] = $dir . '/' . $command[0];
				break;
			}
		}
	}
	$process = @proc_open($command, [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['redirect', 1]], $pipes, $cwd, $env);
	if (!is_resource($process)) {
		return [-1, 'could not run: ' . $command[0]];
	}
	fwrite($pipes[0], $input);
	fclose($pipes[0]);
	$output = stream_get_contents($pipes[1]);
	fclose($pipes[1]);
	return [proc_close($process), trim($output)];
}

function store_read_json($file)
{
	$data = json_decode((string)@file_get_contents($file), true);
	return is_array($data) ? $data : null;
}

// Writes a file in one step (a temporary file renamed over it), root-only unless a mode is given
function store_write($file, $contents, $mode = 0600)
{
	$temp = $file . '.tmp' . getmypid();
	if (file_put_contents($temp, $contents) === false || !chmod($temp, $mode) || !rename($temp, $file)) {
		@unlink($temp);
		return false;
	}
	return true;
}

function store_write_json($file, array $data, $mode = 0600)
{
	return store_write($file, json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) . "\n", $mode);
}

function store_mkdir($dir, $mode = 0700)
{
	return is_dir($dir) || mkdir($dir, $mode, true);
}

// Removes a folder and everything in it (without following links out of it)
function store_rmtree($path)
{
	if (is_link($path) || is_file($path)) {
		return @unlink($path);
	}
	if (!is_dir($path)) {
		return true;
	}
	foreach (scandir($path) ?: [] as $name) {
		if ($name !== '.' && $name !== '..') {
			store_rmtree($path . '/' . $name);
		}
	}
	return @rmdir($path);
}

function store_now()
{
	return gmdate('Y-m-d\TH:i:s\Z');
}

// Versions: dot-separated numbers first, then the rest (e.g. "3.3.5-2" > "3.3.5-1", "1.10" > "1.9")
function store_version_compare($a, $b)
{
	preg_match('/^(\d+(?:\.\d+)*)?(.*)$/s', (string)$a, $ma);
	preg_match('/^(\d+(?:\.\d+)*)?(.*)$/s', (string)$b, $mb);
	$na = $ma[1] !== '' ? array_map('intval', explode('.', $ma[1])) : [];
	$nb = $mb[1] !== '' ? array_map('intval', explode('.', $mb[1])) : [];
	for ($i = 0, $n = max(count($na), count($nb)); $i < $n; $i++) {
		$x = isset($na[$i]) ? $na[$i] : 0;
		$y = isset($nb[$i]) ? $nb[$i] : 0;
		if ($x !== $y) {
			return $x < $y ? -1 : 1;
		}
	}
	return max(-1, min(1, strnatcmp($ma[2], $mb[2])));
}

// ---------------------------------------------------------------------------------------------------------------------
// Downloads (HTTPS only, also after redirects - e.g. GitHub's release downloads)

// Downloads a URL to a file, up to $max_bytes. Returns '' or an error message
function store_download($url, $file, $max_bytes, $timeout = 60)
{
	if (!store_is_https_url($url)) {
		return 'Not an HTTPS address: ' . $url;
	}
	list($code, $output) = store_run(['curl', '-sS', '-f', '-L', '--proto', '=https', '--proto-redir', '=https',
		'--max-redirs', '5', '--connect-timeout', '15', '-m', (string)$timeout, '--max-filesize', (string)$max_bytes,
		'-A', 'WD-NAS-Store/1', '-o', $file, $url]);
	if ($code !== 0) {
		@unlink($file);
		return 'Download failed (' . $url . '): ' . ($output !== '' ? $output : 'curl exit code ' . $code);
	}
	if (filesize($file) > $max_bytes) {
		@unlink($file);
		return 'Download too large: ' . $url;
	}
	return '';
}

function store_is_https_url($url)
{
	return is_string($url) && preg_match('#^https://[A-Za-z0-9.-]+(:\d{1,5})?(/[^\s"\'<>\\\\`]*)?$#', $url) === 1;
}

// A URL from a catalogue: absolute (HTTPS) or relative to the base (no . or .. parts). Returns '' if it isn't allowed
function store_resolve_url($url, $base)
{
	if (!is_string($url)) {
		return '';
	}
	if (strpos($url, 'https://') === 0) {
		return store_is_https_url($url) ? $url : '';
	}
	return preg_match(STORE_PATH_PATTERN, $url) ? $base . $url : '';
}

// ---------------------------------------------------------------------------------------------------------------------
// Signatures (Ed25519, section 6 of the spec): PHP's sodium, else the PHP app's PHP (which has it), else OpenSSL 3

// The raw 32-byte key from "ed25519:<base64 SubjectPublicKeyInfo>", or null
function store_key_raw($key)
{
	if (!is_string($key) || strpos($key, 'ed25519:') !== 0) {
		return null;
	}
	$der = base64_decode(substr($key, 8), true);
	$prefix = hex2bin('302a300506032b6570032100');
	return $der !== false && strlen($der) === 44 && strpos($der, $prefix) === 0 ? substr($der, 12) : null;
}

// A short fingerprint to show (and compare by eye)
function store_key_fingerprint($key)
{
	$raw = store_key_raw($key);
	return $raw === null ? '' : implode(':', str_split(substr(hash('sha256', $raw), 0, 32), 4));
}

// Whether $signature (base64) is a valid signature of $data by $key: true, false, or null if nothing here can check
function store_verify($data, $signature, $key)
{
	$raw = store_key_raw($key);
	$sig = base64_decode(trim((string)$signature), true);
	if ($raw === null || $sig === false || strlen($sig) !== 64) {
		return false;
	}
	if (function_exists('sodium_crypto_sign_verify_detached')) {
		return sodium_crypto_sign_verify_detached($sig, $data, $raw);
	}
	$temp = sys_get_temp_dir() . '/store-verify-' . bin2hex(random_bytes(8));
	mkdir($temp, 0700);
	file_put_contents($temp . '/data', $data);
	file_put_contents($temp . '/sig', $sig);
	$result = null;
	$php = store_apps_path() . '/php/binaries/php';
	if (is_executable($php)) {
		$code = 'exit(sodium_crypto_sign_verify_detached(file_get_contents($argv[1]), file_get_contents($argv[2]), hex2bin($argv[3])) ? 0 : 1);';
		list($exit) = store_run([$php, '-n', '-r', $code, $temp . '/sig', $temp . '/data', bin2hex($raw)]);
		$result = $exit === 0 ? true : ($exit === 1 ? false : null);
	}
	if ($result === null) {
		list(, $version) = store_run(['openssl', 'version']);
		if (preg_match('/^OpenSSL ([3-9])\./', $version)) {
			$pem = "-----BEGIN PUBLIC KEY-----\n" . chunk_split(substr($key, 8), 64, "\n") . "-----END PUBLIC KEY-----\n";
			file_put_contents($temp . '/key.pem', $pem);
			list($exit) = store_run(['openssl', 'pkeyutl', '-verify', '-pubin', '-inkey', $temp . '/key.pem', '-rawin',
				'-in', $temp . '/data', '-sigfile', $temp . '/sig']);
			$result = $exit === 0;
		}
	}
	store_rmtree($temp);
	return $result;
}

// ---------------------------------------------------------------------------------------------------------------------
// Repositories

// Where a repository's store.json is read from: a GitHub repository's raw file (its default branch, or /tree/<branch>),
// or the HTTPS URL itself (store.json added to one ending in /). Returns '' if it isn't usable
function store_repo_json_url($url)
{
	$url = trim($url);
	if (preg_match('#^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?(?:/tree/([A-Za-z0-9_./-]+?))?/?$#', $url, $m)) {
		$branch = isset($m[3]) && $m[3] !== '' ? $m[3] : 'HEAD';
		return "https://raw.githubusercontent.com/{$m[1]}/{$m[2]}/{$branch}/store.json";
	}
	if (!store_is_https_url($url) || strpos($url, '?') !== false || strpos($url, '#') !== false) {
		return '';
	}
	return substr($url, -1) === '/' ? $url . 'store.json' : $url;
}

// The repositories added (the default one first, unless removed)
function store_repos()
{
	$data = store_read_json(store_data_path() . '/repos.json');
	if ($data === null) {
		$data = ['repos' => [['url' => STORE_DEFAULT_REPO, 'key' => null, 'added' => store_now()]]];
	}
	return $data['repos'];
}

function store_save_repos(array $repos)
{
	return store_write_json(store_data_path() . '/repos.json', ['repos' => array_values($repos)]);
}

// A repository's cache folder (by its URL)
function store_repo_cache($url)
{
	return store_data_path() . '/cache/' . substr(hash('sha256', $url), 0, 16);
}

// Fetches a repository's store.json (and signature), checks it and caches it. Returns ['ok' => bool, 'error' => ...,
// 'store' => the catalogue, 'key' => the key it offers (for a new repository)]. $pinned_key: the key it must be signed with
function store_fetch_repo($url, $pinned_key)
{
	$json_url = store_repo_json_url($url);
	if ($json_url === '') {
		return ['ok' => false, 'error' => 'Not a repository address (an HTTPS URL of a store.json, or a GitHub repository)'];
	}
	$temp = store_data_path() . '/tmp-' . bin2hex(random_bytes(6));
	store_mkdir($temp);
	$result = store_fetch_repo_into($json_url, $pinned_key, $temp);
	if ($result['ok']) {
		$cache = store_repo_cache($url);
		store_mkdir(dirname($cache));
		store_rmtree($cache . '.old');
		if (is_dir($cache)) {
			rename($cache, $cache . '.old');
		}
		store_write_json($temp . '/fetched.json', ['url' => $url, 'json_url' => $json_url, 'fetched' => store_now()]);
		rename($temp, $cache);
		store_rmtree($cache . '.old');
	} else {
		store_rmtree($temp);
	}
	return $result;
}

function store_fetch_repo_into($json_url, $pinned_key, $dir)
{
	$error = store_download($json_url, $dir . '/store.json', 8 << 20, 30);
	if ($error !== '') {
		return ['ok' => false, 'error' => $error];
	}
	$bytes = (string)file_get_contents($dir . '/store.json');
	$store = json_decode($bytes, true);
	if (!is_array($store)) {
		return ['ok' => false, 'error' => 'Its store.json isn\'t valid JSON'];
	}
	if (!isset($store['store_version']) || !is_int($store['store_version'])) {
		return ['ok' => false, 'error' => 'Its store.json has no store_version'];
	}
	if ($store['store_version'] > STORE_FORMAT) {
		return ['ok' => false, 'error' => 'It needs a newer Store (its format is version ' . $store['store_version'] . ')'];
	}
	$offered = isset($store['public_key']) && is_string($store['public_key']) ? $store['public_key'] : null;
	if ($offered !== null && store_key_raw($offered) === null) {
		return ['ok' => false, 'error' => 'Its public_key isn\'t an Ed25519 key'];
	}
	// Signed with the pinned key (or, for a new repository, with the key it offers)
	$key = $pinned_key !== null ? $pinned_key : $offered;
	if ($key !== null) {
		if ($pinned_key !== null && $offered !== $pinned_key) {
			return ['ok' => false, 'error' => 'Its signing key has changed', 'key_changed' => true, 'key' => $offered];
		}
		$sig_url = preg_replace('#store\.json$#', 'store.json.sig', $json_url);
		$error = $sig_url !== $json_url ? store_download($sig_url, $dir . '/store.json.sig', 4096, 30) : 'No signature address';
		if ($error !== '') {
			return ['ok' => false, 'error' => 'It is signed, but its signature couldn\'t be downloaded: ' . $error];
		}
		$valid = store_verify($bytes, (string)file_get_contents($dir . '/store.json.sig'), $key);
		if ($valid === null) {
			return ['ok' => false, 'error' => 'Its signature can\'t be checked on this NAS (install the PHP app, which can)'];
		}
		if (!$valid) {
			return ['ok' => false, 'error' => 'Its signature is not valid - store.json may have been changed'];
		}
	}
	$errors = store_check_catalogue($store);
	if ($errors) {
		return ['ok' => false, 'error' => 'Its store.json has errors: ' . implode('; ', array_slice($errors, 0, 5))];
	}
	return ['ok' => true, 'error' => '', 'store' => $store, 'key' => $offered];
}

// Checks what the Store relies on in a catalogue (the schema, store.schema.json, has the rest). Returns error messages
function store_check_catalogue(array $store)
{
	$errors = [];
	foreach (['name', 'summary', 'updated'] as $field) {
		if (!isset($store[$field]) || !is_string($store[$field]) || $store[$field] === '') {
			$errors[] = "no {$field}";
		}
	}
	if (isset($store['base_url']) && (!store_is_https_url($store['base_url']) || substr($store['base_url'], -1) !== '/')) {
		$errors[] = 'base_url must be an HTTPS URL ending in /';
	}
	$seen = [];
	foreach (isset($store['apps']) && is_array($store['apps']) ? $store['apps'] : [] as $i => $app) {
		$label = 'apps[' . $i . ']';
		$errors = array_merge($errors, store_check_entry($app, $label, '/^[A-Za-z0-9][A-Za-z0-9_-]*$/'));
		if (isset($app['id']) && is_string($app['id'])) {
			if (isset($seen['app:' . $app['id']])) {
				$errors[] = "{$label}: {$app['id']} is listed twice";
			}
			$seen['app:' . $app['id']] = true;
		}
		if (!isset($app['packages']) || !is_array($app['packages']) || !$app['packages']) {
			$errors[] = "{$label}: no packages";
			continue;
		}
		foreach ($app['packages'] as $package) {
			if (!is_array($package) || !isset($package['model'], $package['url'], $package['size'], $package['sha256'])
				|| !is_string($package['model']) || !preg_match('/^[A-Za-z0-9_-]+$/', $package['model'])
				|| !is_int($package['size']) || $package['size'] < 1
				|| !is_string($package['sha256']) || !preg_match('/^[0-9a-f]{64}$/', $package['sha256'])
				|| store_resolve_url($package['url'], 'https://x/') === '') {
				$errors[] = "{$label}: a package needs a model, an HTTPS or relative url, a size and a sha256";
				break;
			}
		}
		if (isset($app['data_folder']) && (!is_string($app['data_folder']) || !preg_match('/^[A-Za-z0-9_][A-Za-z0-9._-]*$/', $app['data_folder']))) {
			$errors[] = "{$label}: data_folder is a folder name in Nas_Prog";
		}
	}
	foreach (isset($store['recipes']) && is_array($store['recipes']) ? $store['recipes'] : [] as $i => $recipe) {
		$label = 'recipes[' . $i . ']';
		$errors = array_merge($errors, store_check_entry($recipe, $label, '/^[a-z0-9][a-z0-9_-]*$/'));
		if (isset($recipe['id']) && is_string($recipe['id'])) {
			if (isset($seen['recipe:' . $recipe['id']])) {
				$errors[] = "{$label}: {$recipe['id']} is listed twice";
			}
			$seen['recipe:' . $recipe['id']] = true;
		}
		if (!isset($recipe['path']) || !is_string($recipe['path']) || substr($recipe['path'], -1) !== '/'
			|| !preg_match(STORE_PATH_PATTERN, rtrim($recipe['path'], '/'))) {
			$errors[] = "{$label}: path must be a relative folder ending in /";
		}
		if (!isset($recipe['files']) || !is_array($recipe['files']) || !isset($recipe['files']['recipe.json'])) {
			$errors[] = "{$label}: files must list recipe.json";
			continue;
		}
		foreach ($recipe['files'] as $name => $sha) {
			if (!is_string($name) || !preg_match(STORE_PATH_PATTERN, $name) || !is_string($sha) || !preg_match('/^[0-9a-f]{64}$/', $sha)) {
				$errors[] = "{$label}: files are relative paths (no . or .. parts) with a SHA256";
				break;
			}
		}
	}
	return $errors;
}

function store_check_entry($entry, $label, $id_pattern)
{
	if (!is_array($entry)) {
		return ["{$label}: not an object"];
	}
	$errors = [];
	if (!isset($entry['id']) || !is_string($entry['id']) || !preg_match($id_pattern, $entry['id'])) {
		$errors[] = "{$label}: id isn't valid";
	}
	foreach (['name', 'version', 'summary'] as $field) {
		if (!isset($entry[$field]) || !is_string($entry[$field]) || $entry[$field] === '') {
			$errors[] = "{$label}: no {$field}";
		}
	}
	if (isset($entry['version']) && is_string($entry['version']) && !preg_match('/^[0-9][0-9A-Za-z.+_-]*$/', $entry['version'])) {
		$errors[] = "{$label}: version isn't valid";
	}
	if (isset($entry['requires']) && !is_array($entry['requires'])) {
		$errors[] = "{$label}: requires must be an object";
	}
	return $errors;
}

// Every repository with its cached catalogue: [['url', 'key', 'added', 'store' => array|null, 'fetched', 'checked', 'base',
// 'error']] - fetched: when its catalogue was last read; checked: when it was last tried (also when that failed)
function store_repos_loaded()
{
	$list = [];
	foreach (store_repos() as $repo) {
		$cache = store_repo_cache($repo['url']);
		$fetched = store_read_json($cache . '/fetched.json');
		$store = $fetched !== null ? store_read_json($cache . '/store.json') : null;
		$base = '';
		if ($store !== null) {
			$base = isset($store['base_url']) ? $store['base_url'] : preg_replace('#[^/]*$#', '', $fetched['json_url']);
		}
		$status = store_read_json($cache . '.status.json');
		$list[] = $repo + [
			'store' => $store,
			'fetched' => $fetched !== null ? $fetched['fetched'] : '',
			'checked' => $status !== null && isset($status['checked']) ? $status['checked'] : '',
			'base' => $base,
			'error' => $status !== null ? $status['error'] : '',
			'key_changed' => $status !== null && !empty($status['key_changed']),
			'new_key' => $status !== null && isset($status['key']) ? $status['key'] : null,
		];
	}
	return $list;
}

// Whether any repository is due a check: never tried, or not in the last hour (the page then refreshes them by itself)
function store_repos_stale(array $loaded)
{
	foreach ($loaded as $repo) {
		if ($repo['checked'] === '' || time() - strtotime($repo['checked']) > 3600) {
			return true;
		}
	}
	return false;
}

// Refreshes every repository: [url => error] for those that failed
function store_refresh_all()
{
	$errors = [];
	foreach (store_repos() as $repo) {
		$error = store_refresh_repo($repo);
		if ($error !== '') {
			$errors[$repo['url']] = $error;
		}
	}
	return $errors;
}

// Refreshes one repository, remembering the outcome (an error keeps the previous catalogue). Returns the error, or ''
function store_refresh_repo(array $repo)
{
	$result = store_fetch_repo($repo['url'], isset($repo['key']) ? $repo['key'] : null);
	$status = ['checked' => store_now(), 'error' => $result['ok'] ? '' : $result['error']];
	if (!empty($result['key_changed'])) {
		$status['key_changed'] = true;
		$status['key'] = $result['key'];
	}
	$cache = store_repo_cache($repo['url']);
	store_mkdir(dirname($cache));
	store_write_json($cache . '.status.json', $status);
	if ($result['ok']) {
		store_cache_icons($repo['url']);
	}
	return $status['error'];
}

// Downloads the icons of a repository's apps and recipes (once per address; SVG or PNG, up to 256KB), so that the page
// shows them without the browser contacting the repository
function store_cache_icons($url)
{
	foreach (store_repos_loaded() as $repo) {
		if ($repo['url'] !== $url || $repo['store'] === null) {
			continue;
		}
		$dir = store_repo_cache($url) . '-icons';
		store_mkdir($dir);
		$index = store_read_json($dir . '/index.json') ?: [];
		$wanted = [];
		foreach (['apps', 'recipes'] as $kind) {
			foreach (isset($repo['store'][$kind]) && is_array($repo['store'][$kind]) ? array_slice($repo['store'][$kind], 0, 500) : [] as $entry) {
				$icon = isset($entry['icon']) ? store_resolve_url($entry['icon'], $repo['base']) : '';
				if ($icon === '' || !preg_match('#\.(svg|png)$#i', $icon, $m)) {
					continue;
				}
				$file = substr(hash('sha256', $icon), 0, 16) . '.' . strtolower($m[1]);
				$wanted[$icon] = $file;
				if (!isset($index[$icon]) && store_download($icon, $dir . '/' . $file, 256 << 10, 15) === '') {
					$index[$icon] = $file;
				}
			}
		}
		foreach (array_diff_key($index, $wanted) as $file) {
			@unlink($dir . '/' . $file);
		}
		store_write_json($dir . '/index.json', array_intersect_key($index, $wanted));
	}
}

// An entry's cached icon as a data: URL (or '')
function store_icon_data($repo, $entry)
{
	static $indexes = [];
	$icon = isset($entry['icon']) ? store_resolve_url($entry['icon'], $repo['base']) : '';
	if ($icon === '') {
		return '';
	}
	$dir = store_repo_cache($repo['url']) . '-icons';
	if (!isset($indexes[$dir])) {
		$indexes[$dir] = store_read_json($dir . '/index.json') ?: [];
	}
	if (!isset($indexes[$dir][$icon]) || !is_file($dir . '/' . $indexes[$dir][$icon])) {
		return '';
	}
	$file = $indexes[$dir][$icon];
	$type = substr($file, -4) === '.svg' ? 'image/svg+xml' : 'image/png';
	return 'data:' . $type . ';base64,' . base64_encode((string)file_get_contents($dir . '/' . $file));
}

// ---------------------------------------------------------------------------------------------------------------------
// The NAS

// What the NAS is and has (cached per request)
function store_nas()
{
	static $nas = null;
	if ($nas !== null) {
		return $nas;
	}
	$machine = php_uname('m');
	$mem = 0;
	if (preg_match('/^MemTotal:\s+(\d+)/m', (string)@file_get_contents('/proc/meminfo'), $m)) {
		$mem = (int)($m[1] / 1024);
	}
	$free = @disk_free_space(store_volume());
	$nas = [
		'model' => trim((string)@file_get_contents(STORE_MODEL_FILE)),
		'arch' => in_array($machine, ['x86_64', 'amd64'], true) ? 'amd64' : (strpos($machine, 'arm') === 0 ? 'armhf' : $machine),
		'firmware' => store_firmware(),
		'ram_mb' => $mem,
		'disk_mb' => $free !== false ? (int)($free / 1048576) : 0,
		'apps' => store_installed_apps(),
		'hostname' => (string)gethostname(),
		'timezone' => store_timezone(),
		'ip' => store_ip(),
	];
	return $nas;
}

// The firmware version (OS5 keeps it in /etc/version, e.g. 5.33.102), or '' when it isn't found (WD's installer checks it
// too)
function store_firmware()
{
	foreach (['/etc/version', '/usr/local/modules/files/version', '/etc/fw_version'] as $file) {
		if (preg_match('/(\d+\.\d+\.\d+)/', (string)@file_get_contents($file), $m)) {
			return $m[1];
		}
	}
	return '';
}

function store_timezone()
{
	if (preg_match('/^\s*date\.timezone\s*=\s*"?([A-Za-z0-9_+\/-]+)/m', (string)@file_get_contents('/etc/php/php.ini'), $m)) {
		return $m[1];
	}
	$tz = date_default_timezone_get();
	return $tz !== '' ? $tz : 'UTC';
}

function store_ip()
{
	list(, $output) = store_run(['ip', '-o', '-4', 'addr', 'show', 'scope', 'global']);
	return preg_match('/\binet (\d+\.\d+\.\d+\.\d+)\//', $output, $m) ? $m[1] : '';
}

// Installed apps, from WD's list: [id => ['version', 'enabled', 'name']]
function store_installed_apps()
{
	$apps = [];
	$xml = (string)@file_get_contents(STORE_APKG_XML);
	// (each app is an <item> holding <name>, <show>, <version>, <enable>, <center_type> ... - read leniently)
	if (preg_match_all('#<item>(.*?)</item>#s', $xml, $items)) {
		foreach ($items[1] as $item) {
			$field = function ($tag) use ($item) {
				return preg_match('#<' . $tag . '>([^<]*)</' . $tag . '>#i', $item, $m) ? trim(html_entity_decode($m[1], ENT_QUOTES | ENT_XML1, 'UTF-8')) : '';
			};
			$id = $field('name');
			if ($id === '') {
				continue;
			}
			// (the version in the app's own apkg.rc: WD's list can lag behind an update - e.g. the Store's update of itself)
			$rc = (string)@file_get_contents(store_apps_path() . '/' . basename($id) . '/apkg.rc');
			$version = preg_match('/^Version:[ \t]*(\S+)/m', $rc, $m) ? $m[1] : $field('version');
			$apps[$id] = ['version' => $version, 'enabled' => $field('enable') === '1', 'name' => $field('show'),
				'center_type' => $field('center_type'), 'url' => $field('url'), 'url_port' => $field('url_port'),
				'icon' => $field('icon'), 'description' => $field('description'), 'installed' => $field('inst_date'),
				'depends' => array_values(array_filter(array_map('trim', preg_split('/[,\s]+/', $field('inst_depend'))), 'strlen')),
				'hidden' => strtolower($field('Hidden')) === 'on'];
		}
	}
	return $apps;
}

// The installed apps that need the given one (their InstDepend lists it)
function store_dependent_apps($id)
{
	$names = [];
	foreach (store_installed_apps() as $other => $app) {
		if ($other !== $id && in_array($id, $app['depends'], true)) {
			$names[] = $app['name'] ?: $other;
		}
	}
	return $names;
}

// An installed app's description: its desc.xml in English (as the NAS's Apps page shows it), else apkg.rc's
function store_app_description($id, array $app)
{
	foreach (['/var/www/apps/' . $id . '/desc.xml', '/var/www/' . $id . '/desc.xml'] as $file) {
		if (preg_match('#<en-US>(.*?)</en-US>#s', (string)@file_get_contents($file), $m)) {
			return trim(html_entity_decode(strip_tags($m[1]), ENT_QUOTES | ENT_XML1, 'UTF-8'));
		}
	}
	return $app['description'];
}

// Docker: [present, memory_mb (0 = unknown), driver]
function store_docker($with_driver = false)
{
	list($code) = store_run(['docker', 'compose', 'version']);
	$limit = (string)@file_get_contents('/sys/fs/cgroup/memory/docker/memory.limit_in_bytes');
	$docker = ['present' => $code === 0, 'memory_mb' => ctype_digit(trim($limit)) ? (int)(trim($limit) / 1048576) : 0, 'driver' => ''];
	if ($with_driver && $docker['present']) {
		list(, $driver) = store_run(['docker', 'info', '--format', '{{.Driver}}']);
		$docker['driver'] = trim($driver);
	}
	return $docker;
}

// Checks requirements (section 5 of the spec). Returns [['level' => error|warning, 'message' => ...]]
function store_check_requires($requires, $label_of_app = null)
{
	$requires = is_array($requires) ? $requires : [];
	$nas = store_nas();
	$problems = [];
	$add = function ($level, $message) use (&$problems) {
		$problems[] = ['level' => $level, 'message' => $message];
	};
	if (!empty($requires['models']) && is_array($requires['models']) && !in_array($nas['model'], $requires['models'], true)) {
		$add('error', 'It doesn\'t support this NAS (' . ($nas['model'] ?: 'unknown model') . ') - only: ' . implode(', ', $requires['models']));
	}
	if (!empty($requires['arch']) && $requires['arch'] !== $nas['arch']) {
		$add('error', 'It needs an ' . ($requires['arch'] === 'amd64' ? 'Intel (amd64)' : 'ARM') . ' NAS');
	}
	if (!empty($requires['firmware_min']) && $nas['firmware'] !== '' && store_version_compare($nas['firmware'], $requires['firmware_min']) < 0) {
		$add('error', 'It needs firmware ' . $requires['firmware_min'] . ' or later (this NAS has ' . $nas['firmware'] . ')');
	}
	if (!empty($requires['ram_mb']) && $nas['ram_mb'] > 0 && $nas['ram_mb'] < $requires['ram_mb'] * 0.95) {
		$add('error', 'It needs ' . store_mb($requires['ram_mb']) . ' of memory (this NAS has ' . store_mb($nas['ram_mb']) . ')');
	}
	if (!empty($requires['disk_mb']) && $nas['disk_mb'] < $requires['disk_mb']) {
		$add('error', 'It needs ' . store_mb($requires['disk_mb']) . ' of free space (there\'s ' . store_mb($nas['disk_mb']) . ')');
	}
	foreach (!empty($requires['apps']) && is_array($requires['apps']) ? $requires['apps'] : [] as $app) {
		if (!isset($nas['apps'][$app])) {
			$add('error', 'Install the ' . ($label_of_app ? $label_of_app($app) : $app) . ' app first');
		} elseif (!$nas['apps'][$app]['enabled']) {
			$add('error', 'Turn on the ' . ($label_of_app ? $label_of_app($app) : $app) . ' app first (it\'s installed, but off)');
		}
	}
	if (!empty($requires['docker_memory_mb']) || !empty($requires['storage_driver'])) {
		$docker = store_docker(!empty($requires['storage_driver']));
		if (!$docker['present']) {
			if (empty($requires['apps']) || !in_array('docker', $requires['apps'], true)) {
				$add('error', 'It needs Docker (the Docker app, running)');
			}
		} else {
			if (!empty($requires['docker_memory_mb']) && $docker['memory_mb'] > 0 && $docker['memory_mb'] < $requires['docker_memory_mb'] * 0.95) {
				$add('error', 'It needs ' . store_mb($requires['docker_memory_mb']) . ' of memory for Docker (Docker may use '
					. store_mb($docker['memory_mb']) . ' - raise its share on the Docker app\'s page)');
			}
			// (overlayfs is Docker's containerd image store's name for the same overlay storage as overlay2)
			$driver = $docker['driver'] === 'overlayfs' ? 'overlay2' : $docker['driver'];
			if (!empty($requires['storage_driver']) && $driver !== '' && $driver !== $requires['storage_driver']) {
				$add('warning', 'Docker uses its ' . $docker['driver'] . ' storage driver here: this needs a lot more disk space and is slower than with ' . $requires['storage_driver']);
			}
		}
	}
	return $problems;
}

// A size in bytes, for messages (e.g. 365KB, 29MB, 1.2GB)
function store_size($bytes)
{
	return $bytes < 1048576 ? max(1, (int)ceil($bytes / 1024)) . 'KB' : store_mb((int)round($bytes / 1048576));
}

function store_mb($mb)
{
	return $mb >= 1024 ? rtrim(rtrim(number_format($mb / 1024, 1), '0'), '.') . 'GB' : $mb . 'MB';
}

// ---------------------------------------------------------------------------------------------------------------------
// The catalogue: every repository's apps and recipes, with what's installed

// [repo index, entry] of an app or recipe by repository URL and id
function store_find($kind, $repo_url, $id)
{
	foreach (store_repos_loaded() as $repo) {
		if ($repo['url'] !== $repo_url || $repo['store'] === null) {
			continue;
		}
		foreach (isset($repo['store'][$kind]) && is_array($repo['store'][$kind]) ? $repo['store'][$kind] : [] as $entry) {
			if (isset($entry['id']) && $entry['id'] === $id) {
				return [$repo, $entry];
			}
		}
	}
	return [null, null];
}

// Apps installed by the Store: [id => ['repo', 'version', 'installed']]
function store_installed_by_store()
{
	$data = store_read_json(store_data_path() . '/installed_apps.json');
	return $data !== null ? $data : [];
}

function store_record_app($id, $repo_url, $version)
{
	$data = store_installed_by_store();
	if ($repo_url === null) {
		unset($data[$id]);
	} else {
		$data[$id] = ['repo' => $repo_url, 'version' => $version, 'installed' => store_now()];
	}
	return store_write_json(store_data_path() . '/installed_apps.json', $data);
}

// Installed recipes: [id => installed.json + ['data' => folder]], from Nas_Prog/*/.store/installed.json
function store_installed_recipes()
{
	$recipes = [];
	foreach (glob(store_apps_path() . '/*/.store/installed.json') ?: [] as $file) {
		$record = store_read_json($file);
		if ($record !== null && isset($record['id'])) {
			$recipes[$record['id']] = $record + ['data' => dirname(dirname($file))];
		}
	}
	return $recipes;
}

// ---------------------------------------------------------------------------------------------------------------------
// Recipes: files, options and .env

// Downloads a recipe's files into $dir, checking each one's SHA256 and that it stays inside $dir. Returns '' or an error
function store_fetch_recipe(array $repo, array $entry, $dir)
{
	// (its folder ends in /)
	$base = store_resolve_url(rtrim($entry['path'], '/'), $repo['base']);
	if ($base === '' || substr($entry['path'], -1) !== '/') {
		return 'The recipe\'s path isn\'t allowed';
	}
	$base .= '/';
	store_mkdir($dir);
	$root = realpath($dir);
	foreach ($entry['files'] as $name => $sha256) {
		if (!preg_match(STORE_PATH_PATTERN, $name)) {
			return 'A file name isn\'t allowed: ' . $name;
		}
		$target = $root . '/' . $name;
		store_mkdir(dirname($target));
		$real = realpath(dirname($target));
		if ($real === false || ($real !== $root && strpos($real . '/', $root . '/') !== 0)) {
			return 'A file would be outside the recipe\'s folder: ' . $name;
		}
		$error = store_download($base . $name, $target, 4 << 20, 60);
		if ($error !== '') {
			return $error;
		}
		if (!hash_equals($sha256, hash_file('sha256', $target))) {
			return 'A file doesn\'t match its checksum (it may have been changed): ' . $name;
		}
	}
	return '';
}

// Reads and checks a downloaded recipe.json. Returns [recipe, error]
function store_load_recipe($dir, array $entry)
{
	$recipe = store_read_json($dir . '/recipe.json');
	if ($recipe === null) {
		return [null, 'Its recipe.json isn\'t valid JSON'];
	}
	if (!isset($recipe['recipe_version']) || !is_int($recipe['recipe_version'])) {
		return [null, 'Its recipe.json has no recipe_version'];
	}
	if ($recipe['recipe_version'] > STORE_RECIPE_FORMAT) {
		return [null, 'It needs a newer Store (recipe format ' . $recipe['recipe_version'] . ')'];
	}
	$files = $entry['files'];
	$errors = [];
	if (!isset($recipe['id']) || $recipe['id'] !== $entry['id']) {
		$errors[] = 'its id doesn\'t match the store\'s';
	}
	if (!isset($recipe['compose']) || !is_string($recipe['compose']) || !isset($files[$recipe['compose']])) {
		$errors[] = 'compose must be one of its files';
	}
	if (isset($recipe['description']) && (!is_string($recipe['description']) || !isset($files[$recipe['description']]))) {
		$errors[] = 'description must be one of its files';
	}
	if (!isset($recipe['project']) || !is_string($recipe['project']) || !preg_match('/^[a-z0-9][a-z0-9_-]*$/', $recipe['project'])) {
		$errors[] = 'project isn\'t valid';
	}
	if (!isset($recipe['data_folder']) || !is_string($recipe['data_folder']) || !preg_match('/^[A-Za-z0-9_][A-Za-z0-9._-]*$/', $recipe['data_folder'])) {
		$errors[] = 'data_folder isn\'t a folder name';
	}
	$hooks = isset($recipe['hooks']) && is_array($recipe['hooks']) ? $recipe['hooks'] : [];
	foreach ($hooks as $hook => $path) {
		// (hooks this Store doesn't know - a newer Store's - are ignored: it only ever runs those it knows)
		if (!in_array($hook, STORE_HOOKS, true)) {
			continue;
		}
		if (!is_string($path) || !isset($files[$path])) {
			$errors[] = 'its ' . $hook . ' hook isn\'t one of its files' . (is_string($path) ? ' (' . $path . ')' : '');
			break;
		}
	}
	if (isset($recipe['web'])) {
		$web = $recipe['web'];
		if (!is_array($web) || !isset($web['port']) || !is_int($web['port']) || $web['port'] < 1 || $web['port'] > 65535
			|| (isset($web['path']) && (!is_string($web['path']) || !preg_match('#^/[A-Za-z0-9._~/-]*$#', $web['path'])))
			|| (isset($web['ready_timeout']) && (!is_int($web['ready_timeout']) || $web['ready_timeout'] < 10 || $web['ready_timeout'] > 3600))
			|| (isset($web['nginx']) && (!is_array($web['nginx']) || !isset($web['nginx']['name']) || !is_string($web['nginx']['name'])
				|| !preg_match('/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/', $web['nginx']['name'])))) {
			$errors[] = 'web isn\'t valid';
		}
		// Its other sites in the Nginx app (e.g. each app of a stack): a name, a port, and optionally a label, a path, the
		// options and the boolean setting that switches it on (if)
		foreach (is_array($web) && isset($web['sites']) ? (is_array($web['sites']) ? $web['sites'] : [null]) : [] as $site) {
			if (!is_array($site) || !isset($site['name'], $site['port']) || !is_string($site['name']) || !preg_match('/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/', $site['name'])
				|| !is_int($site['port']) || $site['port'] < 1 || $site['port'] > 65535
				|| (isset($site['label']) && (!is_string($site['label']) || mb_strlen($site['label']) > 60))
				|| (isset($site['path']) && (!is_string($site['path']) || !preg_match('#^/[A-Za-z0-9._~/-]*$#', $site['path'])))
				|| (isset($site['if']) && (!is_string($site['if']) || !preg_match('/^[A-Z][A-Z0-9_]*$/', $site['if'])))) {
				$errors[] = 'web.sites isn\'t valid';
				break;
			}
		}
	}
	$keys = [];
	foreach (isset($recipe['options']) && is_array($recipe['options']) ? $recipe['options'] : [] as $option) {
		$error = store_check_option($option);
		if ($error !== '') {
			$errors[] = $error;
		} elseif (isset($keys[$option['key']])) {
			$errors[] = 'option ' . $option['key'] . ' is listed twice';
		}
		$keys[isset($option['key']) ? (string)$option['key'] : ''] = true;
	}
	return $errors ? [null, 'Its recipe.json has errors: ' . implode('; ', array_slice($errors, 0, 5))] : [$recipe, ''];
}

function store_check_option($option)
{
	$types = ['string', 'number', 'boolean', 'choice', 'folder', 'port', 'timezone', 'password', 'secret', 'hidden'];
	if (!is_array($option) || !isset($option['key'], $option['type']) || !is_string($option['key']) || !preg_match('/^[A-Z][A-Z0-9_]*$/', $option['key'])) {
		return 'an option has no valid key';
	}
	$key = $option['key'];
	if (!in_array($option['type'], $types, true)) {
		return "option {$key}: unknown type";
	}
	if (!in_array($option['type'], ['secret', 'hidden'], true) && (!isset($option['label']) || !is_string($option['label']))) {
		return "option {$key}: no label";
	}
	if ($option['type'] === 'choice' && (empty($option['choices']) || !is_array($option['choices']))) {
		return "option {$key}: no choices";
	}
	if ((!empty($option['multiple']) || isset($option['mount'])) && $option['type'] !== 'folder') {
		return "option {$key}: multiple and mount are only for folders";
	}
	if (!empty($option['multiple']) && !isset($option['mount'])) {
		return "option {$key}: multiple needs mount";
	}
	if (isset($option['mount'])) {
		$mount = $option['mount'];
		// (service: one of the compose file's services, or a list of them - the folder at the same path in each)
		$services = isset($mount['service']) ? (array)$mount['service'] : [];
		$named = array_filter($services, function ($service) {
			return is_string($service) && preg_match('/^[a-zA-Z0-9][a-zA-Z0-9._-]*$/', $service);
		});
		if (!is_array($mount) || !isset($mount['target']) || !$services || count($named) !== count($services)
			|| !is_string($mount['target']) || !preg_match(STORE_PATH_PATTERN, substr($mount['target'], 1)) || $mount['target'][0] !== '/') {
			return "option {$key}: mount isn't valid";
		}
	}
	if (isset($option['pattern']) && (!is_string($option['pattern']) || @preg_match(store_pattern($option['pattern']), '') === false)) {
		return "option {$key}: pattern isn't a valid regular expression";
	}
	return '';
}

// A recipe's pattern (a whole-value regular expression) as a PHP one
function store_pattern($pattern)
{
	return '~^(?:' . str_replace('~', '\~', $pattern) . ')$~u';
}

// Fills in a default's placeholders: {data} {volume} {share:Name} {nas:timezone|hostname|ip} {option:KEY}
function store_placeholders($value, array $recipe, array $values)
{
	if (!is_string($value)) {
		return $value;
	}
	$nas = store_nas();
	return preg_replace_callback('/\{(data|volume|share:[^{}\/]+|nas:(?:timezone|hostname|ip)|option:[A-Z][A-Z0-9_]*)\}/', function ($m) use ($recipe, $values, $nas) {
		if ($m[1] === 'data') {
			return store_apps_path() . '/' . $recipe['data_folder'];
		}
		if ($m[1] === 'volume') {
			return store_volume();
		}
		list($kind, $name) = explode(':', $m[1], 2);
		if ($kind === 'share') {
			return store_volume() . '/' . $name;
		}
		if ($kind === 'nas') {
			return (string)$nas[$name];
		}
		return isset($values[$name]) ? (is_array($values[$name]) ? '' : (string)$values[$name]) : '';
	}, $value);
}

// The wizard's view of a recipe's options: each with its default (or current value), without secrets
function store_wizard(array $recipe, ?array $current = null, $mode = 'install')
{
	$values = [];
	$fields = [];
	foreach (isset($recipe['options']) ? $recipe['options'] : [] as $option) {
		$key = $option['key'];
		$has_current = $current !== null && array_key_exists($key, $current);
		$value = $has_current ? $current[$key] : store_placeholders(isset($option['default']) ? $option['default'] : '', $recipe, $values);
		if ($option['type'] === 'boolean') {
			$value = store_boolean_value($option, $value);
		}
		if (!empty($option['multiple'])) {
			$value = is_array($value) ? $value : store_split_folders((string)$value);
		}
		$values[$key] = $value;
		if (in_array($option['type'], ['secret', 'hidden'], true)) {
			continue;
		}
		if ($mode !== 'install' && !empty($option['install_only'])) {
			continue;
		}
		// (only new options are asked on updates)
		if ($mode === 'update' && $has_current) {
			continue;
		}
		$field = array_intersect_key($option, array_flip(['key', 'type', 'label', 'help', 'advanced', 'pattern', 'max_length',
			'min_length', 'min', 'max', 'choices', 'on_share', 'create', 'empty', 'multiple', 'mount']));
		$field['required'] = isset($option['required']) ? (bool)$option['required'] : true;
		$field['value'] = $option['type'] === 'password' ? '' : $value;
		if ($option['type'] === 'password' && $has_current) {
			$field['saved'] = true;
		}
		if (!empty($option['mount'])) {
			$field['mounted_as'] = [];
			foreach ((array)$value as $folder) {
				if ($folder !== '') {
					$field['mounted_as'][$folder] = store_mount_target($option['mount']['target'], $folder);
				}
			}
		}
		$fields[] = $field;
	}
	return $fields;
}

function store_boolean_value(array $option, $value)
{
	$values = isset($option['values']) && is_array($option['values']) && count($option['values']) === 2 ? $option['values'] : ['true', 'false'];
	if (is_bool($value)) {
		return $value;
	}
	return (string)$value === (string)$values[0];
}

function store_split_folders($value)
{
	return array_values(array_filter(array_map('trim', explode('|', $value)), 'strlen'));
}

// Where a mounted folder appears in its container: target + its path relative to the first volume (or to /mnt)
function store_mount_target($target, $folder)
{
	$volume = store_volume() . '/';
	$relative = strpos($folder, $volume) === 0 ? substr($folder, strlen($volume)) : preg_replace('#^/mnt/#', '', $folder);
	return rtrim($target, '/') . '/' . $relative;
}

// Whether a folder is on a share: in the first volume (not Nas_Prog or a hidden system folder), another volume, or a USB
// drive. Returns '' or why not
function store_check_share_folder($folder)
{
	$volume = store_volume();
	$shares = '#^(' . preg_quote($volume, '#') . '|/mnt/HD/HD_[a-z][0-9]+|/mnt/USB/[A-Za-z0-9_]+)/([^/.][^/]*)(/.*)?$#';
	if (!preg_match($shares, $folder, $m)) {
		return 'It must be a folder on one of the NAS\'s shares (e.g. ' . $volume . '/Photos)';
	}
	if ($m[2] === 'Nas_Prog') {
		return 'It must be on a share, not in Nas_Prog (the apps\' folder)';
	}
	return '';
}

// Checks the wizard's answers against a recipe's options. $current: the values already installed (updates and changes).
// Returns [values (for .env), errors (key => message)]
function store_answers(array $recipe, array $answers, ?array $current = null, $mode = 'install')
{
	$values = [];
	$errors = [];
	foreach (isset($recipe['options']) ? $recipe['options'] : [] as $option) {
		$key = $option['key'];
		$type = $option['type'];
		$has_current = $current !== null && array_key_exists($key, $current);
		$asked = !in_array($type, ['secret', 'hidden'], true) && !($mode !== 'install' && !empty($option['install_only']))
			&& !($mode === 'update' && $has_current);
		$default = store_placeholders(isset($option['default']) ? $option['default'] : '', $recipe, $values);
		if (!$asked) {
			if ($has_current) {
				$values[$key] = $current[$key];
			} elseif ($type === 'secret') {
				$values[$key] = store_secret(isset($option['generate']) ? $option['generate'] : []);
			} elseif ($type === 'boolean') {
				$values[$key] = store_boolean_value($option, $default);
			} else {
				$values[$key] = !empty($option['multiple']) ? store_split_folders((string)$default) : $default;
			}
			continue;
		}
		$value = array_key_exists($key, $answers) ? $answers[$key] : null;
		$required = isset($option['required']) ? (bool)$option['required'] : true;
		list($value, $error) = store_answer($option, $value, $required, $has_current ? $current[$key] : null);
		if ($error !== '') {
			$errors[$key] = $error;
		}
		$values[$key] = $value;
	}
	return [$values, $errors];
}

function store_answer(array $option, $value, $required, $current)
{
	$type = $option['type'];
	if ($type === 'boolean') {
		return [$value === true || $value === 'true' || $value === '1' || $value === 1, ''];
	}
	if ($type === 'folder' && !empty($option['multiple'])) {
		$folders = is_array($value) ? $value : store_split_folders((string)$value);
		$clean = [];
		foreach ($folders as $folder) {
			list($folder, $error) = store_answer(['multiple' => false] + $option, $folder, true, null);
			if ($error !== '') {
				return [$folders, $error];
			}
			if (!in_array($folder, $clean, true)) {
				$clean[] = $folder;
			}
		}
		if ($required && !$clean) {
			return [$clean, 'Choose at least one folder'];
		}
		return [$clean, ''];
	}
	if (!is_string($value) && !is_int($value)) {
		$value = '';
	}
	$value = trim((string)$value);
	if ($type === 'password' && $value === '' && $current !== null) {
		return [$current, ''];
	}
	if (preg_match('/[\x00-\x1f\x7f]/', $value)) {
		return [$value, 'It can\'t contain line breaks or control characters'];
	}
	if ($value === '') {
		return [$value, $required ? 'This is needed' : ''];
	}
	switch ($type) {
		case 'string':
			if (isset($option['max_length']) && mb_strlen($value) > $option['max_length']) {
				return [$value, 'Up to ' . $option['max_length'] . ' characters'];
			}
			if (isset($option['pattern']) && !preg_match(store_pattern($option['pattern']), $value)) {
				return [$value, 'Not in the expected format'];
			}
			return [$value, ''];
		case 'number':
		case 'port':
			if (!preg_match('/^-?\d{1,9}$/', $value)) {
				return [$value, 'A whole number'];
			}
			$number = (int)$value;
			$min = isset($option['min']) ? $option['min'] : ($type === 'port' ? 1 : null);
			$max = isset($option['max']) ? $option['max'] : ($type === 'port' ? 65535 : null);
			if (($min !== null && $number < $min) || ($max !== null && $number > $max)) {
				return [$value, 'Between ' . $min . ' and ' . $max];
			}
			if ($type === 'port' && (string)$current !== $value && store_port_in_use($number)) {
				return [$value, 'Something on the NAS already uses port ' . $number];
			}
			return [(string)$number, ''];
		case 'choice':
			foreach ($option['choices'] as $choice) {
				if (isset($choice['value']) && (string)$choice['value'] === $value) {
					return [$value, ''];
				}
			}
			return [$value, 'Choose one of the options'];
		case 'timezone':
			return [$value, in_array($value, DateTimeZone::listIdentifiers(), true) || $value === 'UTC' ? '' : 'Not a time zone (e.g. Europe/London)'];
		case 'password':
			$min = isset($option['min_length']) ? $option['min_length'] : 1;
			return [$value, mb_strlen($value) < $min ? 'At least ' . $min . ' characters' : ''];
		case 'folder':
			return store_answer_folder($option, $value);
	}
	return [$value, ''];
}

function store_answer_folder(array $option, $folder)
{
	$folder = rtrim($folder, '/');
	if ($folder === '' || $folder[0] !== '/' || preg_match('#(^|/)\.\.?(/|$)|//|\|#', $folder) || preg_match('/["\\\\`$]/', $folder)) {
		return [$folder, 'A full folder path (e.g. ' . store_volume() . '/Photos), without . or .. parts, quotes, $ or |'];
	}
	if (!empty($option['on_share']) || isset($option['mount'])) {
		$error = store_check_share_folder($folder);
		if ($error !== '') {
			return [$folder, $error];
		}
	} elseif (strpos($folder . '/', '/mnt/') !== 0) {
		return [$folder, 'A folder on the NAS\'s disks (in /mnt)'];
	}
	if (is_dir($folder)) {
		// (where it really is: not, through a link, somewhere else)
		$real = realpath($folder);
		if ((!empty($option['on_share']) || isset($option['mount'])) && store_check_share_folder($real) !== '') {
			return [$folder, 'It leads outside the NAS\'s shares'];
		}
		if (!empty($option['empty']) && count(scandir($folder)) > 2) {
			return [$folder, 'It must be a new or empty folder'];
		}
	} elseif (file_exists($folder)) {
		return [$folder, 'It isn\'t a folder'];
	} elseif (empty($option['create'])) {
		return [$folder, 'No such folder'];
	} else {
		// (to be created: its share must exist - shares are made in the NAS dashboard, so that they're shared)
		if (preg_match('#^(' . preg_quote(store_volume(), '#') . '|/mnt/HD/HD_[a-z][0-9]+|/mnt/USB/[A-Za-z0-9_]+)/[^/]+#', $folder, $m) && !is_dir($m[0])) {
			return [$folder, 'The share ' . basename($m[0]) . ' doesn\'t exist - create it in the NAS dashboard (Shares) first'];
		}
	}
	return [$folder, ''];
}

function store_port_in_use($port)
{
	$socket = @fsockopen('127.0.0.1', $port, $errno, $errstr, 0.5);
	if ($socket) {
		fclose($socket);
		return true;
	}
	return false;
}

function store_secret($generate)
{
	$length = isset($generate['length']) ? max(8, min(128, (int)$generate['length'])) : 32;
	if (isset($generate['charset']) && $generate['charset'] === 'hex') {
		return substr(bin2hex(random_bytes($length)), 0, $length);
	}
	$chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
	$secret = '';
	while (strlen($secret) < $length) {
		$byte = ord(random_bytes(1));
		if ($byte < 248) {
			$secret .= $chars[$byte % 62];
		}
	}
	return $secret;
}

// The values as written to .env (booleans as their values, folders joined by |)
function store_env_values(array $recipe, array $values)
{
	$env = [];
	foreach (isset($recipe['options']) ? $recipe['options'] : [] as $option) {
		$key = $option['key'];
		$value = isset($values[$key]) ? $values[$key] : '';
		if ($option['type'] === 'boolean') {
			$pair = isset($option['values']) && is_array($option['values']) && count($option['values']) === 2 ? $option['values'] : ['true', 'false'];
			$value = $value ? $pair[0] : $pair[1];
		} elseif (is_array($value)) {
			$value = implode('|', $value);
		}
		$env[$key] = (string)$value;
	}
	return $env;
}

// .env's text: KEY=value, quoted where needed - single quotes (taken literally by Compose), or double quotes with
// escapes for values holding a single quote
function store_env_text(array $env, $title)
{
	$text = "# {$title} - written by the Store (change the settings there; edits here are kept until then)\n";
	foreach ($env as $key => $value) {
		if (preg_match('#^[A-Za-z0-9_./:@%+,=|-]*$#', $value)) {
			$text .= "{$key}={$value}\n";
		} elseif (strpos($value, "'") === false) {
			$text .= "{$key}='{$value}'\n";
		} else {
			$text .= $key . '="' . str_replace(['\\', '"', '$'], ['\\\\', '\\"', '\\$'], $value) . "\"\n";
		}
	}
	return $text;
}

// The folders given to the app by options with mount: [[label, folder on the NAS, where it is in the app], ...]
function store_mounts(array $recipe, array $values)
{
	$mounts = [];
	foreach (isset($recipe['options']) ? $recipe['options'] : [] as $option) {
		if (empty($option['mount']) || !isset($values[$option['key']])) {
			continue;
		}
		foreach ((array)$values[$option['key']] as $folder) {
			if ($folder !== '') {
				$mounts[] = [isset($option['label']) ? $option['label'] : $option['key'], $folder, store_mount_target($option['mount']['target'], $folder)];
			}
		}
	}
	return $mounts;
}

// compose.override.yaml for the options with mount (or '' when nothing is mounted)
function store_override_text(array $recipe, array $values)
{
	$services = [];
	foreach (isset($recipe['options']) ? $recipe['options'] : [] as $option) {
		if (empty($option['mount'])) {
			continue;
		}
		foreach ((array)(isset($values[$option['key']]) ? $values[$option['key']] : []) as $folder) {
			if ($folder === '') {
				continue;
			}
			$quote = function ($s) {
				return '"' . str_replace(['\\', '"', '$'], ['\\\\', '\\"', '$$'], $s) . '"';
			};
			foreach ((array)$option['mount']['service'] as $service) {
				$services[$service][] = "      - type: bind\n        source: " . $quote($folder)
					. "\n        target: " . $quote(store_mount_target($option['mount']['target'], $folder))
					. (!empty($option['mount']['read_only']) ? "\n        read_only: true" : '') . "\n";
			}
		}
	}
	if (!$services) {
		return '';
	}
	$text = "# Folders chosen in the Store's settings for this recipe - written by the Store (rewritten with them)\nservices:\n";
	foreach ($services as $service => $mounts) {
		$text .= "  {$service}:\n    volumes:\n" . implode('', $mounts);
	}
	return $text;
}

// The values worth keeping in installed.json (no secrets or passwords - they stay in .env only)
function store_public_values(array $recipe, array $values)
{
	$public = [];
	foreach (isset($recipe['options']) ? $recipe['options'] : [] as $option) {
		if (!in_array($option['type'], ['secret', 'password'], true) && array_key_exists($option['key'], $values)) {
			$public[$option['key']] = $values[$option['key']];
		}
	}
	return $public;
}

// The values of an installed recipe: installed.json's, plus the secrets and passwords from its .env
function store_recipe_values(array $installed, array $recipe)
{
	$values = isset($installed['values']) && is_array($installed['values']) ? $installed['values'] : [];
	$env = store_parse_env($installed['data'] . '/.env');
	foreach (isset($recipe['options']) ? $recipe['options'] : [] as $option) {
		if (in_array($option['type'], ['secret', 'password'], true) && isset($env[$option['key']])) {
			$values[$option['key']] = $env[$option['key']];
		}
	}
	return $values;
}

// Reads a .env file (as the Store writes them): [key => value]
function store_parse_env($file)
{
	$env = [];
	foreach (file($file, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
		if (!preg_match('/^([A-Z][A-Z0-9_]*)=(.*)$/', $line, $m)) {
			continue;
		}
		$value = $m[2];
		if (strlen($value) >= 2 && $value[0] === "'" && substr($value, -1) === "'") {
			$value = substr($value, 1, -1);
		} elseif (strlen($value) >= 2 && $value[0] === '"' && substr($value, -1) === '"') {
			$value = preg_replace_callback('/\\\\(.)/', function ($e) {
				return $e[1];
			}, substr($value, 1, -1));
		}
		$env[$m[1]] = $value;
	}
	return $env;
}

// Settings already in a recipe's folder (a previous install whose data was kept, or one set up by hand): reused, so that
// e.g. a database keeps its password. Returns [values or null, error]
function store_existing_settings(array $recipe)
{
	$data = store_apps_path() . '/' . $recipe['data_folder'];
	if (!is_dir($data)) {
		return [null, ''];
	}
	if (is_file($data . '/apkg.rc')) {
		return [null, $data . ' is an app\'s folder'];
	}
	$other = store_read_json($data . '/.store/installed.json');
	if ($other !== null && $other['id'] !== $recipe['id']) {
		return [null, $data . ' belongs to another recipe (' . $other['id'] . ')'];
	}
	foreach (store_installed_recipes() as $installed) {
		if ($installed['id'] !== $recipe['id'] && isset($installed['project']) && $installed['project'] === $recipe['project']) {
			return [null, 'Another recipe (' . $installed['id'] . ') uses the same Docker project name'];
		}
	}
	if (!is_file($data . '/.env')) {
		return [null, ''];
	}
	$env = store_parse_env($data . '/.env');
	$values = [];
	foreach (isset($recipe['options']) ? $recipe['options'] : [] as $option) {
		if (!array_key_exists($option['key'], $env)) {
			continue;
		}
		$value = $env[$option['key']];
		if ($option['type'] === 'boolean') {
			$value = store_boolean_value($option, $value);
		} elseif (!empty($option['multiple'])) {
			$value = store_split_folders($value);
		}
		$values[$option['key']] = $value;
	}
	return [$values, ''];
}

// ---------------------------------------------------------------------------------------------------------------------
// Descriptions: a small, safe subset of Markdown (everything escaped first; links only to HTTPS addresses)

function store_markdown($text)
{
	$h = function ($s) {
		return htmlspecialchars($s, ENT_QUOTES, 'UTF-8');
	};
	$inline = function ($s) use ($h) {
		$s = $h($s);
		$s = preg_replace('/`([^`]+)`/', '<code>$1</code>', $s);
		$s = preg_replace('/\*\*(.+?)\*\*/', '<strong>$1</strong>', $s);
		$s = preg_replace('/(?<![*\w])\*([^*]+)\*(?![*\w])/', '<em>$1</em>', $s);
		return preg_replace_callback('/\[([^\]]+)\]\((https:\/\/[^\s)"]+)\)/', function ($m) {
			return '<a href="' . $m[2] . '" target="_blank" rel="noopener noreferrer">' . $m[1] . '</a>';
		}, $s);
	};
	$html = '';
	$list = false;
	$paragraph = [];
	$flush = function () use (&$paragraph, &$html, $inline) {
		if ($paragraph) {
			$html .= '<p>' . $inline(implode(' ', $paragraph)) . "</p>\n";
			$paragraph = [];
		}
	};
	foreach (preg_split('/\r?\n/', (string)$text) as $line) {
		if (preg_match('/^\s*[-*]\s+(.*)$/', $line, $m)) {
			$flush();
			if (!$list) {
				$html .= "<ul>\n";
				$list = true;
			}
			$html .= '<li>' . $inline($m[1]) . "</li>\n";
			continue;
		}
		if ($list && preg_match('/^\s{2,}\S/', $line)) {
			// (a list item continued on the next line)
			$html = preg_replace('#</li>\n$#', ' ' . $inline(trim($line)) . "</li>\n", $html);
			continue;
		}
		if ($list) {
			$html .= "</ul>\n";
			$list = false;
		}
		if (trim($line) === '') {
			$flush();
		} elseif (preg_match('/^(#{1,4})\s+(.*)$/', $line, $m)) {
			$flush();
			$html .= '<h4>' . $inline($m[2]) . "</h4>\n";
		} else {
			$paragraph[] = trim($line);
		}
	}
	$flush();
	return $html . ($list ? "</ul>\n" : '');
}
