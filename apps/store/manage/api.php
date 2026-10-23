<?php
// Store actions (JSON), for NAS admins only - see manage_helpers.php. Long work (installs, updates, removals) runs as a
// background job (lib/job.php), which the page follows
require __DIR__ . '/manage_helpers.php';
manage_require_admin('store');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path = dirname(__DIR__);
require $app_path . '/lib/store.php';

$data_path = store_data_path();
$jobs = $data_path . '/jobs';
store_mkdir($jobs);

$action = isset($_GET['action']) ? $_GET['action'] : 'job';

// An installed recipe's part of its page: its settings, folders, address, and what can be deleted with it
function api_recipe_installed(array $installed, array $installed_recipe)
{
	$out = [];
	$current = store_recipe_values($installed, $installed_recipe);
	$out['installed'] = ['version' => $installed['version'], 'data' => $installed['data'], 'installed' => $installed['installed']];
	$out['settings'] = store_wizard($installed_recipe, $current, 'change');
	$out['mounts'] = store_mounts($installed_recipe, $current);
	$out['url'] = api_web_url(isset($installed_recipe['web']) ? $installed_recipe['web'] : null);
	// The folders that can be deleted along with it
	$keep = isset($installed_recipe['uninstall']['keep']) && is_array($installed_recipe['uninstall']['keep']) ? $installed_recipe['uninstall']['keep'] : [];
	$out['deletable'] = [];
	foreach ($installed_recipe['options'] as $option) {
		if ($option['type'] === 'folder' && !empty($option['create']) && !in_array($option['key'], $keep, true)) {
			foreach ((array)(isset($current[$option['key']]) ? $current[$option['key']] : []) as $folder) {
				if ($folder !== '' && strpos($folder . '/', $installed['data'] . '/') !== 0) {
					$out['deletable'][] = ['key' => $option['key'], 'label' => isset($option['label']) ? $option['label'] : $option['key'], 'folder' => $folder];
				}
			}
		}
	}
	$out['kept'] = [];
	foreach ($installed_recipe['options'] as $option) {
		if ($option['type'] === 'folder' && in_array($option['key'], $keep, true) && isset($current[$option['key']])) {
			$out['kept'] = array_merge($out['kept'], (array)$current[$option['key']]);
		}
	}
	return $out;
}

// Each repository's label: its name, with its owner (or host) added when another repository has the same name - e.g. a
// fork that kept the name. [url => label]
function api_repo_labels(array $loaded)
{
	$names = [];
	foreach ($loaded as $repo) {
		if ($repo['store'] !== null) {
			$names[] = $repo['store']['name'];
		}
	}
	$counts = array_count_values($names);
	$labels = [];
	foreach ($loaded as $repo) {
		$name = $repo['store'] !== null ? $repo['store']['name'] : '';
		$labels[$repo['url']] = $name !== '' && $counts[$name] > 1 ? $name . ' (' . api_repo_owner($repo['url']) . ')' : $name;
	}
	return $labels;
}

// A repository's owner on GitHub (from github.com/<owner>/... or raw.githubusercontent.com/<owner>/...), else its host
function api_repo_owner($url)
{
	$host = (string)parse_url($url, PHP_URL_HOST);
	$path = explode('/', trim((string)parse_url($url, PHP_URL_PATH), '/'));
	return in_array($host, ['github.com', 'raw.githubusercontent.com'], true) && $path[0] !== '' ? $path[0] : $host;
}

