<?php
// changedetection.io management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('changedetection');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path      = dirname(__DIR__);
$apps_path     = dirname($app_path);
$data_path     = $apps_path.'/_changedetection';
$settings_file = $data_path.'/settings';
$ctl           = $app_path.'/changedetection_ctl.sh';
$target        = 'http://127.0.0.1:5000';
// The Browser recipe's Chrome, on this NAS (its DevTools port), and its folder
$local_browser = 'http://127.0.0.1:9222';
$recipe_path   = $apps_path.'/_changedetection-browser';

/**
 * The app's settings (KEY=value lines, also read by its control script).
 *
 * @param string $file The settings file
 *
 * @return array<string, string> Each setting, by name
 */
function cd_settings(string $file): array
{
    $settings = [];

    foreach (@file($file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [] as $line) {
        $parts = explode('=', $line, 2);

        if (count($parts) === 2) {
            $settings[$parts[0]] = $parts[1];
        }
    }

    return $settings;
}

/**
 * Changes some of the app's settings (keeping the others), failing the request if they can't be saved.
 *
 * @param string                $file    The settings file
 * @param array<string, string> $changes The settings to change, by name
 *
 * @return void
 */
function cd_save_settings(string $file, array $changes): void
{
    $text = '';

    foreach (array_merge(cd_settings($file), $changes) as $name => $value) {
        $text .= $name.'='.$value."\n";
    }

    if (!manage_write_file($file, $text) || !@chmod($file, 0600)) {
        manage_fail(500, 'The settings could not be saved');
    }
}

/**
 * Runs one of the app's control script commands that ends with changedetection.io restarted, failing the request if it
 * doesn't start.
 *
 * @param string       $ctl     The app's control script
 * @param list<string> $command The command and its arguments (e.g. ['browser', 'on'])
 * @param string       $input   What to give it on its input (e.g. a new password - never on its command line)
 *
 * @return void
 */
function cd_run(string $ctl, array $command, string $input = ''): void
{
    list($code, $output) = manage_run(array_merge(['/bin/sh', $ctl], $command), [], $input);

    if ($code !== 0) {
        manage_fail(500, 'changedetection.io could not be started: '.$output);
    }
}

/**
 * Whether a browser answers at a DevTools address (its version, as Playwright and Patchright ask for it).
 *
 * @param string $url The address (http://, https://, ws:// or wss://, with its host and port)
 *
 * @return string The browser's name and version (e.g. Chrome/156.0.8078.79), or '' if nothing answers
 */
function cd_browser_version(string $url): string
{
    $parts = parse_url($url);

    if (!is_array($parts) || !isset($parts['host'])) {
        return '';
    }

    $scheme = isset($parts['scheme']) && in_array($parts['scheme'], ['https', 'wss'], true) ? 'https' : 'http';
    $port   = isset($parts['port']) ? ':'.$parts['port'] : '';

    list($code, $body) = manage_http_get($scheme.'://'.$parts['host'].$port.'/json/version', 3);
    $version           = $code === 200 ? json_decode($body, true) : null;

    return is_array($version) && isset($version['Browser']) ? (string)$version['Browser'] : '';
}

$action   = isset($_GET['action']) ? $_GET['action'] : 'status';
$settings = cd_settings($settings_file);

if ($action === 'status') {
    $running = manage_pid_running('/var/run/changedetection.pid');

    // Its login page, which it shows to anyone
    list($code, $body) = $running ? manage_http_get($target.'/login', 5) : [0, ''];

    $browser = isset($settings['BROWSER_URL']) ? $settings['BROWSER_URL'] : '';
    $log     = @file($data_path.'/changedetection.out', FILE_IGNORE_NEW_LINES) ?: [];

    manage_json([
        'running'         => $running,
        'answering'       => $code === 200 && stripos($body, 'type="password"') !== false,
        'version'         => trim((string)@file_get_contents($app_path.'/binaries/version')),
        'listen'          => isset($settings['LISTEN']) && $settings['LISTEN'] === 'all' ? 'all' : 'local',
        'site'            => manage_nginx_site($apps_path, $target),
        'browser'         => [
            'url'     => $browser,
            'local'   => $browser === $local_browser,
            'recipe'  => is_file($recipe_path.'/compose.yaml'),
            'version' => $browser !== '' ? cd_browser_version($browser) : '',
        ],
        'local_addresses' => isset($settings['LOCAL_ADDRESSES']) && $settings['LOCAL_ADDRESSES'] === '1',
        'ntfy_topic'      => isset($settings['NTFY_TOPIC']) ? $settings['NTFY_TOPIC'] : '',
        'ntfy'            => is_dir($apps_path.'/ntfy'),
        // Its warnings and errors (it logs nothing else)
        'log'             => array_values(array_slice(preg_grep('/\| (WARNING|ERROR|CRITICAL) /', $log), -20)),
    ]);
}

manage_require_action('changedetection');

if ($action === 'show_password') {
    manage_json(['password' => trim((string)@file_get_contents($data_path.'/password'))]);
}

if ($action === 'new_password') {
    // Shown on the page afterwards (Show password), as the first one is
    $password = manage_new_password(isset($_POST['password']) ? (string)$_POST['password'] : '');

    cd_run($ctl, ['password'], $password."\n");
    manage_json(['password' => $password]);
}

if ($action === 'browser') {
    $browser = isset($_POST['browser']) ? trim((string)$_POST['browser']) : '';

    if ($browser !== '' && $browser !== 'local' && !preg_match('#^(https?|wss?)://[A-Za-z0-9.-]+(:\d{1,5})?(/[^\s]*)?$#', $browser)) {
        manage_fail(400, 'A browser\'s address is its DevTools address, e.g. http://192.168.1.20:9222 (or nothing, for none)');
    }

    if ($browser === 'local' && !is_file($recipe_path.'/compose.yaml')) {
        manage_fail(400, 'The Browser recipe isn\'t installed on this NAS (Store → Recipes)');
    }

    cd_run($ctl, ['browser', $browser === '' ? 'off' : ($browser === 'local' ? 'on' : $browser)]);
    manage_json();
}

if ($action === 'settings') {
    $topic = isset($_POST['ntfy_topic']) ? trim((string)$_POST['ntfy_topic']) : '';

    if (!preg_match('/^[A-Za-z0-9_-]{0,64}$/', $topic)) {
        manage_fail(400, 'An ntfy topic is 1-64 letters, digits, _ and - (or nothing, for no alerts there)');
    }

    cd_save_settings($settings_file, [
        'LOCAL_ADDRESSES' => isset($_POST['local_addresses']) && $_POST['local_addresses'] === '1' ? '1' : '0',
        'NTFY_TOPIC'      => $topic,
    ]);
    cd_run($ctl, ['restart']);
    manage_json();
}

if ($action === 'listen') {
    cd_save_settings($settings_file, ['LISTEN' => isset($_POST['listen']) && $_POST['listen'] === 'all' ? 'all' : 'local']);
    cd_run($ctl, ['restart']);
    manage_json();
}

if ($action === 'restart') {
    cd_run($ctl, ['restart']);
    manage_json();
}

manage_fail(400, 'Unknown action');
