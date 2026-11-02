<?php
require_once dirname(__DIR__).'/manage/manage_helpers.php';

// Kopia's address in the Nginx app, and its server's own API, for the management page
const KOPIA_TARGET = 'http://127.0.0.1:51515';

/**
 * Asks Kopia's API for several things, logged in as admin with its CSRF token. The login goes via a root-only header
 * file, never on curl's command line.
 *
 * @param string       $password The admin password
 * @param list<string> $paths    The API's paths
 *
 * @return array<string, mixed>|null The decoded JSON for each path (null for any that failed), or null if Kopia didn't
 *                                   answer
 */
function kopia_api(string $password, array $paths): ?array
{
    $dir = sys_get_temp_dir().'/kopia-manage-'.bin2hex(random_bytes(6));

    if (!@mkdir($dir, 0700)) {
        return null;
    }

    $headers = $dir.'/headers';
    $jar     = $dir.'/cookies';
    $get     = function (string $path, array $extra) use ($password, $headers, $jar): string {
        file_put_contents($headers, implode("\n", array_merge(['Authorization: Basic '.base64_encode('admin:'.$password)], $extra))."\n");
        chmod($headers, 0600);

        list($code, $out) = manage_run(['curl', '-s', '-m', '5', '-c', $jar, '-b', $jar, '-H', '@'.$headers, KOPIA_TARGET.$path]);

        return $code === 0 ? $out : '';
    };
    $results = null;

    if (preg_match('/name="kopia-csrf-token" content="([0-9a-f]+)"/', $get('/', []), $m)) {
        $results = [];

        foreach ($paths as $path) {
            $results[$path] = json_decode($get($path, ['X-Kopia-Csrf-Token: '.$m[1]]), true);
        }
    }

    @unlink($headers);
    @unlink($jar);
    @rmdir($dir);

    return $results;
}