// Every app the NAS has installed (as its Apps page lists them), for the Installed tab: how to configure it, whether it runs
function api_installed_apps(array $installed, array $by_store)
{
	$apps = [];
	foreach ($installed as $id => $app) {
		if ($app['hidden']) {
			continue;
		}
		$id = (string)$id;
		$apps[] = [
			'id' => $id,
			'name' => $app['name'] ?: $id,
			'version' => $app['version'],
			'enabled' => $app['enabled'],
			// (CenterType 1: its page is shown inside the dashboard, from /apps/<id>/; otherwise it opens on its own port)
			'center_type' => $app['center_type'] === '1' ? 1 : 0,
			'url' => preg_match('#^[A-Za-z0-9._/?=&-]*$#', $app['url']) ? ltrim($app['url'], '/') : '',
			'url_port' => ctype_digit($app['url_port']) ? $app['url_port'] : '',
			'icon' => $app['icon'] !== '' && preg_match('#^[A-Za-z0-9._-]+$#', $app['icon'])
				? ($app['center_type'] === '1' ? '/apps/' : '/') . rawurlencode($id) . '/' . $app['icon'] : '',
			'description' => store_app_description($id, $app),
			'installed' => $app['installed'],
			'repo' => isset($by_store[$id]) ? $by_store[$id]['repo'] : '',
		];
	}
	usort($apps, function ($a, $b) {
		return strcasecmp($a['name'], $b['name']);
	});
	return $apps;
}

// The address of an installed app's or recipe's web interface: its Nginx site (if the Nginx app has it), else its port
function api_web_url($web)
{
	if (!is_array($web)) {
		return '';
	}
	if (isset($web['nginx']['name']) && is_string($web['nginx']['name']) && is_file(store_apps_path() . '/nginx/lib/sites.php')) {
		list($code, $url) = store_run(['php', store_apps_path() . '/nginx/lib/sites.php', 'url', store_apps_path() . '/_nginx', $web['nginx']['name']]);
		if ($code === 0 && store_is_https_url(trim($url))) {
			return trim($url);
		}
	}
	if (isset($web['port']) && is_int($web['port'])) {
		$path = isset($web['path']) && is_string($web['path']) && preg_match('#^/[A-Za-z0-9._~/-]*$#', $web['path']) ? $web['path'] : '/';
		return 'http://' . store_nas()['ip'] . ($web['port'] !== 80 ? ':' . $web['port'] : '') . $path;
	}
	return '';
}

// The current (or last) job, with the end of its log
function api_job($jobs)
{
	$status = store_read_json($jobs . '/status.json');
	if ($status !== null && $status['state'] === 'running' && !file_exists('/proc/' . (int)$status['pid'])) {
		$status['state'] = 'failed';
		$status['message'] = 'The job stopped unexpectedly';
	}
	$log = $status !== null ? (string)@file_get_contents($jobs . '/job.log') : '';
	$lines = explode("\n", rtrim($log));
	return ['job' => $status, 'log' => implode("\n", array_slice($lines, -200))];
}

function api_job_running($jobs)
{
	$job = api_job($jobs);
	return $job['job'] !== null && $job['job']['state'] === 'running';
}

// An app's or recipe's description: Markdown text, or a Markdown file in the repository (apps), or the recipe's own file
function api_description(array $repo, array $entry, $recipe_dir = null, $recipe = null)
{
	if ($recipe !== null && !empty($recipe['description'])) {
		return store_markdown((string)@file_get_contents($recipe_dir . '/' . $recipe['description']));
	}
	$text = isset($entry['description']) && is_string($entry['description']) ? $entry['description'] : '';
	if (preg_match('/\.md$/', $text) && ($url = store_resolve_url($text, $repo['base'])) !== '') {
		$file = tempnam(sys_get_temp_dir(), 'store');
		$text = store_download($url, $file, 256 << 10, 15) === '' ? (string)file_get_contents($file) : '';
		@unlink($file);
	}
	return store_markdown($text !== '' ? $text : $entry['summary']);
}

// Downloads a recipe for its page and wizard (into a preview folder, separate from a running job's)
function api_preview_recipe(array $repo, array $entry)
{
	$dir = store_data_path() . '/preview/' . substr(hash('sha256', $repo['url']), 0, 8) . '-' . $entry['id'];
	store_rmtree($dir);
	$error = store_fetch_recipe($repo, $entry, $dir);
	if ($error !== '') {
		return [null, $dir, $error];
	}
	list($recipe, $error) = store_load_recipe($dir, $entry);
	return [$recipe, $dir, $error];
}

