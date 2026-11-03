<?php
// The Store's core (see store/SPEC.md in the project): repositories and their catalogues, downloads checked against
// their checksums and signatures, what the NAS has, requirements, and recipes' options. Used by the management page
// (api.php) and the background jobs (job.php), through WD's PHP 7.4 or the PHP app's 8.5 - so it must work on both.

const STORE_FORMAT = 1;            // the store_version this Store reads

// The recipe hooks this Store runs (section 4 of store/SPEC.md)
const STORE_HOOKS         = ['pre_install', 'post_install', 'pre_update', 'post_update', 'post_change', 'pre_uninstall'];
const STORE_RECIPE_FORMAT = 1;     // the recipe_version it reads
const STORE_DEFAULT_REPO  = 'https://github.com/paul-norman/WD-NAS-App-Builder';
const STORE_UPLOAD_PATH   = '/usr/local/apps_upload';
const STORE_APKG_XML      = '/var/www/xml/apkg_all.xml';
const STORE_MODEL_FILE    = '/usr/local/modules/files/model';

// Safe relative paths: no empty, . or .. parts, nothing but letters, digits, . _ and -
const STORE_PATH_PATTERN = '#^(?!(.*/)?\.\.?(/|$))[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$#';
const STORE_CATEGORIES   = [
    'media',
    'music',
    'photos',
    'books',
    'backup',
    'files',
    'monitoring',
    'network',
    'security',
    'development',
    'databases',
    'productivity',
    'home',
    'system'
];

/**
 * The NAS's first volume. STORE_TEST_VOLUME replaces it only in the project's tests, where Docker needs the same paths
 * as the test machine.
 *
 * @return string Its path, without a trailing /
 */
function store_volume(): string
{
    $test = getenv('STORE_TEST_VOLUME');

    return $test !== false && $test !== '' ? rtrim($test, '/') : '/mnt/HD/HD_a2';
}

/**
 * Where the NAS keeps its apps: Nas_Prog on the first volume.
 *
 * @return string The folder's path
 */
function store_apps_path(): string
{
    return store_volume().'/Nas_Prog';
}

/**
 * The Store's own data: its repositories, cached catalogues and jobs.
 *
 * @return string The folder's path
 */
function store_data_path(): string
{
    return store_apps_path().'/_store';
}

// ---------------------------------------------------------------------------------------------------------------------
// Small helpers

/**
 * Runs a command without a shell, with optional extra environment and working folder.
 *
 * @param list<string>          $command The program and its arguments
 * @param array<string, string> $env     Extra environment variables (PATH and HOME are set unless given)
 * @param string|null           $cwd     The working folder, or null for the current one
 * @param string                $input   What to give it on its standard input
 *
 * @return array{ 0: int, 1: string } [exit code, output (standard output and error, trimmed)] - the exit code is -1 if it
 *                                    couldn't be run (e.g. a program this NAS doesn't have; PHP 8 would also warn, hence
 *                                    the @)
 */
function store_run(array $command, array $env = [], ?string $cwd = null, string $input = ''): array
{
    $env += ['PATH' => '/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin', 'HOME' => getenv('HOME') ?: '/root'];

    // A program given by name is found in that PATH: PHP looks for it in the web server's own environment, which
    // PHP-FPM clears - leaving only /bin:/usr/bin, without e.g. /sbin/ip
    if (strpos($command[0], '/') === false) {
        foreach (explode(':', $env['PATH']) as $dir) {
            if ($dir !== '' && is_file($dir.'/'.$command[0]) && is_executable($dir.'/'.$command[0])) {
                $command[0] = $dir.'/'.$command[0];

                break;
            }
        }
    }

    $process = @proc_open($command, [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['redirect', 1]], $pipes, $cwd, $env);

    if (!is_resource($process)) {
        return [-1, 'could not run: '.$command[0]];
    }

    fwrite($pipes[0], $input);
    fclose($pipes[0]);

    $output = stream_get_contents($pipes[1]);

    fclose($pipes[1]);

    return [proc_close($process), trim($output)];
}

/**
 * Reads a JSON file holding an object or array.
 *
 * @param string $file The file
 *
 * @return array<mixed>|null Its contents, or null if it's missing or not JSON
 */
function store_read_json(string $file): ?array
{
    $data = json_decode((string)@file_get_contents($file), true);

    return is_array($data) ? $data : null;
}

/**
 * Writes a file in one step: a temporary file, renamed over it.
 *
 * @param string $file     The file
 * @param string $contents What to write
 * @param int    $mode     Its permissions (root only by default)
 *
 * @return bool Whether it was written
 */
function store_write(string $file, string $contents, int $mode = 0600): bool
{
    $temp = $file.'.tmp'.getmypid();

    if (file_put_contents($temp, $contents) === false || !chmod($temp, $mode) || !rename($temp, $file)) {
        @unlink($temp);

        return false;
    }

    return true;
}

/**
 * Writes data to a JSON file in one step, pretty-printed (see store_write()).
 *
 * @param string       $file The file
 * @param array<mixed> $data The data
 * @param int          $mode Its permissions (root only by default)
 *
 * @return bool Whether it was written
 */
function store_write_json(string $file, array $data, int $mode = 0600): bool
{
    return store_write($file, json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE)."\n", $mode);
}

/**
 * Creates a folder (and its parents) unless it's already there.
 *
 * @param string $dir  The folder
 * @param int    $mode Its permissions, if it's created (root only by default)
 *
 * @return bool Whether the folder is there
 */
function store_mkdir(string $dir, int $mode = 0700): bool
{
    return is_dir($dir) || mkdir($dir, $mode, true);
}

/**
 * Removes a folder and everything in it, without following links out of it (a link is removed, not what it leads to).
 *
 * @param string $path The folder (or a file or link)
 *
 * @return bool Whether it was removed (true if it wasn't there)
 */
function store_rmtree(string $path): bool
{
    if (is_link($path) || is_file($path)) {
        return @unlink($path);
    }

    if (!is_dir($path)) {
        return true;
    }

    foreach (scandir($path) ?: [] as $name) {
        if ($name !== '.' && $name !== '..') {
            store_rmtree($path.'/'.$name);
        }
    }

    return @rmdir($path);
}

/**
 * The current time, as the Store records it.
 *
 * @return string UTC, in ISO 8601 (e.g. 2026-10-30T09:30:24Z)
 */
function store_now(): string
{
    return gmdate('Y-m-d\TH:i:s\Z');
}

/**
 * Whether a string isn't empty - for array_filter(), which on its own would also drop "0".
 *
 * @param string $value The string
 *
 * @return bool Whether it isn't empty
 */
function store_not_empty(string $value): bool
{
    return $value !== '';
}

/**
 * Compares two versions: their dot-separated numbers first, then the rest (e.g. 3.3.5-2 > 3.3.5-1, 1.10 > 1.9).
 *
 * @param mixed $a A version
 * @param mixed $b The version to compare it with
 *
 * @return int<-1, 1> -1, 0 or 1 - as $a is older than, the same as or newer than $b
 */
function store_version_compare($a, $b): int
{
    preg_match('/^(\d+(?:\.\d+)*)?(.*)$/s', (string)$a, $ma);
    preg_match('/^(\d+(?:\.\d+)*)?(.*)$/s', (string)$b, $mb);

    $na = $ma[1] !== '' ? array_map('intval', explode('.', $ma[1])) : [];
    $nb = $mb[1] !== '' ? array_map('intval', explode('.', $mb[1])) : [];

    for ($i = 0, $n = max(count($na), count($nb)); $i < $n; $i++) {
        $x = $na[$i] ?? 0;
        $y = $nb[$i] ?? 0;

        if ($x !== $y) {
            return $x < $y ? -1 : 1;
        }
    }

    return max(-1, min(1, strnatcmp($ma[2], $mb[2])));
}

// ---------------------------------------------------------------------------------------------------------------------
// Downloads (HTTPS only, also after redirects - e.g. GitHub's release downloads)

/**
 * Downloads a URL to a file over HTTPS only (redirects included - e.g. GitHub's release downloads), up to a size limit.
 *
 * @param string       $url       The HTTPS URL
 * @param string|false $file      Where to save it (removed if the download fails)
 * @param positive-int $max_bytes The largest download allowed
 * @param positive-int $timeout   How long it may take, in seconds
 *
 * @return string '' once downloaded, else an error message
 */
function store_download(string $url, $file, int $max_bytes, int $timeout = 60): string
{
    if (!store_is_https_url($url)) {
        return 'Not an HTTPS address: '.$url;
    }

    list($code, $output) = store_run(['curl', '-sS', '-f', '-L', '--proto', '=https', '--proto-redir', '=https',
        '--max-redirs', '5', '--connect-timeout', '15', '-m', (string)$timeout, '--max-filesize', (string)$max_bytes,
        '-A', 'WD-NAS-Store/1', '-o', $file, $url]);

    if ($code !== 0) {
        @unlink($file);

        return 'Download failed ('.$url.'): '.($output !== '' ? $output : 'curl exit code '.$code);
    }

    if (filesize($file) > $max_bytes) {
        @unlink($file);

        return 'Download too large: '.$url;
    }

    return '';
}

/**
 * Whether a value is an HTTPS URL the Store accepts: a host, an optional port and a path without spaces, quotes, angle
 * brackets, backslashes or backticks.
 *
 * @param mixed $url The value
 *
 * @return bool Whether it is
 */
