<?php
// Shared security checks for app management pages (copied into each app's manage/ folder when it is built).
//
// Management pages are only installed under /var/www/apps/<app>/ (URL /apps/<app>/), where nasAdmin itself only lets
// requests through with a valid NAS login token: its signature, expiry, client IP and origin are all checked, and the
// token is removed before the request reaches PHP. On top of that, every request here must belong to an admin's WD
// session, and every action must carry this page's CSRF token.
//
// Never trust the login_username cookie: browsers can set it to anything.

/**
 * Stops with a JSON error.
 *
 * @param int   $code    The HTTP status
 * @param mixed $message Why, as the page shows it
 *
 * @return never
 */
function manage_fail(int $code, $message): void
{
    http_response_code($code);

    header('Content-Type: application/json');

    echo json_encode(['ok' => false, 'error' => $message]);
    exit;
}

/**
 * Sends a JSON answer (with ok: true) and stops.
 *
 * @param array<string, mixed> $data The answer
 *
 * @return never
 */
function manage_json(array $data = []): void
{
    header('Content-Type: application/json');
    header('Cache-Control: no-store');

    echo json_encode(['ok' => true] + $data);
    exit;
}

/**
 * Whether a user is a NAS admin: a member of the administrators group, which the NAS maintains.
 *
 * @param string $user The user name
 *
 * @return bool Whether they are
 */
function manage_is_admin(string $user): bool
{
    foreach (file('/etc/group', FILE_IGNORE_NEW_LINES) ?: [] as $line) {
        $fields = explode(':', $line);

        if ($fields[0] === 'administrators') {
            return in_array($user, explode(',', $fields[3] ?? ''), true);
        }
    }

    return false;
}

/**
 * Only allows NAS admins, and only where nasAdmin enforces the NAS login (under /apps/<app>/, from 127.0.0.1). Who is
 * logged in comes from WD's own session, which is stored on the NAS - the browser only holds its ID.
 *
 * @param string $app The app's id
 *
 * @return string The admin's user name
 */
function manage_require_admin(string $app): string
{
    $path = parse_url($_SERVER['REQUEST_URI'] ?? '', PHP_URL_PATH);

    if (strpos((string)$path, "/apps/{$app}/") !== 0 || $_SERVER['REMOTE_ADDR'] !== '127.0.0.1') {
        manage_fail(403, 'Not available here');
    }

    // Who is logged in comes from WD's own session, which is stored on the NAS (the browser only holds its ID)
    session_start(['read_and_close' => true]);

    $user = isset($_SESSION['username']) ? (string)$_SESSION['username'] : '';

    if ($user === '' || !manage_is_admin($user)) {
        manage_fail(403, 'Only NAS admins can manage apps');
    }

    return $user;
}

/**
 * A CSRF token for this session: an HMAC of the session ID with a secret that never leaves the NAS (regenerated on
 * every boot, as /var/run is in RAM).
 *
 * @param string $app The app's id
 *
 * @return string The token
 */
function manage_csrf_token(string $app): string
{
    $file = "/var/run/manage_{$app}.secret";

    if (!is_file($file)) {
        file_put_contents($file, bin2hex(random_bytes(32)), LOCK_EX);
        chmod($file, 0600);
    }

    return hash_hmac('sha256', session_id(), trim(file_get_contents($file)));
}

/**
 * Requires a POST request carrying this session's CSRF token, so that other websites can't make an admin's browser act.
 *
 * @param string $app The app's id
 *
 * @return void
 */
function manage_require_action(string $app): void
{
    $sent = isset($_SERVER['HTTP_X_CSRF_TOKEN']) ? (string)$_SERVER['HTTP_X_CSRF_TOKEN'] : '';

    if ($_SERVER['REQUEST_METHOD'] !== 'POST' || !hash_equals(manage_csrf_token($app), $sent)) {
        manage_fail(403, 'Invalid request token - reload the page');
    }
}

/**
 * Runs a command without a shell (nothing can be injected), with optional extra environment variables and input - use
 * these for secrets, which would otherwise be visible to other processes in the command line.
 *
 * @param list<string>          $command The program and its arguments
 * @param array<string, string> $env     Extra environment variables (PATH is set unless given)
 * @param mixed                 $input   What to give it on its standard input
 *
 * @return array{ 0: int, 1: string } [exit code (-1 if it couldn't be run), output (standard output then error, trimmed)]
 */