function api_app_label($id)
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

if ($action === 'job') {
	manage_json(api_job($jobs));
}

if ($action === 'catalogue') {
	$nas = store_nas();
	$by_store = store_installed_by_store();
	$recipes_installed = store_installed_recipes();
	$repos = [];
	$apps = [];
	$recipes = [];
	$loaded = store_repos_loaded();
	$labels = api_repo_labels($loaded);
	// (where something was installed from, by its label - or its address, for a repository no longer read)
	$source_name = function ($url) use ($labels) {
		return $url === null ? '' : (isset($labels[$url]) && $labels[$url] !== '' ? $labels[$url] : $url);
	};
	foreach ($loaded as $index => $repo) {
		$store = $repo['store'];
		$repos[] = [
			'url' => $repo['url'],
			'default' => $repo['url'] === STORE_DEFAULT_REPO,
			'name' => $store !== null ? $labels[$repo['url']] : '',
			'summary' => $store !== null ? $store['summary'] : '',
			'homepage' => $store !== null && isset($store['homepage']) && store_is_https_url($store['homepage']) ? $store['homepage'] : '',
			'maintainer' => $store !== null && isset($store['maintainer']) ? (string)$store['maintainer'] : '',
			'updated' => $store !== null ? $store['updated'] : '',
			'fetched' => $repo['fetched'],
			'checked' => $repo['checked'],
			'error' => $repo['error'],
			'signed' => !empty($repo['key']),
			'fingerprint' => store_key_fingerprint($repo['key']),
			'key_changed' => $repo['key_changed'],
			'new_fingerprint' => $repo['key_changed'] ? store_key_fingerprint($repo['new_key']) : '',
			'apps' => $store !== null && isset($store['apps']) ? count($store['apps']) : 0,
			'recipes' => $store !== null && isset($store['recipes']) ? count($store['recipes']) : 0,
		];
		if ($store === null) {
			continue;
		}
		foreach (isset($store['apps']) ? $store['apps'] : [] as $app) {
			$id = $app['id'];
			$installed = isset($nas['apps'][$id]) ? $nas['apps'][$id] : null;
			$models = array_map(function ($p) {
				return $p['model'];
			}, $app['packages']);
			// Updates come from the repository it was installed from (or any, for apps installed otherwise)
			$from = isset($by_store[$id]) ? $by_store[$id]['repo'] : null;
			$apps[] = [
				'repo' => $repo['url'],
				'repo_name' => $labels[$repo['url']],
				// (the repository the Store installed it from - none for apps installed by hand)
				'source' => $installed !== null ? $from : null,
				'source_name' => $installed !== null ? $source_name($from) : '',
				'id' => $id,
				'name' => $app['name'],
				'version' => $app['version'],
				'summary' => $app['summary'],
				'categories' => isset($app['categories']) && is_array($app['categories']) ? array_values(array_intersect($app['categories'], STORE_CATEGORIES)) : [],
				'icon' => store_icon_data($repo, $app),
				'supported' => in_array($nas['model'], $models, true),
				'installed' => $installed !== null ? $installed['version'] : '',
				'enabled' => $installed !== null && $installed['enabled'],
				'from_here' => $from === null || $from === $repo['url'],
				'update' => $installed !== null && ($from === null || $from === $repo['url']) && store_version_compare($app['version'], $installed['version']) > 0,
				'can_update' => !empty($app['keeps_data']),
			];
		}
		foreach (isset($store['recipes']) ? $store['recipes'] : [] as $recipe) {
			$id = $recipe['id'];
			$installed = isset($recipes_installed[$id]) ? $recipes_installed[$id] : null;
			$recipes[] = [
				'repo' => $repo['url'],
				'repo_name' => $labels[$repo['url']],
				'source_name' => $installed !== null ? $source_name($installed['repo']) : '',
				'id' => $id,
				'name' => $recipe['name'],
				'version' => $recipe['version'],
				'summary' => $recipe['summary'],
				'categories' => isset($recipe['categories']) && is_array($recipe['categories']) ? array_values(array_intersect($recipe['categories'], STORE_CATEGORIES)) : [],
				'icon' => store_icon_data($repo, $recipe),
				'installed' => $installed !== null ? $installed['version'] : '',
				'from_here' => $installed === null || $installed['repo'] === $repo['url'],
				'update' => $installed !== null && $installed['repo'] === $repo['url'] && store_version_compare($recipe['version'], $installed['version']) > 0,
			];
		}
	}
	$listed = [];
	foreach ($recipes as $recipe) {
		$listed[$recipe['repo'] . '|' . $recipe['id']] = true;
	}
	$orphans = [];
	foreach ($recipes_installed as $id => $record) {
		if (!isset($listed[$record['repo'] . '|' . $id])) {
			$orphans[] = ['id' => (string)$id, 'name' => isset($record['name']) ? $record['name'] : (string)$id, 'version' => $record['version'], 'repo' => $record['repo']];
		}
	}
	$sort = function ($a, $b) {
		return strnatcasecmp($a['name'], $b['name']) ?: strcmp($a['repo'], $b['repo']);
	};
	usort($apps, $sort);
	usort($recipes, $sort);
	manage_json([
		'nas' => array_intersect_key($nas, array_flip(['model', 'arch', 'firmware', 'ram_mb', 'disk_mb', 'ip'])),
		'installed_apps' => api_installed_apps($nas['apps'], $by_store),
		'repos' => $repos,
		'stale' => store_repos_stale($loaded),
		'apps' => $apps,
		'recipes' => $recipes,
		'orphan_recipes' => $orphans,
		'categories' => STORE_CATEGORIES,
		'volume' => store_volume(),
	]);
}