function store_is_https_url($url): bool
{
    return is_string($url) && preg_match('#^https://[A-Za-z0-9.-]+(:\d{1,5})?(/[^\s"\'<>\\\\`]*)?$#', $url) === 1;
}

/**
 * A URL from a catalogue: absolute (HTTPS) or relative to the repository's base (with no . or .. parts).
 *
 * @param mixed  $url  The URL from the catalogue
 * @param string $base The repository's base URL (ending in /)
 *
 * @return string The full URL, or '' if it isn't allowed
 */
function store_resolve_url($url, string $base): string
{
    if (!is_string($url)) {
        return '';
    }

    if (strpos($url, 'https://') === 0) {
        return store_is_https_url($url) ? $url : '';
    }

    return preg_match(STORE_PATH_PATTERN, $url) ? $base.$url : '';
}

// ---------------------------------------------------------------------------------------------------------------------
// Signatures (Ed25519, section 6 of the spec): PHP's sodium, else the PHP app's PHP (which has it), else OpenSSL 3

/**
 * The raw 32-byte Ed25519 key from a repository's public_key.
 *
 * @param mixed $key The key, as "ed25519:<base64 SubjectPublicKeyInfo>"
 *
 * @return string|null The raw key, or null if it isn't one
 */
function store_key_raw($key): ?string
{
    if (!is_string($key) || strpos($key, 'ed25519:') !== 0) {
        return null;
    }

    $der    = base64_decode(substr($key, 8), true);
    $prefix = hex2bin('302a300506032b6570032100');

    return $der !== false && strlen($der) === 44 && strpos($der, $prefix) === 0 ? substr($der, 12) : null;
}

/**
 * A short fingerprint of a signing key, to show (and compare by eye).
 *
 * @param mixed $key The key, as "ed25519:<base64 SubjectPublicKeyInfo>"
 *
 * @return string Eight groups of four hex digits, or '' if it isn't a key
 */
function store_key_fingerprint($key): string
{
    $raw = store_key_raw($key);

    return $raw === null ? '' : implode(':', str_split(substr(hash('sha256', $raw), 0, 32), 4));
}

/**
 * Checks an Ed25519 signature (section 6 of the spec) with PHP's sodium extension, else the PHP app's PHP (which has
 * it), else OpenSSL 3.
 *
 * @param string $data      What was signed
 * @param string $signature The signature, in base64
 * @param string $key       The signing key, as "ed25519:<base64 SubjectPublicKeyInfo>"
 *
 * @return bool|null Whether the signature is valid, or null if nothing on this NAS can check it
 */
function store_verify(string $data, string $signature, string $key): ?bool
{
    $raw = store_key_raw($key);
    $sig = base64_decode(trim((string)$signature), true);

    if ($raw === null || $sig === false || strlen($sig) !== 64) {
        return false;
    }

    if (function_exists('sodium_crypto_sign_verify_detached')) {
        return sodium_crypto_sign_verify_detached($sig, $data, $raw);
    }

    $temp = sys_get_temp_dir().'/store-verify-'.bin2hex(random_bytes(8));

    mkdir($temp, 0700);
    file_put_contents($temp.'/data', $data);
    file_put_contents($temp.'/sig', $sig);

    $result = null;
    $php    = store_apps_path().'/php/binaries/php';

    if (is_executable($php)) {
        $code = 'exit(sodium_crypto_sign_verify_detached(file_get_contents($argv[1]), file_get_contents($argv[2]), hex2bin($argv[3])) ? 0 : 1);';

        list($exit) = store_run([$php, '-n', '-r', $code, $temp.'/sig', $temp.'/data', bin2hex($raw)]);

        $result = $exit === 0 ? true : ($exit === 1 ? false : null);
    }

    if ($result === null) {
        list(, $version) = store_run(['openssl', 'version']);

        if (preg_match('/^OpenSSL ([3-9])\./', $version)) {
            $pem = "-----BEGIN PUBLIC KEY-----\n".chunk_split(substr($key, 8), 64, "\n")."-----END PUBLIC KEY-----\n";

            file_put_contents($temp.'/key.pem', $pem);

            list($exit) = store_run(['openssl', 'pkeyutl', '-verify', '-pubin', '-inkey', $temp.'/key.pem', '-rawin',
                '-in', $temp.'/data', '-sigfile', $temp.'/sig']);
            $result = $exit === 0;
        }
    }

    store_rmtree($temp);

    return $result;
}

// ---------------------------------------------------------------------------------------------------------------------
// Repositories

/**
 * Where a repository's store.json is read from: a GitHub repository's raw file (its default branch, or /tree/<branch>),
 * or the HTTPS URL itself (with store.json added to one ending in /).
 *
 * @param string $url The repository's address, as added
 *
 * @return string The URL of its store.json, or '' if the address isn't usable
 */
function store_repo_json_url(string $url): string
{
    $url = trim($url);

    if (preg_match('#^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?(?:/tree/([A-Za-z0-9_./-]+?))?/?$#', $url, $m)) {
        $branch = $m[3] ?? 'HEAD';

        return "https://raw.githubusercontent.com/{$m[1]}/{$m[2]}/{$branch}/store.json";
    }

    if (!store_is_https_url($url) || strpos($url, '?') !== false || strpos($url, '#') !== false) {
        return '';
    }

    return substr($url, -1) === '/' ? $url.'store.json' : $url;
}

/**
 * The repositories added - the default one first, unless it was removed.
 *
 * @return list<array{ url: string, key: string|null, added: string }> The repositories, each with its signing key (null
 *                                                                     if it isn't signed) and when it was added
 */
function store_repos(): array
{
    $data = store_read_json(store_data_path().'/repos.json');

    if ($data === null) {
        $data = [
            'repos' => [[
                'url'   => STORE_DEFAULT_REPO,
                'key'   => null,
                'added' => store_now()
            ]]
        ];
    }

    return $data['repos'];
}

/**
 * Saves the list of repositories.
 *
 * @param array<array{ url: string, key: string|null, added: string }> $repos The repositories (any keys: they're saved as a list)
 *
 * @return bool Whether it was saved
 */
function store_save_repos(array $repos): bool
{
    return store_write_json(store_data_path().'/repos.json', ['repos' => array_values($repos)]);
}

/**
 * A repository's cache folder, named after its URL.
 *
 * @param string $url The repository's address
 *
 * @return string The folder's path
 */
function store_repo_cache(string $url): string
{
    return store_data_path().'/cache/'.substr(hash('sha256', $url), 0, 16);
}

/**
 * Fetches a repository's store.json (and signature), checks it and caches it - replacing the cached copy only once the
 * new one is checked.
 *
 * @param string      $url        The repository's address
 * @param string|null $pinned_key The key it must be signed with, or null for a new repository
 *
 * @return array{
 *     ok:           bool,
 *     error:        string,
 *     store?:       array<string, mixed>,
 *     key?:         string|null,
 *     key_changed?: true,
 * } Whether it worked, and why not; the catalogue and the key it offers (for a new repository); key_changed when its
 *   key isn't the pinned one
 */
function store_fetch_repo(string $url, ?string $pinned_key): array
{
    $json_url = store_repo_json_url($url);

    if ($json_url === '') {
        return [
            'ok'    => false,
            'error' => 'Not a repository address (an HTTPS URL of a store.json, or a GitHub repository)'
        ];
    }

    $temp = store_data_path().'/tmp-'.bin2hex(random_bytes(6));

    store_mkdir($temp);

    $result = store_fetch_repo_into($json_url, $pinned_key, $temp);

    if ($result['ok']) {
        $cache = store_repo_cache($url);

        store_mkdir(dirname($cache));
        store_rmtree($cache.'.old');

        if (is_dir($cache)) {
            rename($cache, $cache.'.old');
        }

        store_write_json($temp.'/fetched.json', ['url' => $url, 'json_url' => $json_url, 'fetched' => store_now()]);
        rename($temp, $cache);
        store_rmtree($cache.'.old');
    } else {
        store_rmtree($temp);
    }

    return $result;
}

/**
 * Downloads a repository's store.json (and its signature, if it's signed) into a folder, and checks them: valid JSON, a
 * format this Store reads, signed with the right key, and a catalogue it can use.
 *
 * @param string      $json_url   The URL of its store.json
 * @param string|null $pinned_key The key it must be signed with, or null for a new repository
 * @param string      $dir        The folder to download into
 *
 * @return array{
 *     ok:           bool,
 *     error:        string,
 *     store?:       array<string, mixed>,
 *     key?:         string|null,
 *     key_changed?: true,
 * } As store_fetch_repo()
 */