function manage_run(array $command, array $env = [], $input = ''): array
{
    $env       += ['PATH' => '/usr/bin:/bin:/usr/sbin:/sbin'];
    $command[0] = manage_find_program($command[0], $env['PATH']);
    $process    = proc_open($command, [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes, null, $env);

    if (!is_resource($process)) {
        return [-1, 'could not run: '.$command[0]];
    }

    fwrite($pipes[0], $input);
    fclose($pipes[0]);

    $output = stream_get_contents($pipes[1]).stream_get_contents($pipes[2]);

    fclose($pipes[1]);
    fclose($pipes[2]);

    return [proc_close($process), trim($output)];
}

/**
 * A program given by name (e.g. ip), found in the PATH given: PHP looks for it in the web server's own environment,
 * which PHP-FPM clears - leaving only /bin:/usr/bin, without e.g. /sbin/ip.
 *
 * @param string $program The program, by name or path
 * @param string $path    The folders to look in, separated by :
 *
 * @return string Its path, or the name given if it isn't found
 */
function manage_find_program(string $program, string $path): string
{
    if (strpos($program, '/') !== false) {
        return $program;
    }

    foreach (explode(':', $path) as $dir) {
        if ($dir !== '' && is_file($dir.'/'.$program) && is_executable($dir.'/'.$program)) {
            return $dir.'/'.$program;
        }
    }

    return $program;
}

/**
 * Sends a request to a service on the NAS itself (e.g. http://127.0.0.1:8096/health) with the NAS's own curl, as WD's
 * PHP has allow_url_fopen turned off. Headers (e.g. API keys) go via a root-only file rather than the command line,
 * which other processes can see; the body goes on curl's input.
 *
 * @param string       $method       The HTTP method
 * @param string       $url          The URL
 * @param mixed        $body         The body (null for none)
 * @param int          $timeout      How long it may take, in seconds
 * @param list<string> $headers      Extra headers (e.g. 'Authorization: Bearer ...')
 * @param string       $content_type The body's type (e.g. application/x-www-form-urlencoded for a form)
 *
 * @return array{ 0: int, 1: string } [HTTP status, body], or [0, ''] if it couldn't be reached
 */
function manage_http_request(string $method, string $url, $body = null, int $timeout = 3, array $headers = [], string $content_type = 'application/json'): array
{
    $command = ['curl', '-s', '-m', (string)$timeout, '-X', $method, '-w', '\n%{http_code}'];

    if ($body !== null) {
        $command = array_merge($command, ['-H', 'Content-Type: '.$content_type, '--data-binary', '@-']);
    }

    $header_file = null;

    if ($headers) {
        $header_file = tempnam(sys_get_temp_dir(), 'manage');

        chmod($header_file, 0600);
        file_put_contents($header_file, implode("\n", $headers)."\n");

        $command = array_merge($command, ['-H', '@'.$header_file]);
    }

    [$code, $output] = manage_run(array_merge($command, [$url]), [], (string)$body);

    if ($header_file !== null) {
        unlink($header_file);
    }

    // The status code comes last, after a newline (which manage_run trims away when the body is empty)
    if ($code !== 0 || !preg_match('/^(.*?)\n?(\d{3})$/s', $output, $m)) {
        return [0, ''];
    }

    return [(int)$m[2], $m[1]];
}

/**
 * Sends a GET request to a service on the NAS itself (see manage_http_request()).
 *
 * @param string $url     The URL
 * @param int    $timeout How long it may take, in seconds
 *
 * @return array{ 0: int, 1: string } [HTTP status, body], or [0, ''] if it couldn't be reached
 */
function manage_http_get(string $url, int $timeout = 3): array
{
    return manage_http_request('GET', $url, null, $timeout);
}

/**
 * Whether the process in a PID file (e.g. /var/run/mailpit.pid) is running.
 *
 * @param string $pid_file The PID file
 *
 * @return bool Whether it is
 *
 * @phpstan-impure
 */
function manage_pid_running(string $pid_file): bool
{
    $pid = (int)@file_get_contents($pid_file);

    return $pid > 0 && file_exists('/proc/'.$pid);
}

/**
 * Replaces a file's contents in one step (a temporary file in the same folder, renamed over it), keeping its mode (root
 * only for a new file).
 *
 * @param string $file     The file
 * @param mixed  $contents What it holds
 *
 * @return bool Whether it was written
 */
function manage_write_file(string $file, $contents): bool
{
    $mode = is_file($file) ? fileperms($file) & 0777 : 0600;
    $temp = $file.'.tmp';

    if (file_put_contents($temp, $contents, LOCK_EX) === false || !chmod($temp, $mode) || !rename($temp, $file)) {
        @unlink($temp);

        return false;
    }

    return true;
}

/**
 * Where the Nginx app serves an app: the enabled site whose target is the app's address (the Nginx app offers it
 * under a name, but it can be renamed).
 *
 * @param string $apps_path Nas_Prog
 * @param string $target    The app's address, as the Nginx app proxies to it (e.g. http://127.0.0.1:8010)
 *
 * @return array{ state: 'ok'|'no_nginx'|'no_domain'|'off', url: string } Its state and its address ('' unless 'ok')
 */
function manage_nginx_site(string $apps_path, string $target): array
{
    $sites = $apps_path.'/nginx/lib/sites.php';

    if (!is_file($sites) || !is_dir($apps_path.'/_nginx')) {
        return [
            'state' => 'no_nginx',
            'url'   => '',
        ];
    }

    require_once $sites;

    $settings = sites_load($apps_path.'/_nginx');

    if ($settings['domain'] === '') {
        return [
            'state' => 'no_domain',
            'url'   => '',
        ];
    }

    foreach ($settings['apps'] as $app) {
        if ($app['enabled'] && rtrim($app['target'], '/') === rtrim($target, '/')) {
            // Older Nginx apps have no sites_host()
            $host = function_exists('sites_host') ? sites_host($settings, $app) : $app['name'].'.'.$settings['domain'];

            return [
                'state' => 'ok',
                'url'   => 'https://'.$host.'/',
            ];
        }
    }

    return [
        'state' => 'off',
        'url'   => '',
    ];
}

/**
 * Prints the start of a page's script, inside its closure: root (the page's element, id <app>-manage), api (its API's
 * address) and csrf (this page's token), and the helpers every page uses - part(name), button(name), say(text, good,
 * where) and call(action, data, query).
 *
 * @param string $app    The app's name, as its folder has it (e.g. phpMyAdmin)
 * @param string $prefix The page's data prefix (e.g. pma, for data-pma="..." and data-pma-action="..."): lower-case
 *                       letters, and no other page's
 *
 * @return void
 */
function manage_core_script(string $app, string $prefix): void
{
    $js = <<<'JS'
        let root = document.getElementById('{id}');
        let api  = '/apps/{app}/api.php';
        let csrf = {csrf};

        /**
         * One of the page's parts, by its data name.
         *
         * @param {string} name The part's data name
         *
         * @return {Element|null} The part
         */
        function part(name) {
            return root.querySelector('[data-{prefix}="' + name + '"]');
        }

        /**
         * One of the page's buttons, by its data name.
         *
         * @param {string} name The button's data name
         *
         * @return {Element|null} The button
         */
        function button(name) {
            return root.querySelector('[data-{prefix}-action="' + name + '"]');
        }

        /**
         * Shows a message on the page.
         *
         * @param {string}  text  The message ('' clears it)
         * @param {boolean} good  Whether it's good news (else it's shown as a problem)
         * @param {string}  where The part to show it in (message by default)
         *
         * @return {void}
         */
        function say(text, good, where) {
            let message = part(where || 'message');

            message.textContent = text || '';
            message.className   = good ? 'mg-ok' : 'mg-bad';
        }

        /**
         * API calls carry X-Requested-With (nasAdmin requires it) and this page's CSRF token.
         *
         * @param {string} action The API's action
         * @param {Object} data   What to post (a GET when there's none)
         * @param {string} query  More of the query string (e.g. &id=nano), if any
         *
         * @return {Promise.<Object>} Its answer
         */
        function call(action, data, query) {
            let options = {
                method:      data ? 'POST' : 'GET',
                credentials: 'same-origin',
                headers:     {
                    'X-Requested-With': 'XMLHttpRequest',
                    'X-CSRF-Token':     csrf
                }
            };

            if (data) {
                options.headers['Content-Type'] = 'application/x-www-form-urlencoded';
                options.body                    = new URLSearchParams(data).toString();
            }

            return fetch(api + '?action=' + action + (query || ''), options).then(function (response) {
                return response.json().catch(function () {
                    return {
                        ok:    false,
                        error: 'Unexpected response (' + response.status + ')'
                    };
                });
            });
        }

JS;

    echo ltrim(strtr($js, [
        '{id}'     => strtolower($app).'-manage',
        '{app}'    => $app,
        '{prefix}' => $prefix,
        '{csrf}'   => json_encode(manage_csrf_token($app)),
    ]));
}

/**
 * Prints act(action, data, working, done), inside a page's script (after manage_core_script()): it runs one of the
 * API's actions, saying it's being done, then how it went, and calls the page's refresh() 2 seconds later.
 *
 * @return void
 */
function manage_act_script(): void
{
    $js = <<<'JS'
        /**
         * Runs one of the API's actions, saying it's being done, then how it went - and shows the status again.
         *
         * @param {string} action  The API's action
         * @param {Object} data    What to post (a GET when there's none)
         * @param {string} working What to say meanwhile
         * @param {string} done    What to say once it's done
         *
         * @return {Promise.<(Object|null)>} Its answer (null if it failed)
         */
        function act(action, data, working, done) {
            say(working, true);

            return call(action, data).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return null;
                }

                say(done, true);
                setTimeout(refresh, 2000);

                return response;
            });
        }