if ($action === 'details') {
	$kind = isset($_GET['kind']) && $_GET['kind'] === 'recipes' ? 'recipes' : 'apps';
	list($repo, $entry) = store_find($kind, isset($_GET['repo']) ? (string)$_GET['repo'] : '', isset($_GET['id']) ? (string)$_GET['id'] : '');
	$recipes_installed = store_installed_recipes();
	$id = isset($_GET['id']) ? (string)$_GET['id'] : '';
	if ($entry === null && $kind === 'recipes' && isset($recipes_installed[$id]) && $recipes_installed[$id]['repo'] === (isset($_GET['repo']) ? (string)$_GET['repo'] : '')) {
		// Installed from a repository the Store no longer reads: its settings and removal still work, from the recipe's
		// files kept in its folder (but no updates)
		$installed = $recipes_installed[$id];
		$recipe_dir = $installed['data'] . '/.store/recipe';
		$installed_recipe = store_read_json($recipe_dir . '/recipe.json');
		if ($installed_recipe === null) {
			manage_fail(500, 'Its recipe files are missing from ' . $installed['data'] . '/.store');
		}
		manage_json(['name' => isset($installed['name']) ? $installed['name'] : $id, 'version' => $installed['version'], 'homepage' => '', 'sources' => '',
			'release_notes' => '', 'license' => '', 'repo_name' => '', 'third_party' => false, 'orphan' => $installed['repo'], 'problems' => [],
			'description' => !empty($installed_recipe['description']) ? store_markdown((string)@file_get_contents($recipe_dir . '/' . $installed_recipe['description'])) : '',
			'update_fields' => []] + api_recipe_installed($installed, $installed_recipe));
	}
	if ($entry === null) {
		manage_fail(404, 'Not found - refresh the repositories');
	}
	$out = [
		'name' => $entry['name'],
		'version' => $entry['version'],
		'homepage' => isset($entry['homepage']) && store_is_https_url($entry['homepage']) ? $entry['homepage'] : '',
		'sources' => isset($entry['sources']) && store_is_https_url($entry['sources']) ? $entry['sources'] : '',
		'release_notes' => isset($entry['release_notes']) && store_is_https_url($entry['release_notes']) ? $entry['release_notes'] : '',
		'license' => isset($entry['license']) && is_string($entry['license']) ? $entry['license'] : '',
		'repo_name' => api_repo_labels(store_repos_loaded())[$repo['url']],
		'third_party' => $repo['url'] !== STORE_DEFAULT_REPO,
	];
	if ($kind === 'apps') {
		$requires = isset($entry['requires']) && is_array($entry['requires']) ? $entry['requires'] : [];
		$requires['models'] = array_map(function ($p) {
			return $p['model'];
		}, $entry['packages']);
		$size = 0;
		foreach ($entry['packages'] as $package) {
			if ($package['model'] === store_nas()['model']) {
				$size = $package['size'];
			}
		}
		$out += [
			'description' => api_description($repo, $entry),
			'problems' => store_check_requires($requires, 'api_app_label'),
			'replaces' => isset($entry['replaces']) && is_array($entry['replaces']) ? array_values(array_filter($entry['replaces'], 'is_string')) : [],
			'data_folder' => isset($entry['data_folder']) && is_string($entry['data_folder']) ? $entry['data_folder'] : '',
			'keeps_data' => !empty($entry['keeps_data']),
			'size' => $size,
			'url' => isset(store_installed_apps()[$entry['id']]) ? api_web_url(isset($entry['web']) ? $entry['web'] : null) : '',
		];
		manage_json($out);
	}
	list($recipe, $dir, $error) = api_preview_recipe($repo, $entry);
	if ($recipe === null) {
		manage_fail(502, $error);
	}
	$installed = isset($recipes_installed[$entry['id']]) ? $recipes_installed[$entry['id']] : null;
	$out += ['description' => api_description($repo, $entry, $dir, $recipe), 'problems' => store_check_requires(isset($recipe['requires']) ? $recipe['requires'] : [], 'api_app_label')];
	if ($installed !== null && $installed['repo'] === $repo['url']) {
		// Installed from here: its settings (the installed recipe's), and the new options of an update
		$installed_recipe = store_read_json($installed['data'] . '/.store/recipe/recipe.json') ?: $recipe;
		$current = store_recipe_values($installed, $installed_recipe);
		$out += api_recipe_installed($installed, $installed_recipe);
		$out['update_fields'] = store_version_compare($recipe['version'], $installed['version']) > 0 ? store_wizard($recipe, $current, 'update') : [];
	} else {
		list($existing, $error) = store_existing_settings($recipe);
		if ($error !== '') {
			$out['problems'][] = ['level' => 'error', 'message' => $error];
		}
		$out['existing'] = $existing !== null ? store_apps_path() . '/' . $recipe['data_folder'] : '';
		$out['wizard'] = store_wizard($recipe, $existing, 'install');
		$out['data_folder'] = store_apps_path() . '/' . $recipe['data_folder'];
		$out['web'] = isset($recipe['web']['nginx']['name']) ? $recipe['web']['nginx']['name'] : '';
	}
	manage_json($out);
}