function store_fetch_repo_into(string $json_url, ?string $pinned_key, string $dir): array
{
    $error = store_download($json_url, $dir.'/store.json', 8 << 20, 30);

    if ($error !== '') {
        return [
            'ok'    => false,
            'error' => $error,
        ];
    }

    $bytes = (string)file_get_contents($dir.'/store.json');
    $store = json_decode($bytes, true);

    if (!is_array($store)) {
        return [
            'ok'    => false,
            'error' => 'Its store.json isn\'t valid JSON',
        ];
    }

    if (!isset($store['store_version']) || !is_int($store['store_version'])) {
        return [
            'ok'    => false,
            'error' => 'Its store.json has no store_version',
        ];
    }

    if ($store['store_version'] > STORE_FORMAT) {
        return [
            'ok'    => false,
            'error' => 'It needs a newer Store (its format is version '.$store['store_version'].')',
        ];
    }

    $offered = isset($store['public_key']) && is_string($store['public_key']) ? $store['public_key'] : null;

    if ($offered !== null && store_key_raw($offered) === null) {
        return [
            'ok'    => false,
            'error' => 'Its public_key isn\'t an Ed25519 key',
        ];
    }

    // Signed with the pinned key (or, for a new repository, with the key it offers)
    $key = $pinned_key !== null ? $pinned_key : $offered;

    if ($key !== null) {
        if ($pinned_key !== null && $offered !== $pinned_key) {
            return [
                'ok'          => false,
                'error'       => 'Its signing key has changed',
                'key_changed' => true,
                'key'         => $offered,
            ];
        }

        $sig_url = preg_replace('#store\.json$#', 'store.json.sig', $json_url);
        $error   = $sig_url !== $json_url ? store_download($sig_url, $dir.'/store.json.sig', 4096, 30) : 'No signature address';

        if ($error !== '') {
            return [
                'ok'    => false,
                'error' => 'It is signed, but its signature couldn\'t be downloaded: '.$error,
            ];
        }

        $valid = store_verify($bytes, (string)file_get_contents($dir.'/store.json.sig'), $key);

        if ($valid === null) {
            return [
                'ok'    => false,
                'error' => 'Its signature can\'t be checked on this NAS (install the PHP app, which can)',
            ];
        }

        if (!$valid) {
            return [
                'ok'    => false,
                'error' => 'Its signature is not valid - store.json may have been changed',
            ];
        }
    }

    $errors = store_check_catalogue($store);

    if ($errors) {
        return [
            'ok'    => false,
            'error' => 'Its store.json has errors: '.implode('; ', array_slice($errors, 0, 5)),
        ];
    }

    return [
        'ok'    => true,
        'error' => '',
        'store' => $store,
        'key'   => $offered,
    ];
}

/**
 * Checks what the Store relies on in a catalogue (the schema, store.schema.json, has the rest): its details, and each
 * app's packages and each recipe's files.
 *
 * @param array<string, mixed> $store The catalogue (store.json)
 *
 * @return list<string> Error messages (none if it's usable)
 */