JS;

    echo ltrim($js);
}

/**
 * Prints the timer that keeps a page current, inside its script (after manage_core_script()): it calls the page's
 * refresh() every so often, and stops once the dashboard has removed the page.
 *
 * @param int $interval How often, in milliseconds
 *
 * @return void
 */
function manage_timer_script(int $interval = 15000): void
{
    $js = <<<'JS'
        let timer = setInterval(function () {
            if (!document.body.contains(root)) {
                clearInterval(timer);

                return;
            }

            refresh();
        }, {interval});

JS;

    echo ltrim(str_replace('{interval}', (string) $interval, $js));
}

/**
 * Prints the JavaScript for showing a secret (a password or token) on request, inside a page's script (its closure):
 * let secret = secretControls(codeElement, showButton, copyButton, load). load() returns a promise of the secret (or
 * null, e.g. after saying why it failed). Show fetches and displays it, and becomes Hide (which puts the dots back);
 * Copy copies it without showing it. secret.set(value) shows a new value (e.g. after changing a password),
 * secret.reset() hides it and forgets it (e.g. after a new token was issued).
 *
 * @return void
 */
function manage_secret_script(): void
{
    $js = <<<'JS'
        /**
         * Copies text to the clipboard.
         *
         * @param {string} text The text
         *
         * @return {Promise.<boolean>} Whether it was copied
         */
        function copyText(text) {
            // The clipboard API only exists on secure (https) pages - the dashboard is often plain http
            if (navigator.clipboard && window.isSecureContext) {
                return navigator.clipboard.writeText(text).then(function () {
                    return true;
                }, function () {
                    return false;
                });
            }

            let area   = document.createElement('textarea');
            area.value = text;
            area.setAttribute('readonly', '');
            area.style.position = 'fixed';
            area.style.left     = '-9999px';
            document.body.appendChild(area);
            area.select();

            let ok = false;

            try {
                ok = document.execCommand('copy');
            } catch (e) {
                ok = false;
            }

            document.body.removeChild(area);

            return Promise.resolve(ok);
        }

        /**
         * A secret's Show / Hide and Copy buttons (see manage_secret_script() in manage_helpers.php).
         *
         * @param {Element}  code The element that shows it (dots until it's shown)
         * @param {Element}  show The Show / Hide button
         * @param {Element}  copy The Copy button
         * @param {Function} load Fetches it: returns a promise of the secret (or null)
         *
         * @return {{set: Function, reset: Function}} Shows a new value, or hides it and forgets it
         */
        function secretControls(code, show, copy, load) {
            let dots  = code.textContent;
            let value = null;
            let shown = false;

            /**
             * Shows the secret, or the dots.
             *
             * @param {boolean} on Whether to show the secret
             *
             * @return {void}
             */
            function display(on) {
                shown            = on;
                code.textContent = on ? value : dots;
                show.textContent = on ? 'Hide' : 'Show';
            }

            /**
             * The secret, fetched the first time.
             *
             * @return {Promise.<(string|null)>} The secret (null if it couldn't be fetched)
             */
            function get() {
                return value !== null ? Promise.resolve(value) : load().then(function (secret) {
                    if (secret !== null && secret !== undefined) {
                        value = secret;
                    }

                    return value;
                });
            }

            show.addEventListener('click', function () {
                if (shown) {
                    display(false);

                    return;
                }

                get().then(function (secret) {
                    if (secret !== null) {
                        display(true);
                    }
                });
            });

            copy.addEventListener('click', function () {
                get().then(function (secret) {
                    if (secret === null) {
                        return;
                    }

                    copyText(secret).then(function (ok) {
                        copy.textContent = ok ? 'Copied' : 'Copy failed';

                        setTimeout(function () {
                            copy.textContent = 'Copy';
                        }, 1500);
                    });
                });
            });

            return {
                set: function (secret) {
                    value = secret;

                    display(true);
                },
                reset: function () {
                    value = null;

                    display(false);
                }
            };
        }

JS;

    echo ltrim($js);
}