manage_require_action('store');

if ($action === 'refresh') {
	if (api_job_running($jobs)) {
		manage_fail(409, 'Wait for the current job to finish');
	}
	$errors = [];
	foreach (store_refresh_all() as $url => $error) {
		$errors[] = $url . ': ' . $error;
	}
	manage_json(['errors' => $errors]);
}

if ($action === 'add_repo') {
	$url = trim(isset($_POST['url']) ? (string)$_POST['url'] : '');
	if (store_repo_json_url($url) === '') {
		manage_fail(400, 'Enter the address of a repository: an HTTPS URL of its store.json, or a GitHub repository (https://github.com/owner/repo)');
	}
	$repos = store_repos();
	foreach ($repos as $repo) {
		if ($repo['url'] === $url) {
			manage_fail(400, 'It\'s already added');
		}
	}
	if ($url !== STORE_DEFAULT_REPO && empty($_POST['confirm'])) {
		manage_fail(400, 'Confirm that you trust it');
	}
	// Its key (if it offers one) is remembered from now on: later catalogues must be signed with it
	$result = store_fetch_repo($url, null);
	if (!$result['ok']) {
		manage_fail(400, $result['error']);
	}
	$repos[] = ['url' => $url, 'key' => $result['key'], 'added' => store_now()];
	if (!store_save_repos($repos)) {
		manage_fail(500, 'Could not save the repositories');
	}
	store_refresh_repo(end($repos));
	manage_json(['name' => $result['store']['name'], 'fingerprint' => store_key_fingerprint($result['key'])]);
}