function store_check_catalogue(array $store): array
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
        $label  = 'apps['.$i.']';
        $errors = array_merge($errors, store_check_entry($app, $label, '/^[A-Za-z0-9][A-Za-z0-9_-]*$/'));

        if (isset($app['id']) && is_string($app['id'])) {
            if (isset($seen['app:'.$app['id']])) {
                $errors[] = "{$label}: {$app['id']} is listed twice";
            }

            $seen['app:'.$app['id']] = true;
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
        $label  = 'recipes['.$i.']';
        $errors = array_merge($errors, store_check_entry($recipe, $label, '/^[a-z0-9][a-z0-9_-]*$/'));

        if (isset($recipe['id']) && is_string($recipe['id'])) {
            if (isset($seen['recipe:'.$recipe['id']])) {
                $errors[] = "{$label}: {$recipe['id']} is listed twice";
            }

            $seen['recipe:'.$recipe['id']] = true;
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

/**
 * Checks what every app and recipe in a catalogue needs: an id, a name, a version and a summary.
 *
 * @param mixed  $entry      The app or recipe
 * @param string $label      Where it is in the catalogue, for the messages (e.g. apps[3])
 * @param string $id_pattern The regular expression its id must match
 *
 * @return list<string> Error messages
 */
function store_check_entry($entry, string $label, string $id_pattern): array
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

/**
 * Every repository with its cached catalogue: fetched is when its catalogue was last read, checked when it was last
 * tried (also when that failed).
 *
 * @return list<array{
 *     url:         string,
 *     key:         string|null,
 *     added:       string,
 *     store:       array<string, mixed>|null,
 *     fetched:     string,
 *     checked:     string,
 *     base:        string,
 *     error:       string,
 *     key_changed: bool,
 *     new_key:     string|null,
 * }> The repositories: fetched is when its catalogue was last read, checked when it was last tried (also when that
 *    failed); base is the base for its relative URLs
 */
function store_repos_loaded(): array
{
    $list = [];

    foreach (store_repos() as $repo) {
        $cache   = store_repo_cache($repo['url']);
        $fetched = store_read_json($cache.'/fetched.json');
        $store   = $fetched !== null ? store_read_json($cache.'/store.json') : null;
        $base    = '';

        if ($store !== null) {
            $base = $store['base_url'] ?? preg_replace('#[^/]*$#', '', $fetched['json_url']);
        }

        $status = store_read_json($cache.'.status.json');
        $list[] = $repo + [
            'store'       => $store,
            'fetched'     => $fetched !== null ? $fetched['fetched'] : '',
            'checked'     => $status !== null && isset($status['checked']) ? $status['checked'] : '',
            'base'        => $base,
            'error'       => $status !== null ? $status['error'] : '',
            'key_changed' => $status !== null && !empty($status['key_changed']),
            'new_key'     => $status !== null && isset($status['key']) ? $status['key'] : null,
        ];
    }

    return $list;
}

/**
 * Whether any repository is due a check: never tried, or not in the last hour (the page then refreshes them by itself).
 *
 * @param list<array<string, mixed>> $loaded The repositories, as store_repos_loaded() gives them
 *
 * @return bool Whether one is
 */
function store_repos_stale(array $loaded): bool
{
    foreach ($loaded as $repo) {
        if ($repo['checked'] === '' || time() - strtotime($repo['checked']) > 3600) {
            return true;
        }
    }

    return false;
}

/**
 * Refreshes every repository.
 *
 * @return array<string, string> The error of each repository that failed, by its address
 */
function store_refresh_all(): array
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

/**
 * Refreshes one repository, remembering the outcome (an error keeps the previous catalogue), and caches its icons.
 *
 * @param array{ url: string, key?: string|null } $repo The repository, as store_repos() gives it
 *
 * @return string The error, or ''
 */
function store_refresh_repo(array $repo): string
{
    $result = store_fetch_repo($repo['url'], $repo['key'] ?? null);
    $status = [
        'checked' => store_now(),
        'error'   => $result['ok'] ? '' : $result['error'],
    ];

    if (!empty($result['key_changed'])) {
        $status['key_changed'] = true;
        $status['key']         = $result['key'];
    }

    $cache = store_repo_cache($repo['url']);

    store_mkdir(dirname($cache));
    store_write_json($cache.'.status.json', $status);

    if ($result['ok']) {
        store_cache_icons($repo['url']);
    }

    return $status['error'];
}

/**
 * Downloads the icons of a repository's apps and recipes (once per address; SVG or PNG, up to 256KB), so that the page
 * shows them without the browser contacting the repository. Icons no longer listed are removed.
 *
 * @param string $url The repository's address
 *
 * @return void
 */
function store_cache_icons(string $url): void
{
    foreach (store_repos_loaded() as $repo) {
        if ($repo['url'] !== $url || $repo['store'] === null) {
            continue;
        }

        $dir = store_repo_cache($url).'-icons';

        store_mkdir($dir);

        $index  = store_read_json($dir.'/index.json') ?: [];
        $wanted = [];

        foreach (['apps', 'recipes'] as $kind) {
            foreach (isset($repo['store'][$kind]) && is_array($repo['store'][$kind]) ? array_slice($repo['store'][$kind], 0, 500) : [] as $entry) {
                $icon = isset($entry['icon']) ? store_resolve_url($entry['icon'], $repo['base']) : '';

                if ($icon === '' || !preg_match('#\.(svg|png)$#i', $icon, $m)) {
                    continue;
                }

                $file          = substr(hash('sha256', $icon), 0, 16).'.'.strtolower($m[1]);
                $wanted[$icon] = $file;

                if (!isset($index[$icon]) && store_download($icon, $dir.'/'.$file, 256 << 10, 15) === '') {
                    $index[$icon] = $file;
                }
            }
        }

        foreach (array_diff_key($index, $wanted) as $file) {
            @unlink($dir.'/'.$file);
        }

        store_write_json($dir.'/index.json', array_intersect_key($index, $wanted));
    }
}

/**
 * An app's or recipe's cached icon, to show on the page.
 *
 * @param array<string, mixed> $repo  Its repository, as store_repos_loaded() gives it
 * @param array<string, mixed> $entry The app or recipe in the repository's catalogue
 *
 * @return string A data: URL, or '' if it has no cached icon
 */
function store_icon_data(array $repo, array $entry): string
{
    static $indexes = [];

    $icon = isset($entry['icon']) ? store_resolve_url($entry['icon'], $repo['base']) : '';

    if ($icon === '') {
        return '';
    }

    $dir = store_repo_cache($repo['url']).'-icons';

    if (!isset($indexes[$dir])) {
        $indexes[$dir] = store_read_json($dir.'/index.json') ?: [];
    }

    if (!isset($indexes[$dir][$icon]) || !is_file($dir.'/'.$indexes[$dir][$icon])) {
        return '';
    }

    $file = $indexes[$dir][$icon];
    $type = substr($file, -4) === '.svg' ? 'image/svg+xml' : 'image/png';

    return 'data:'.$type.';base64,'.base64_encode((string)file_get_contents($dir.'/'.$file));
}

// ---------------------------------------------------------------------------------------------------------------------
// The NAS

/**
 * What the NAS is and has: its model, architecture, firmware, memory, free space, installed apps, host name, time zone
 * and IP address (read once per request).
 *
 * @return array{
 *     model:    string,
 *     arch:     string,
 *     firmware: string,
 *     ram_mb:   int,
 *     disk_mb:  int,
 *     apps:     array<string, array<string, mixed>>,
 *     hostname: string,
 *     timezone: string,
 *     ip:       string,
 * } The NAS's details
 */
function store_nas(): array
{
    static $nas = null;

    if ($nas !== null) {
        return $nas;
    }

    $machine = php_uname('m');
    $mem     = 0;

    if (preg_match('/^MemTotal:\s+(\d+)/m', (string)@file_get_contents('/proc/meminfo'), $m)) {
        $mem = (int)($m[1] / 1024);
    }

    $free = @disk_free_space(store_volume());
    $nas  = [
        'model'    => trim((string)@file_get_contents(STORE_MODEL_FILE)),
        'arch'     => in_array($machine, ['x86_64', 'amd64'], true) ? 'amd64' : (strpos($machine, 'arm') === 0 ? 'armhf' : $machine),
        'firmware' => store_firmware(),
        'ram_mb'   => $mem,
        'disk_mb'  => $free !== false ? (int)($free / 1048576) : 0,
        'apps'     => store_installed_apps(),
        'hostname' => (string)gethostname(),
        'timezone' => store_timezone(),
        'ip'       => store_ip(),
    ];

    return $nas;
}

/**
 * The NAS's firmware version: OS5 keeps it in /etc/version (e.g. 5.33.102). WD's installer checks it too.
 *
 * @return string The version, or '' when it isn't found
 */
function store_firmware(): string
{
    foreach (['/etc/version', '/usr/local/modules/files/version', '/etc/fw_version'] as $file) {
        if (preg_match('/(\d+\.\d+\.\d+)/', (string)@file_get_contents($file), $m)) {
            return $m[1];
        }
    }

    return '';
}

/**
 * The NAS's time zone: the one set in its PHP settings (as the dashboard sets it), else PHP's default.
 *
 * @return non-empty-string A time zone identifier (e.g. Europe/London), or UTC
 */
function store_timezone(): string
{
    if (preg_match('/^\s*date\.timezone\s*=\s*"?([A-Za-z0-9_+\/-]+)/m', (string)@file_get_contents('/etc/php/php.ini'), $m)) {
        return $m[1];
    }

    $tz = date_default_timezone_get();

    return $tz !== '' ? $tz : 'UTC';
}

/**
 * The NAS's IPv4 address on its network.
 *
 * @return string The address, or '' if it isn't found
 */
function store_ip(): string
{
    list(, $output) = store_run(['ip', '-o', '-4', 'addr', 'show', 'scope', 'global']);

    return preg_match('/\binet (\d+\.\d+\.\d+\.\d+)\//', $output, $m) ? $m[1] : '';
}

/**
 * The installed apps, from WD's list (read leniently), each with the version in its own apkg.rc - WD's list can lag
 * behind an update (e.g. the Store's update of itself).
 *
 * @return array<string, array{
 *     version:     string,
 *     enabled:     bool,
 *     name:        string,
 *     center_type: string,
 *     url:         string,
 *     url_port:    string,
 *     icon:        string,
 *     description: string,
 *     installed:   string,
 *     depends:     list<string>,
 *     hidden:      bool,
 * }> The apps, by id
 */
function store_installed_apps(): array
{
    $apps = [];
    $xml  = (string)@file_get_contents(STORE_APKG_XML);

    // Each app is an <item> holding <name>, <show>, <version>, <enable>, <center_type> ... - read leniently
    if (preg_match_all('#<item>(.*?)</item>#s', $xml, $items)) {
        foreach ($items[1] as $item) {
            $field = function (string $tag) use ($item) {
                return preg_match('#<'.$tag.'>([^<]*)</'.$tag.'>#i', $item, $m) ? trim(html_entity_decode($m[1], ENT_QUOTES | ENT_XML1, 'UTF-8')) : '';
            };
            $id    = $field('name');

            if ($id === '') {
                continue;
            }

            // The version in the app's own apkg.rc: WD's list can lag behind an update - e.g. the Store's own
            $rc        = (string)@file_get_contents(store_apps_path().'/'.basename($id).'/apkg.rc');
            $version   = preg_match('/^Version:[ \t]*(\S+)/m', $rc, $m) ? $m[1] : $field('version');
            $apps[$id] = [
                'version'     => $version,
                'enabled'     => $field('enable') === '1',
                'name'        => $field('show'),
                'center_type' => $field('center_type'),
                'url'         => $field('url'),
                'url_port'    => $field('url_port'),
                'icon'        => $field('icon'),
                'description' => $field('description'),
                'installed'   => $field('inst_date'),
                'depends'     => array_values(array_filter(array_map('trim', preg_split('/[,\s]+/', $field('inst_depend'))), 'store_not_empty')),
                'hidden'      => strtolower($field('Hidden')) === 'on',
            ];
        }
    }

    return $apps;
}

/**
 * The installed apps that need an app: those whose InstDepend lists it.
 *
 * @param string $id The app's id
 *
 * @return list<string> Their names
 */
function store_dependent_apps(string $id): array
{
    $names = [];

    foreach (store_installed_apps() as $other => $app) {
        if ($other !== $id && in_array($id, $app['depends'], true)) {
            $names[] = $app['name'] ?: $other;
        }
    }

    return $names;
}

/**
 * An installed app's description: its desc.xml in English (as the NAS's Apps page shows it), else its apkg.rc's.
 *
 * @param string               $id  The app's id
 * @param array<string, mixed> $app The app, as store_installed_apps() gives it
 *
 * @return string The description
 */
function store_app_description(string $id, array $app): string
{
    foreach (['/var/www/apps/'.$id.'/desc.xml', '/var/www/'.$id.'/desc.xml'] as $file) {
        if (preg_match('#<en-US>(.*?)</en-US>#s', (string)@file_get_contents($file), $m)) {
            return trim(html_entity_decode(strip_tags($m[1]), ENT_QUOTES | ENT_XML1, 'UTF-8'));
        }
    }

    return $app['description'];
}

/**
 * Whether Docker (with Docker Compose) is there, and how much memory it may use.
 *
 * @param bool $with_driver Whether to also ask Docker for its storage driver (slower)
 *
 * @return array{ present: bool, memory_mb: int, driver: string } Whether it's there, the memory it may use (0 when
 *                                                                unknown) and its storage driver ('' unless asked)
 */
function store_docker(bool $with_driver = false): array
{
    list($code) = store_run(['docker', 'compose', 'version']);

    $limit  = (string)@file_get_contents('/sys/fs/cgroup/memory/docker/memory.limit_in_bytes');
    $docker = [
        'present'   => $code === 0,
        'memory_mb' => ctype_digit(trim($limit)) ? (int)(trim($limit) / 1048576) : 0,
        'driver'    => '',
    ];

    if ($with_driver && $docker['present']) {
        list(, $driver) = store_run(['docker', 'info', '--format', '{{.Driver}}']);

        $docker['driver'] = trim($driver);
    }

    return $docker;
}

/**
 * Checks an app's or recipe's requirements against the NAS (section 5 of the spec): its model, architecture, firmware,
 * memory, free space, the apps it needs, and Docker's memory and storage driver.
 *
 * @param mixed                          $requires     The requirements (requires, from the catalogue or recipe.json)
 * @param (callable(mixed): string)|null $label_of_app Gives an app's name from its id, for the messages (else the id is
 *                                                     used)
 *
 * @return list<array{ level: 'error'|'warning', message: string }> The problems found, if any
 */
function store_check_requires($requires, ?callable $label_of_app = null): array
{
    $requires = is_array($requires) ? $requires : [];
    $nas      = store_nas();
    $problems = [];
    $add      = function (string $level, string $message) use (&$problems): void {
        $problems[] = [
            'level'   => $level,
            'message' => $message,
        ];
    };

    if (!empty($requires['models']) && is_array($requires['models']) && !in_array($nas['model'], $requires['models'], true)) {
        $add('error', 'It doesn\'t support this NAS ('.($nas['model'] ?: 'unknown model').') - only: '.implode(', ', $requires['models']));
    }

    if (!empty($requires['arch']) && $requires['arch'] !== $nas['arch']) {
        $add('error', 'It needs an '.($requires['arch'] === 'amd64' ? 'Intel (amd64)' : 'ARM').' NAS');
    }

    if (!empty($requires['firmware_min']) && $nas['firmware'] !== '' && store_version_compare($nas['firmware'], $requires['firmware_min']) < 0) {
        $add('error', 'It needs firmware '.$requires['firmware_min'].' or later (this NAS has '.$nas['firmware'].')');
    }

    if (!empty($requires['ram_mb']) && $nas['ram_mb'] > 0 && $nas['ram_mb'] < $requires['ram_mb'] * 0.95) {
        $add('error', 'It needs '.store_mb($requires['ram_mb']).' of memory (this NAS has '.store_mb($nas['ram_mb']).')');
    }

    if (!empty($requires['disk_mb']) && $nas['disk_mb'] < $requires['disk_mb']) {
        $add('error', 'It needs '.store_mb($requires['disk_mb']).' of free space (there\'s '.store_mb($nas['disk_mb']).')');
    }

    foreach (!empty($requires['apps']) && is_array($requires['apps']) ? $requires['apps'] : [] as $app) {
        if (!isset($nas['apps'][$app])) {
            $add('error', 'Install the '.($label_of_app ? $label_of_app($app) : $app).' app first');
        } elseif (!$nas['apps'][$app]['enabled']) {
            $add('error', 'Turn on the '.($label_of_app ? $label_of_app($app) : $app).' app first (it\'s installed, but off)');
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
                $add('error', 'It needs '.store_mb($requires['docker_memory_mb']).' of memory for Docker (Docker may use '
                    .store_mb($docker['memory_mb']).' - raise its share on the Docker app\'s page)');
            }

            // Overlayfs is Docker's containerd image store's name for the same overlay storage as overlay2
            $driver = $docker['driver'] === 'overlayfs' ? 'overlay2' : $docker['driver'];

            if (!empty($requires['storage_driver']) && $driver !== '' && $driver !== $requires['storage_driver']) {
                $add('warning', 'Docker uses its '.$docker['driver'].' storage driver here: this needs a lot more disk space and is slower than with '.$requires['storage_driver']);
            }
        }
    }

    return $problems;
}

/**
 * A size in bytes, for messages (e.g. 365KB, 29MB, 1.2GB).
 *
 * @param int|float $bytes The size
 *
 * @return string The size, rounded
 */
function store_size($bytes): string
{
    return $bytes < 1048576 ? max(1, (int)ceil($bytes / 1024)).'KB' : store_mb((int)round($bytes / 1048576));
}

/**
 * A size in megabytes, for messages (e.g. 512MB, 4GB, 1.5GB).
 *
 * @param int|float $mb The size
 *
 * @return string The size, in MB or GB
 */
function store_mb($mb): string
{
    return $mb >= 1024 ? rtrim(rtrim(number_format($mb / 1024, 1), '0'), '.').'GB' : $mb.'MB';
}

// ---------------------------------------------------------------------------------------------------------------------
// The catalogue: every repository's apps and recipes, with what's installed

/**
 * Finds an app or recipe in a repository's catalogue.
 *
 * @param 'apps'|'recipes' $kind     apps or recipes
 * @param string           $repo_url The repository's address
 * @param string           $id       The app's or recipe's id
 *
 * @return array{
 *     0: array<string, mixed>|null,
 *     1: array<string, mixed>|null,
 * } [repository, entry] (as store_repos_loaded() and the catalogue give them), or [null, null]
 */
function store_find(string $kind, string $repo_url, string $id): array
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

/**
 * The apps the Store installed, and where from.
 *
 * @return array<string, array{
 *     repo:      string,
 *     version:   string,
 *     installed: string,
 * }> The apps, by id: the repository each came from, its version, and when it was installed
 */
function store_installed_by_store(): array
{
    $data = store_read_json(store_data_path().'/installed_apps.json');

    return $data !== null ? $data : [];
}

/**
 * Records an app the Store installed (or forgets it).
 *
 * @param string      $id       The app's id
 * @param string|null $repo_url The repository it came from, or null to forget it
 * @param string|null $version  Its version
 *
 * @return bool Whether it was recorded
 */
function store_record_app(string $id, ?string $repo_url, ?string $version): bool
{
    $data = store_installed_by_store();

    if ($repo_url === null) {
        unset($data[$id]);
    } else {
        $data[$id] = ['repo' => $repo_url, 'version' => $version, 'installed' => store_now()];
    }

    return store_write_json(store_data_path().'/installed_apps.json', $data);
}

/**
 * The installed recipes, from the installed.json in each recipe's folder (Nas_Prog/<its folder>/.store/installed.json).
 *
 * @return array<string, array<string, mixed>> The recipes, by id: their installed.json, with data - the recipe's folder
 */
function store_installed_recipes(): array
{
    $recipes = [];

    foreach (glob(store_apps_path().'/*/.store/installed.json') ?: [] as $file) {
        $record = store_read_json($file);

        if ($record !== null && isset($record['id'])) {
            $recipes[$record['id']] = $record + ['data' => dirname(dirname($file))];
        }
    }

    return $recipes;
}

// ---------------------------------------------------------------------------------------------------------------------
// Recipes: files, options and .env

/**
 * Downloads a recipe's files into a folder, checking each one's SHA256 and that it stays inside the folder.
 *
 * @param array<string, mixed> $repo  Its repository, as store_repos_loaded() gives it
 * @param array<string, mixed> $entry The recipe in the repository's catalogue
 * @param string               $dir   The folder to download into
 *
 * @return string '' once they're all downloaded and checked, else an error message
 */
function store_fetch_recipe(array $repo, array $entry, string $dir): string
{
    // Its folder ends in /
    $base = store_resolve_url(rtrim($entry['path'], '/'), $repo['base']);

    if ($base === '' || substr($entry['path'], -1) !== '/') {
        return 'The recipe\'s path isn\'t allowed';
    }

    store_mkdir($dir);

    $base .= '/';
    $root  = realpath($dir);

    foreach ($entry['files'] as $name => $sha256) {
        if (!preg_match(STORE_PATH_PATTERN, $name)) {
            return 'A file name isn\'t allowed: '.$name;
        }

        $target = $root.'/'.$name;

        store_mkdir(dirname($target));

        $real = realpath(dirname($target));

        if ($real === false || ($real !== $root && strpos($real.'/', $root.'/') !== 0)) {
            return 'A file would be outside the recipe\'s folder: '.$name;
        }

        $error = store_download($base.$name, $target, 4 << 20, 60);

        if ($error !== '') {
            return $error;
        }

        if (!hash_equals($sha256, hash_file('sha256', $target))) {
            return 'A file doesn\'t match its checksum (it may have been changed): '.$name;
        }
    }

    return '';
}

/**
 * Reads and checks a downloaded recipe.json: its format, that it matches the catalogue, and its files, hooks, web
 * interface and options.
 *
 * @param string               $dir   The folder it was downloaded into
 * @param array<string, mixed> $entry The recipe in the repository's catalogue
 *
 * @return array{ 0: array<string, mixed>|null, 1: string } [recipe, ''], or [null, an error message]
 */
function store_load_recipe(string $dir, array $entry): array
{
    $recipe = store_read_json($dir.'/recipe.json');

    if ($recipe === null) {
        return [null, 'Its recipe.json isn\'t valid JSON'];
    }

    if (!isset($recipe['recipe_version']) || !is_int($recipe['recipe_version'])) {
        return [null, 'Its recipe.json has no recipe_version'];
    }

    if ($recipe['recipe_version'] > STORE_RECIPE_FORMAT) {
        return [null, 'It needs a newer Store (recipe format '.$recipe['recipe_version'].')'];
    }

    $files  = $entry['files'];
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
        // Hooks this Store doesn't know - a newer Store's - are ignored: it only ever runs those it knows
        if (!in_array($hook, STORE_HOOKS, true)) {
            continue;
        }

        if (!is_string($path) || !isset($files[$path])) {
            $errors[] = 'its '.$hook.' hook isn\'t one of its files'.(is_string($path) ? ' ('.$path.')' : '');
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

        // Its other sites in the Nginx app (e.g. each app of a stack): a name, a port, and optionally a label, a path,
        // the options and the boolean setting that switches it on (if)
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
            $errors[] = 'option '.$option['key'].' is listed twice';
        }

        $keys[isset($option['key']) ? (string)$option['key'] : ''] = true;
    }

    return $errors ? [null, 'Its recipe.json has errors: '.implode('; ', array_slice($errors, 0, 5))] : [$recipe, ''];
}