/**
 * Prints the shared look of management pages, scoped to the page's own element: pages are injected into the dashboard's
 * window, so unscoped rules would restyle the dashboard itself.
 *
 * @param string $id The page's element's id
 *
 * @return void
 */
function manage_styles(string $id): void
{
    $id = '#'.$id;

    echo "<style>
		{$id} { font-family: inherit; color: inherit; padding: 0.5rem 0; line-height: 1.5; white-space: normal; }
		{$id} h2 { font-size: 1.3em; font-weight: bold; margin: 0 0 0.75rem; }
		{$id} h3 { font-size: 1.05em; font-weight: bold; margin: 2rem 0 0.75rem; padding-top: 1.25rem; border-top: 1px solid rgba(127, 127, 127, 0.3); }
		{$id} .mg-section { margin-top: 2rem; padding-top: 1.25rem; border-top: 1px solid rgba(127, 127, 127, 0.3); }
		{$id} p { margin: 0.6rem 0; }
		{$id} table { border-collapse: collapse; }
		{$id} td { padding: 0.15rem 1rem 0.15rem 0; vertical-align: top; }
		{$id} code { background: rgba(127, 127, 127, 0.15); border-radius: 4px; padding: 0.1rem 0.35rem; word-break: break-all; }
		{$id} input[type=text] { width: 22rem; max-width: 100%; padding: 0.3rem; }
		{$id} input::placeholder { color: #b0b0b0; opacity: 1; }
		{$id} select,
		{$id} input[type=number] { box-sizing: border-box; height: 32px; padding: 0 6px; border: 1px solid #c8c8c8; border-radius: 0; outline: 0; background-color: #f0f0f0; color: #4b5a68; font: 14px Arial, Helvetica, sans-serif; vertical-align: middle; cursor: pointer; }
		{$id} select:focus,
		{$id} input[type=number]:focus { border-color: #0099ff; }
		{$id} input[type=number] { cursor: text; }
		{$id} button,
		{$id} a.mg-button { display: inline-block; margin: 0.2rem 0.4rem 0.2rem 0; padding: 0.3rem 0.8rem; cursor: pointer; }
		{$id} a.mg-button { text-decoration: none; color: #fafafa; border-top: 1px solid #15abff; border-bottom: 1px solid #0067a6; outline: 1px solid #0067a6; background-color: #018be3; background-image: linear-gradient(to bottom, #0099ff, #027dc8); background-origin: border-box; background-repeat: no-repeat; box-sizing: border-box; height: 32px; padding-top: 0; padding-bottom: 0; font: 14px Arial, Helvetica, sans-serif; line-height: 30px; }
		{$id} a.mg-button:hover { background-image: linear-gradient(to bottom, #027dc8, #0099ff); }
		{$id} [hidden] { display: none !important; }
		{$id} .mg-ok { color: #2e7d32; }
		{$id} .mg-bad { color: #c62828; }
		{$id} .mg-note { opacity: 0.75; font-size: 0.9em; }
	</style>\n";
}