if ($action === 'remove_repo') {
	$url = isset($_POST['url']) ? (string)$_POST['url'] : '';
	$repos = array_values(array_filter(store_repos(), function ($repo) use ($url) {
		return $repo['url'] !== $url;
	}));
	if (!store_save_repos($repos)) {
		manage_fail(500, 'Could not save the repositories');
	}
	$cache = store_repo_cache($url);
	store_rmtree($cache);
	store_rmtree($cache . '-icons');
	@unlink($cache . '.status.json');
	manage_json([]);
}

if ($action === 'accept_key') {
	$url = isset($_POST['url']) ? (string)$_POST['url'] : '';
	$repos = store_repos();
	foreach (store_repos_loaded() as $i => $repo) {
		if ($repo['url'] === $url && $repo['key_changed'] && $repo['new_key'] !== null
			&& isset($_POST['fingerprint']) && $_POST['fingerprint'] === store_key_fingerprint($repo['new_key'])) {
			$repos[$i]['key'] = $repo['new_key'];
			store_save_repos($repos);
			$error = store_refresh_repo($repos[$i]);
			if ($error !== '') {
				manage_fail(400, $error);
			}
			manage_json([]);
		}
	}
	manage_fail(400, 'Nothing to accept - refresh and try again');
}

if ($action === 'clear_job') {
	if (api_job_running($jobs)) {
		manage_fail(409, 'The job is still running');
	}
	@unlink($jobs . '/status.json');
	@unlink($jobs . '/job.log');
	manage_json([]);
}