/**
 * Checks one of a recipe's options: its key and type, and what its type needs.
 *
 * @param mixed $option The option
 *
 * @return string '' if it's valid, else an error message
 */
function store_check_option($option): string
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

        // Service: one of the compose file's services, or a list of them - the folder at the same path in each
        $services = isset($mount['service']) ? (array)$mount['service'] : [];
        $named    = array_filter($services, function ($service): bool {
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

/**
 * A recipe's pattern (a regular expression the whole value must match) as one for PHP.
 *
 * @param string $pattern The pattern, as in recipe.json
 *
 * @return non-empty-string The PHP regular expression (Unicode)
 */
function store_pattern(string $pattern): string
{
    return '~^(?:'.str_replace('~', '\~', $pattern).')$~u';
}

/**
 * Fills in the placeholders of an option's default: {data}, {volume}, {share:Name}, {nas:timezone | hostname | ip} and
 * {option:KEY}.
 *
 * @param mixed                $value  The default (only strings have placeholders)
 * @param array<string, mixed> $recipe The recipe
 * @param array<string, mixed> $values The values of the options before it
 *
 * @return mixed The default, filled in
 */
function store_placeholders($value, array $recipe, array $values)
{
    if (!is_string($value)) {
        return $value;
    }

    $nas = store_nas();

    return preg_replace_callback('/\{(data|volume|share:[^{}\/]+|nas:(?:timezone|hostname|ip)|option:[A-Z][A-Z0-9_]*)\}/', function ($m) use ($recipe, $values, $nas) {
        if ($m[1] === 'data') {
            return store_apps_path().'/'.$recipe['data_folder'];
        }

        if ($m[1] === 'volume') {
            return store_volume();
        }
        list($kind, $name) = explode(':', $m[1], 2);

        if ($kind === 'share') {
            return store_volume().'/'.$name;
        }

        if ($kind === 'nas') {
            return (string)$nas[$name];
        }

        return isset($values[$name]) ? (is_array($values[$name]) ? '' : (string)$values[$name]) : '';
    }, $value);
}

/**
 * The wizard's view of a recipe's options: each with its default (or current value), without secrets, and on an update
 * only the new ones.
 *
 * @param array<string, mixed>        $recipe  The recipe
 * @param array<string, mixed>|null   $current The values already installed (updates and changes), or null
 * @param 'install'|'update'|'change' $mode    install, update or change
 *
 * @return list<array<string, mixed>> The fields to show: each option's details, with 'required', 'value' and (for
 *                                    passwords) 'saved'
 */
function store_wizard(array $recipe, ?array $current = null, string $mode = 'install'): array
{
    $values = [];
    $fields = [];

    foreach ($recipe['options'] ?? [] as $option) {
        $key         = $option['key'];
        $has_current = $current !== null && array_key_exists($key, $current);
        $value       = $has_current ? $current[$key] : store_placeholders($option['default'] ?? '', $recipe, $values);

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

        // Only new options are asked on updates
        if ($mode === 'update' && $has_current) {
            continue;
        }

        $field = array_intersect_key($option, array_flip([
            'key', 'type', 'label', 'help', 'advanced', 'pattern', 'max_length',
            'min_length', 'min', 'max', 'choices', 'on_share', 'create', 'empty', 'multiple', 'mount'
        ]));

        $field['required'] = !isset($option['required']) || (bool)$option['required'];
        $field['value']    = $option['type'] === 'password' ? '' : $value;

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

/**
 * A boolean option's value as a boolean: an option's two values (e.g. on / off) are true and false.
 *
 * @param array<string, mixed> $option The option
 * @param mixed                $value  The value (a boolean, or one of the option's values)
 *
 * @return bool The value
 */
function store_boolean_value(array $option, $value): bool
{
    $values = isset($option['values']) && is_array($option['values']) && count($option['values']) === 2 ? $option['values'] : ['true', 'false'];

    if (is_bool($value)) {
        return $value;
    }

    return (string)$value === (string)$values[0];
}

/**
 * The folders of an option with multiple, from the | separated list kept in .env.
 *
 * @param string $value The list
 *
 * @return list<string> The folders
 */
function store_split_folders(string $value): array
{
    return array_values(array_filter(array_map('trim', explode('|', $value)), 'store_not_empty'));
}

/**
 * Where a mounted folder appears in its container: the option's target, then the folder's path relative to the first
 * volume (or to /mnt).
 *
 * @param string $target The option's mount target
 * @param string $folder The folder on the NAS
 *
 * @return string The path in the container
 */
function store_mount_target(string $target, string $folder): string
{
    $volume   = store_volume().'/';
    $relative = strpos($folder, $volume) === 0 ? substr($folder, strlen($volume)) : preg_replace('#^/mnt/#', '', $folder);

    return rtrim($target, '/').'/'.$relative;
}

/**
 * Whether a folder is on a share: in the first volume (not Nas_Prog or a hidden system folder), another volume, or a
 * USB drive.
 *
 * @param string|false $folder The folder
 *
 * @return string '' if it is, else why not
 */
function store_check_share_folder($folder): string
{
    $volume = store_volume();
    $shares = '#^('.preg_quote($volume, '#').'|/mnt/HD/HD_[a-z][0-9]+|/mnt/USB/[A-Za-z0-9_]+)/([^/.][^/]*)(/.*)?$#';

    if (!preg_match($shares, $folder, $m)) {
        return 'It must be a folder on one of the NAS\'s shares (e.g. '.$volume.'/Photos)';
    }

    if ($m[2] === 'Nas_Prog') {
        return 'It must be on a share, not in Nas_Prog (the apps\' folder)';
    }

    return '';
}

/**
 * Checks the wizard's answers against a recipe's options, and works out the values of those not asked (secrets
 * generated, defaults filled in, current values kept).
 *
 * @param array<string, mixed>        $recipe  The recipe
 * @param array<string, mixed>        $answers The answers given
 * @param array<string, mixed>|null   $current The values already installed (updates and changes), or null
 * @param 'install'|'update'|'change' $mode    install, update or change
 *
 * @return array{ 0: array<string, mixed>, 1: array<string, string> } [values (for .env), errors (key => message)]
 */
function store_answers(array $recipe, array $answers, ?array $current = null, string $mode = 'install'): array
{
    $values = [];
    $errors = [];

    foreach ($recipe['options'] ?? [] as $option) {
        $key         = $option['key'];
        $type        = $option['type'];
        $has_current = $current !== null && array_key_exists($key, $current);
        $asked       = !in_array($type, ['secret', 'hidden'], true) && !($mode !== 'install' && !empty($option['install_only'])) && !($mode === 'update' && $has_current);
        $default     = store_placeholders($option['default'] ?? '', $recipe, $values);

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

        $value    = array_key_exists($key, $answers) ? $answers[$key] : null;
        $required = !isset($option['required']) || (bool)$option['required'];

        [$value, $error] = store_answer($option, $value, $required, $has_current ? $current[$key] : null);

        if ($error !== '') {
            $errors[$key] = $error;
        }

        $values[$key] = $value;
    }

    return [$values, $errors];
}

/**
 * Checks one answer against its option, by the option's type.
 *
 * @param array<string, mixed> $option   The option
 * @param mixed                $value    The answer
 * @param bool                 $required Whether an answer is needed
 * @param mixed                $current  The value already installed, or null (an empty password keeps it)
 *
 * @return array{ 0: mixed, 1: string } [value, error] - the value cleaned up (e.g. trimmed), and '' or an error message
 */
function store_answer(array $option, $value, bool $required, $current): array
{
    $type = $option['type'];

    if ($type === 'boolean') {
        return [$value === true || $value === 'true' || $value === '1' || $value === 1, ''];
    }

    if ($type === 'folder' && !empty($option['multiple'])) {
        $folders = is_array($value) ? $value : store_split_folders((string)$value);
        $clean   = [];

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
                return [$value, 'Up to '.$option['max_length'].' characters'];
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
            $min    = $option['min'] ?? ($type === 'port' ? 1 : null);
            $max    = $option['max'] ?? ($type === 'port' ? 65535 : null);

            if (($min !== null && $number < $min) || ($max !== null && $number > $max)) {
                return [$value, 'Between '.$min.' and '.$max];
            }

            if ($type === 'port' && (string)$current !== $value && store_port_in_use($number)) {
                return [$value, 'Something on the NAS already uses port '.$number];
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
            $min = $option['min_length'] ?? 1;

            return [$value, mb_strlen($value) < $min ? 'At least '.$min.' characters' : ''];
        case 'folder':
            return store_answer_folder($option, $value);
    }

    return [$value, ''];
}

/**
 * Checks a folder answer: a full path in /mnt (on a share, for on_share and mount options) that exists - or, with
 * create, whose share does - and is empty when it must be.
 *
 * @param array<string, mixed> $option The option
 * @param string               $folder The folder
 *
 * @return array{ 0: string, 1: string } [folder (without a trailing /), '' or an error message]
 */
function store_answer_folder(array $option, string $folder): array
{
    $folder = rtrim($folder, '/');

    if ($folder === '' || $folder[0] !== '/' || preg_match('#(^|/)\.\.?(/|$)|//|\|#', $folder) || preg_match('/["\\\\`$]/', $folder)) {
        return [$folder, 'A full folder path (e.g. '.store_volume().'/Photos), without . or .. parts, quotes, $ or |'];
    }

    if (!empty($option['on_share']) || isset($option['mount'])) {
        $error = store_check_share_folder($folder);

        if ($error !== '') {
            return [$folder, $error];
        }
    } elseif (strpos($folder.'/', '/mnt/') !== 0) {
        return [$folder, 'A folder on the NAS\'s disks (in /mnt)'];
    }

    if (is_dir($folder)) {
        // Where it really is: not, through a link, somewhere else
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
        // To be created: its share must exist - shares are made in the NAS dashboard, so that they're shared
        if (preg_match('#^('.preg_quote(store_volume(), '#').'|/mnt/HD/HD_[a-z][0-9]+|/mnt/USB/[A-Za-z0-9_]+)/[^/]+#', $folder, $m) && !is_dir($m[0])) {
            return [$folder, 'The share '.basename($m[0]).' doesn\'t exist - create it in the NAS dashboard (Shares) first'];
        }
    }

    return [$folder, ''];
}

/**
 * Whether something on the NAS is listening on a TCP port.
 *
 * @param int $port The port
 *
 * @return bool Whether it is
 */
function store_port_in_use(int $port): bool
{
    $socket = @fsockopen('127.0.0.1', $port, $errno, $errstr, 0.5);

    if ($socket) {
        fclose($socket);

        return true;
    }

    return false;
}

/**
 * Generates a secret: letters and digits, or hex digits.
 *
 * @param mixed $generate The option's generate: ['length' (8 to 128, 32 by default), 'charset' (alnum or hex)]
 *
 * @return non-empty-string The secret
 */
function store_secret($generate): string
{
    $length = isset($generate['length']) ? max(8, min(128, (int)$generate['length'])) : 32;

    if (isset($generate['charset']) && $generate['charset'] === 'hex') {
        return substr(bin2hex(random_bytes($length)), 0, $length);
    }
    $chars  = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    $secret = '';

    while (strlen($secret) < $length) {
        $byte = ord(random_bytes(1));

        if ($byte < 248) {
            $secret .= $chars[$byte % 62];
        }
    }

    return $secret;
}

/**
 * The values as written to .env: booleans as their option's values, folders joined by |.
 *
 * @param array<string, mixed> $recipe The recipe
 * @param array<string, mixed> $values The values
 *
 * @return array<string, string> The values, by key
 */
function store_env_values(array $recipe, array $values): array
{
    $env = [];

    foreach ($recipe['options'] ?? [] as $option) {
        $key   = $option['key'];
        $value = $values[$key] ?? '';

        if ($option['type'] === 'boolean') {
            $pair  = isset($option['values']) && is_array($option['values']) && count($option['values']) === 2 ? $option['values'] : ['true', 'false'];
            $value = $value ? $pair[0] : $pair[1];
        } elseif (is_array($value)) {
            $value = implode('|', $value);
        }

        $env[$key] = (string)$value;
    }

    return $env;
}

/**
 * The text of a .env file: KEY=value, quoted where needed - with single quotes (taken literally by Compose), or double
 * quotes with escapes for values holding a single quote.
 *
 * @param array<string, string> $env   The values kept, by key
 * @param mixed                 $title The recipe's name, for the file's first line
 *
 * @return string The text
 */
function store_env_text(array $env, $title): string
{
    $text = "# {$title} - written by the Store (change the settings there; edits here are kept until then)\n";

    foreach ($env as $key => $value) {
        if (preg_match('#^[A-Za-z0-9_./:@%+,=|-]*$#', $value)) {
            $text .= "{$key}={$value}\n";
        } elseif (strpos($value, "'") === false) {
            $text .= "{$key}='{$value}'\n";
        } else {
            $text .= $key.'="'.str_replace(['\\', '"', '$'], ['\\\\', '\\"', '\\$'], $value)."\"\n";
        }
    }

    return $text;
}

/**
 * The folders given to the app by its options with mount.
 *
 * @param array<string, mixed> $recipe The recipe
 * @param array<string, mixed> $values The values
 *
 * @return list<array{ 0: string, 1: string, 2: string }> [[label, folder on the NAS, where it is in the app], ...]
 */
function store_mounts(array $recipe, array $values): array
{
    $mounts = [];

    foreach ($recipe['options'] ?? [] as $option) {
        if (empty($option['mount']) || !isset($values[$option['key']])) {
            continue;
        }

        foreach ((array)$values[$option['key']] as $folder) {
            if ($folder !== '') {
                $mounts[] = [$option['label'] ?? $option['key'], $folder, store_mount_target($option['mount']['target'], $folder)];
            }
        }
    }

    return $mounts;
}

/**
 * The text of compose.override.yaml: a bind mount in each of their services for every folder of the options with mount.
 *
 * @param array<string, mixed> $recipe The recipe
 * @param array<string, mixed> $values The values
 *
 * @return string The text, or '' when nothing is mounted
 */
function store_override_text(array $recipe, array $values): string
{
    $services = [];

    foreach ($recipe['options'] ?? [] as $option) {
        if (empty($option['mount'])) {
            continue;
        }

        foreach ((array)($values[$option['key']] ?? []) as $folder) {
            if ($folder === '') {
                continue;
            }
            $quote = function ($s) {
                return '"'.str_replace(['\\', '"', '$'], ['\\\\', '\\"', '$$'], $s).'"';
            };

            foreach ((array)$option['mount']['service'] as $service) {
                $services[$service][] = "      - type: bind\n        source: ".$quote($folder)
                    ."\n        target: ".$quote(store_mount_target($option['mount']['target'], $folder))
                    .(!empty($option['mount']['read_only']) ? "\n        read_only: true" : '')."\n";
            }
        }
    }

    if (!$services) {
        return '';
    }

    $text = "# Folders chosen in the Store's settings for this recipe - written by the Store (rewritten with them)\nservices:\n";

    foreach ($services as $service => $mounts) {
        $text .= "  {$service}:\n    volumes:\n".implode('', $mounts);
    }

    return $text;
}

/**
 * The values worth keeping in installed.json: all but secrets and passwords, which stay in .env only.
 *
 * @param array<string, mixed> $recipe The recipe
 * @param array<string, mixed> $values The values
 *
 * @return array<string, mixed> The values kept, by key
 */
function store_public_values(array $recipe, array $values): array
{
    $public = [];

    foreach ($recipe['options'] ?? [] as $option) {
        if (!in_array($option['type'], ['secret', 'password'], true) && array_key_exists($option['key'], $values)) {
            $public[$option['key']] = $values[$option['key']];
        }
    }

    return $public;
}

/**
 * The values of an installed recipe: its installed.json's, plus the secrets and passwords from its .env.
 *
 * @param array<string, mixed> $installed The installed recipe, as store_installed_recipes() gives it
 * @param array<string, mixed> $recipe    The recipe
 *
 * @return array<string, mixed> The values, by key
 */
function store_recipe_values(array $installed, array $recipe): array
{
    $values = isset($installed['values']) && is_array($installed['values']) ? $installed['values'] : [];
    $env    = store_parse_env($installed['data'].'/.env');

    foreach ($recipe['options'] ?? [] as $option) {
        if (in_array($option['type'], ['secret', 'password'], true) && isset($env[$option['key']])) {
            $values[$option['key']] = $env[$option['key']];
        }
    }

    return $values;
}

/**
 * Reads a .env file, as the Store writes them (see store_env_text()).
 *
 * @param string $file The file
 *
 * @return array<string, string> The values, by key
 */
function store_parse_env(string $file): array
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

/**
 * Settings already in a recipe's folder - a previous install whose data was kept, or one set up by hand - reused so
 * that, e.g., a database keeps its password. A folder that's an app's or another recipe's, or a Docker project name
 * already in use, is refused.
 *
 * @param array<string, mixed> $recipe The recipe
 *
 * @return array{ 0: array<string, mixed>|null, 1: string } [values (or null if there are none), '' or an error message]
 */
function store_existing_settings(array $recipe): array
{
    $data = store_apps_path().'/'.$recipe['data_folder'];

    if (!is_dir($data)) {
        return [null, ''];
    }

    if (is_file($data.'/apkg.rc')) {
        return [null, $data.' is an app\'s folder'];
    }

    $other = store_read_json($data.'/.store/installed.json');

    if ($other !== null && $other['id'] !== $recipe['id']) {
        return [null, $data.' belongs to another recipe ('.$other['id'].')'];
    }

    foreach (store_installed_recipes() as $installed) {
        if ($installed['id'] !== $recipe['id'] && isset($installed['project']) && $installed['project'] === $recipe['project']) {
            return [null, 'Another recipe ('.$installed['id'].') uses the same Docker project name'];
        }
    }

    if (!is_file($data.'/.env')) {
        return [null, ''];
    }

    $env    = store_parse_env($data.'/.env');
    $values = [];

    foreach ($recipe['options'] ?? [] as $option) {
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
// Automatic updates: every night (lib/auto_update.php, from root's crontab) the apps and recipes ticked "Update
// automatically" are updated, one at a time, from the repository each came from - the Store itself last

/**
 * The automatic updates' settings (Nas_Prog/_store/auto_update.json).
 *
 * @return array{ apps: list<string>, recipes: list<string>, topic: string } The ticked apps and recipes, and the ntfy
 *         topic told what happened ('' for none)
 */
function store_auto_settings(): array
{
    $data     = store_read_json(store_data_path().'/auto_update.json') ?: [];
    $settings = ['apps' => [], 'recipes' => [], 'topic' => ''];

    foreach (['apps', 'recipes'] as $kind) {
        if (isset($data[$kind]) && is_array($data[$kind])) {
            $settings[$kind] = array_values(array_unique(array_filter($data[$kind], 'is_string')));
        }
    }

    if (isset($data['topic']) && is_string($data['topic']) && store_valid_topic($data['topic'])) {
        $settings['topic'] = $data['topic'];
    }

    return $settings;
}

/**
 * Saves the automatic updates' settings.
 *
 * @param array{ apps: list<string>, recipes: list<string>, topic: string } $settings The settings
 *
 * @return bool Whether they were saved
 */
function store_save_auto_settings(array $settings): bool
{
    return store_write_json(store_data_path().'/auto_update.json', [
        'apps'    => array_values(array_unique($settings['apps'])),
        'recipes' => array_values(array_unique($settings['recipes'])),
        'topic'   => $settings['topic'],
    ]);
}

/**
 * Whether a string is an ntfy topic: 1-64 letters, digits, _ and - ('' is no topic).
 *
 * @param string $topic The topic
 *
 * @return bool Whether it is
 */
function store_valid_topic(string $topic): bool
{
    return $topic === '' || preg_match('/^[A-Za-z0-9_-]{1,64}$/', $topic) === 1;
}

/**
 * Whether an update needs doing by hand, as its repository says (manual_update in its catalogue entry: updating from a
 * version before manual_update.version needs something only the user can do, e.g. a database's data upgrade).
 *
 * @param array<string, mixed> $entry     The app or recipe in its repository's catalogue
 * @param string               $installed The installed version
 *
 * @return string Why, or '' when it can be done unattended
 */
function store_manual_update(array $entry, string $installed): string
{
    $manual = $entry['manual_update'] ?? null;

    if (!is_array($manual) || !isset($manual['version']) || !is_string($manual['version'])) {
        return '';
    }

    if (store_version_compare($installed, $manual['version']) >= 0 || store_version_compare($entry['version'], $manual['version']) < 0) {
        return '';
    }

    $reason = isset($manual['reason']) && is_string($manual['reason']) && $manual['reason'] !== '' ? $manual['reason'] : 'its repository says so';

    return 'updating to '.$manual['version'].' or later needs doing by hand: '.$reason;
}

/**
 * What tonight's automatic updates would do with each ticked app and recipe: update it (from the repository it came
 * from), nothing (up to date), or skip it - and why. Apps come first, each after the apps it needs (InstDepend), then
 * recipes, then the Store itself: an update of the Store replaces the code that runs the others.
 *
 * @return list<array{
 *     kind:    'apps'|'recipes',
 *     id:      string,
 *     name:    string,
 *     repo:    string,
 *     from:    string,
 *     to:      string,
 *     state:   'update'|'current'|'skip',
 *     reason:  string,
 * }> The ticked apps and recipes, in the order they're updated
 */
function store_auto_plan(): array
{
    $settings  = store_auto_settings();
    $loaded    = store_repos_loaded();
    $installed = store_installed_apps();
    $by_store  = store_installed_by_store();
    $recipes   = store_installed_recipes();
    $model     = store_nas()['model'];
    $plan      = [];

    // The repositories offering an id, and each one's entry
    $offered = function (string $kind, string $id) use ($loaded): array {
        $found = [];

        foreach ($loaded as $repo) {
            foreach ($repo['store'] !== null && isset($repo['store'][$kind]) && is_array($repo['store'][$kind]) ? $repo['store'][$kind] : [] as $entry) {
                if (isset($entry['id']) && $entry['id'] === $id) {
                    $found[$repo['url']] = [$repo, $entry];
                }
            }
        }

        return $found;
    };

    foreach (['apps', 'recipes'] as $kind) {
        foreach ($settings[$kind] as $id) {
            $item = ['kind' => $kind, 'id' => $id, 'name' => $id, 'repo' => '', 'from' => '', 'to' => '', 'state' => 'skip', 'reason' => ''];

            if ($kind === 'apps') {
                $current = $installed[$id] ?? null;
                $source  = isset($by_store[$id]) ? $by_store[$id]['repo'] : null;
            } else {
                $current = $recipes[$id] ?? null;
                $source  = $current !== null ? $current['repo'] : null;
            }

            if ($current === null) {
                $plan[] = ['reason' => 'it isn\'t installed'] + $item;

                continue;
            }

            $item['name'] = $current['name'] ?: $id;
            $item['from'] = (string)$current['version'];
            $offers       = $offered($kind, $id);

            // Installed by hand: no source yet - only a single repository offering it is taken as it
            if ($source === null) {
                if (count($offers) > 1) {
                    $plan[] = ['reason' => 'several repositories offer it, and it was installed by hand - update it once from the one you want'] + $item;

                    continue;
                }

                $source = $offers ? array_keys($offers)[0] : '';
            }

            if (!isset($offers[$source])) {
                $plan[] = ['reason' => $source === '' ? 'no repository offers it' : 'its repository no longer offers it ('.$source.')'] + $item;

                continue;
            }

            list($repo, $entry) = $offers[$source];

            $item['name'] = $entry['name'];
            $item['repo'] = $source;
            $item['to']   = (string)$entry['version'];

            if ($repo['key_changed']) {
                $plan[] = ['reason' => 'its repository\'s signing key has changed - accept or refuse it on the Repositories tab'] + $item;

                continue;
            }

            if (store_version_compare($entry['version'], $current['version']) <= 0) {
                $plan[] = ['state' => 'current'] + $item;

                continue;
            }

            $reason = store_manual_update($entry, (string)$current['version']);

            if ($reason === '' && $kind === 'apps') {
                $models = array_map(function ($package): string {
                    return is_array($package) && isset($package['model']) ? (string)$package['model'] : '';
                }, $entry['packages']);

                if (empty($entry['keeps_data'])) {
                    $reason = 'it can\'t be updated by the Store without losing its settings - update it by hand';
                } elseif (!in_array($model, $models, true)) {
                    $reason = 'there\'s no package for this NAS ('.($model ?: 'unknown model').')';
                }
            }

            if ($reason === '') {
                foreach (store_check_requires($entry['requires'] ?? []) as $problem) {
                    if ($problem['level'] === 'error') {
                        $reason = $problem['message'];

                        break;
                    }
                }
            }

            $plan[] = ($reason === '' ? ['state' => 'update'] : ['reason' => $reason]) + $item;
        }
    }

    // Apps after those they need, then recipes, then the Store
    $ordered = [];
    $apps    = array_values(array_filter($plan, function (array $item): bool {
        return $item['kind'] === 'apps' && $item['id'] !== 'store';
    }));

    while ($apps) {
        $progress = false;

        foreach ($apps as $i => $item) {
            $needs = array_intersect($installed[$item['id']]['depends'] ?? [], array_column($apps, 'id'));

            if (!$needs) {
                $ordered[] = $item;
                $progress  = true;

                unset($apps[$i]);
            }
        }

        $apps = array_values($apps);

        // Apps needing each other: in the order they were ticked
        if (!$progress) {
            $ordered = array_merge($ordered, $apps);
            $apps    = [];
        }
    }

    foreach ($plan as $item) {
        if ($item['kind'] === 'recipes') {
            $ordered[] = $item;
        }
    }

    foreach ($plan as $item) {
        if ($item['kind'] === 'apps' && $item['id'] === 'store') {
            $ordered[] = $item;
        }
    }

    return $ordered;
}

/**
 * The last automatic updates (Nas_Prog/_store/auto_update_last.json): when they were checked, and what happened to
 * each ticked app and recipe.
 *
 * @return array{ checked: string, results: list<array<string, string>> } checked is '' if they've never run; each
 *         result is a plan item (see store_auto_plan()) whose state is updated, failed, current or skip, with a message
 */
function store_auto_last(): array
{
    $data = store_read_json(store_data_path().'/auto_update_last.json');

    return [
        'checked' => $data !== null && isset($data['checked']) && is_string($data['checked']) ? $data['checked'] : '',
        'results' => $data !== null && isset($data['results']) && is_array($data['results']) ? array_values($data['results']) : [],
    ];
}

/**
 * Records what the automatic updates did, and tells the ntfy app's topic (if one is set, and the ntfy app installed)
 * about anything new: updates, failures, and skips not reported before (a skip is reported once per version).
 *
 * @param list<array<string, string>> $results What happened to each ticked app and recipe
 *
 * @return void
 */
function store_auto_record(array $results): void
{
    $previous = store_auto_last();
    $reported = [];

    foreach ($previous['results'] as $result) {
        if (($result['state'] ?? '') === 'skip') {
            $reported[$result['kind'].':'.$result['id'].':'.$result['to']] = true;
        }
    }

    store_write_json(store_data_path().'/auto_update_last.json', ['checked' => store_now(), 'results' => $results]);

    $lines  = [];
    $failed = false;

    foreach ($results as $result) {
        if ($result['state'] === 'updated') {
            $lines[] = $result['name'].' updated to '.$result['to'];
        } elseif ($result['state'] === 'failed') {
            $lines[] = $result['name'].' '.$result['to'].' failed: '.$result['message'];
            $failed  = true;
        } elseif ($result['state'] === 'skip' && $result['to'] !== '' && !isset($reported[$result['kind'].':'.$result['id'].':'.$result['to']])) {
            $lines[] = $result['name'].' '.$result['to'].' not installed: '.$result['reason'];
        }
    }

    $topic = store_auto_settings()['topic'];
    $token = trim((string)@file_get_contents(store_apps_path().'/_ntfy/token'));

    if (!$lines || $topic === '' || $token === '' || !isset(store_installed_apps()['ntfy'])) {
        return;
    }

    store_run(['curl', '-sS', '-f', '--max-time', '10', '-H', 'Authorization: Bearer '.$token, '-H', 'Title: Store: automatic updates',
        '-H', 'Tags: '.($failed ? 'warning' : 'package'), '--data-binary', '@-', 'http://127.0.0.1:2586/'.$topic], [], null, implode("\n", $lines));
}

// ---------------------------------------------------------------------------------------------------------------------
// Descriptions: a small, safe subset of Markdown (everything escaped first; links only to HTTPS addresses)

/**
 * A recipe's description as HTML, from a small, safe subset of Markdown: paragraphs, headings, lists, code, bold,
 * italics and links (to HTTPS addresses only). Everything is escaped first.
 *
 * @param string $text The Markdown
 *
 * @return string The HTML
 */
function store_markdown(string $text): string
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
            return '<a href="'.$m[2].'" target="_blank" rel="noopener noreferrer">'.$m[1].'</a>';
        }, $s);
    };
    $html      = '';
    $list      = false;
    $paragraph = [];
    $flush     = function () use (&$paragraph, &$html, $inline) {
        if ($paragraph) {
            $html     .= '<p>'.$inline(implode(' ', $paragraph))."</p>\n";
            $paragraph = [];
        }
    };

    foreach (preg_split('/\r?\n/', (string)$text) as $line) {
        if (preg_match('/^\s*[-*]\s+(.*)$/', $line, $m)) {
            $flush();

            if (!$list) {
                $html .= "<ul>\n";
                $list  = true;
            }

            $html .= '<li>'.$inline($m[1])."</li>\n";

            continue;
        }

        if ($list && preg_match('/^\s{2,}\S/', $line)) {
            // A list item continued on the next line
            $html = preg_replace('#</li>\n$#', ' '.$inline(trim($line))."</li>\n", $html);

            continue;
        }

        if ($list) {
            $html .= "</ul>\n";
            $list  = false;
        }

        if (trim($line) === '') {
            $flush();
        } elseif (preg_match('/^(#{1,4})\s+(.*)$/', $line, $m)) {
            $flush();

            $html .= '<h4>'.$inline($m[2])."</h4>\n";
        } else {
            $paragraph[] = trim($line);
        }
    }

    $flush();

    return $html.($list ? "</ul>\n" : '');
}