if ($action === 'start') {
	if (api_job_running($jobs)) {
		manage_fail(409, 'Wait for the current job to finish');
	}
	$job = isset($_POST['job']) ? (string)$_POST['job'] : '';
	$repo_url = isset($_POST['repo']) ? (string)$_POST['repo'] : '';
	$id = isset($_POST['id']) ? (string)$_POST['id'] : '';
	$answers = json_decode(isset($_POST['answers']) ? (string)$_POST['answers'] : '{}', true);
	$answers = is_array($answers) ? $answers : [];
	$spec = ['id' => bin2hex(random_bytes(8)), 'action' => $job, 'repo' => $repo_url, 'target' => $id];
	if ($job === 'app_install' || $job === 'app_update') {
		list($repo, $app) = store_find('apps', $repo_url, $id);
		if ($app === null) {
			manage_fail(404, 'Not found - refresh the repositories');
		}
		$by_store = store_installed_by_store();
		$switching = $job === 'app_update' && isset($by_store[$id]) && $by_store[$id]['repo'] !== $repo_url;
		$spec['title'] = $switching ? 'Switching ' . $app['name'] . ' to ' . api_repo_labels(store_repos_loaded())[$repo_url] . ' (' . $app['version'] . ')'
			: ($job === 'app_install' ? 'Installing ' : 'Updating ') . $app['name'] . ' ' . $app['version'];
	} elseif ($job === 'app_uninstall') {
		$apps = store_installed_apps();
		if (!isset($apps[$id])) {
			manage_fail(404, 'It isn\'t installed');
		}
		$needed = store_dependent_apps($id);
		if ($needed) {
			manage_fail(409, 'Remove ' . implode(', ', $needed) . ' first: ' . (count($needed) > 1 ? 'they need' : 'it needs') . ' this app');
		}
		$spec['title'] = 'Removing ' . ($apps[$id]['name'] ?: $id);
	} elseif (in_array($job, ['recipe_install', 'recipe_update', 'recipe_change'], true)) {
		// The answers are checked now, so that the wizard can show what's wrong (and again by the job)
		$installed = store_installed_recipes();
		if ($job === 'recipe_install') {
			list($repo, $entry) = store_find('recipes', $repo_url, $id);
		} elseif (isset($installed[$id])) {
			list($repo, $entry) = store_find('recipes', $installed[$id]['repo'], $id);
			$spec['repo'] = $installed[$id]['repo'];
		} else {
			manage_fail(404, 'It isn\'t installed');
		}
		if ($job === 'recipe_change') {
			$recipe = store_read_json($installed[$id]['data'] . '/.store/recipe/recipe.json');
			$error = $recipe === null ? 'Its recipe files are missing' : '';
		} else {
			if ($entry === null) {
				manage_fail(404, 'Not found - refresh the repositories');
			}
			list($recipe, , $error) = api_preview_recipe($repo, $entry);
		}
		if ($recipe === null) {
			manage_fail(502, $error);
		}
		if ($job === 'recipe_install') {
			list($current, $error) = store_existing_settings($recipe);
			if ($error !== '') {
				manage_fail(400, $error);
			}
		} else {
			$installed_recipe = store_read_json($installed[$id]['data'] . '/.store/recipe/recipe.json') ?: $recipe;
			$current = store_recipe_values($installed[$id], $installed_recipe);
		}
		list(, $errors) = store_answers($recipe, $answers, $current, substr($job, 7));
		if ($errors) {
			http_response_code(400);
			header('Content-Type: application/json');
			echo json_encode(['ok' => false, 'error' => 'Some settings need changing', 'fields' => $errors]);
			exit;
		}
		$spec['answers'] = $answers;
		$spec['title'] = ['recipe_install' => 'Installing ', 'recipe_update' => 'Updating ', 'recipe_change' => 'Changing the settings of '][$job] . $recipe['name'];
	} elseif ($job === 'recipe_uninstall') {
		$installed = store_installed_recipes();
		if (!isset($installed[$id])) {
			manage_fail(404, 'It isn\'t installed');
		}
		$delete = json_decode(isset($_POST['delete']) ? (string)$_POST['delete'] : '[]', true);
		$spec['delete'] = is_array($delete) ? array_values(array_filter($delete, 'is_string')) : [];
		$spec['delete_data'] = !empty($_POST['delete_data']);
		$spec['title'] = 'Removing ' . $installed[$id]['name'];
	} else {
		manage_fail(400, 'Unknown job');
	}

	// The job file holds the answers (passwords too): root-only, and deleted by the job as soon as it has read it
	$file = $jobs . '/job-' . $spec['id'] . '.json';
	if (!store_write_json($file, $spec)) {
		manage_fail(500, 'Could not start the job');
	}
	@unlink($jobs . '/status.json');
	manage_run(['/bin/sh', '-c', '"$0" "$1" "$2" > /dev/null 2>&1 < /dev/null &', 'php', $app_path . '/lib/job.php', $file],
		['PATH' => '/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin', 'HOME' => getenv('HOME') ?: '/root'] + (getenv('STORE_TEST_VOLUME') ? ['STORE_TEST_VOLUME' => getenv('STORE_TEST_VOLUME')] : []));
	for ($i = 0; $i < 30 && !is_file($jobs . '/status.json'); $i++) {
		usleep(100000);
	}
	manage_json(api_job($jobs));
}

manage_fail(400, 'Unknown action');
