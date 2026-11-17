<?php
// The MeTube app's settings, users and media server check, for its management page (manage/api.php). Must work on
// both WD's PHP 7.4 and the PHP app's 8.5.
require_once dirname(__DIR__).'/manage/manage_helpers.php';

// The Watch page's address, as the Nginx app proxies to it
const METUBE_WATCH_TARGET = 'http://127.0.0.1:8086';
// PBKDF2-SHA256 rounds for the Watch page's passwords (checked by watch.py with hashlib)
const METUBE_PBKDF2_ROUNDS = 100000;
// The media servers the Watch page can read last-played times from
const METUBE_MEDIA_SERVERS = ['plex', 'jellyfin', 'emby'];
// Videos and audio, as the Watch page lists them
const METUBE_MEDIA_PATTERN = '/^[^.].*\\.(mp4|m4v|mkv|webm|mov|m4a|mp3|opus|ogg|flac|wav)$/i';

/**
 * A JSON file of the app's data folder, decoded - failing the request if it can't be read.
 *
 * @param string $file The file
 *
 * @return array<string, mixed> Its contents
 */
function metube_read_json(string $file): array
{
    $data = json_decode((string)@file_get_contents($file), true);

    if (!is_array($data)) {
        manage_fail(500, 'Could not read '.basename($file).' (is the app set up?)');
    }

    return $data;
}

/**
 * Writes a JSON file of the app's data folder in one step, readable by MeTube's user only (the Watch page reads it
 * again by itself) - failing the request if it can't.
 *
 * @param string               $file The file
 * @param array<string, mixed> $data What it holds
 *
 * @return void
 */
function metube_write_json(string $file, array $data): void
{
    $json = json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);

    if ($json === false || !manage_write_file($file, $json."\n") || !@chown($file, 'metube') || !@chgrp($file, 'root')
        || !@chmod($file, 0640)) {
        manage_fail(500, 'Could not save '.basename($file));
    }
}

/**
 * The app's settings, with their defaults.
 *
 * @param string $file settings.json
 *
 * @return array{ download_dir: string, listen: string, ytdlp_update: bool, watched_days: int, unwatched_days: int, media_server: array<string, string> }
 */
function metube_settings(string $file): array
{
    $settings = metube_read_json($file) + [
        'download_dir'   => '',
        'listen'         => 'local',
        'ytdlp_update'   => true,
        'watched_days'   => 3,
        'unwatched_days' => 30,
        'media_server'   => [],
    ];

    if (!is_array($settings['media_server'])) {
        $settings['media_server'] = [];
    }

    return $settings;
}

/**
 * A password's PBKDF2-SHA256 hash, as watch.py checks it.
 *
 * @param string $password The password
 *
 * @return string pbkdf2_sha256$<rounds>$<salt>$<hex>
 */
function metube_hash(string $password): string
{
    $salt = bin2hex(random_bytes(12));

    return 'pbkdf2_sha256$'.METUBE_PBKDF2_ROUNDS.'$'.$salt.'$'.hash_pbkdf2('sha256', $password, $salt, METUBE_PBKDF2_ROUNDS);
}

/**
 * Checks a download folder: on the NAS's volumes (or a USB drive), its parent existing - not the apps' folder
 * (Nas_Prog) or the volumes' system folders.
 *
 * @param string $path The folder
 *
 * @return string '' or the error
 */
function metube_check_folder(string $path): string
{
    $volume = '#^/mnt/(HD/HD_[a-z][0-9]+|USB/[^/]+)/[^\x00-\x1f]+$#';

    if (!preg_match($volume, $path) || preg_match('#/\.\.?(/|$)#', $path)) {
        return 'The folder must be in one of the NAS\'s shares, e.g. /mnt/HD/HD_a2/Public/Watch Later';
    }

    // Where it really is (its parent, if it doesn't exist yet), symbolic links followed
    $real = realpath(is_dir($path) ? $path : dirname($path));

    if ($real === false) {
        return 'No such folder: '.dirname($path);
    }

    if (!preg_match('#^/mnt/(HD/HD_[a-z][0-9]+|USB/[^/]+)/#', $real.'/')
        || preg_match('#^/mnt/HD/HD_[a-z][0-9]+/(Nas_Prog|lost\+found|otaclient|restsdk-data|restsdk-info|\.[^/]*)(/|$)#', $real.'/')) {
        return 'That folder holds the NAS\'s or its apps\' own files: choose one in a share';
    }

    return '';
}

/**
 * The yt-dlp version in use: the updated one in the data folder, else the packaged one.
 *
 * @param string $data_path Nas_Prog/_metube
 * @param string $app_path  The app's folder
 *
 * @return string Its version ('' if unknown)
 */
function metube_ytdlp_version(string $data_path, string $app_path): string
{
    $files = [
        $data_path.'/ytdlp/yt_dlp/version.py',
        $app_path.'/binaries/python/lib/python3.14/site-packages/yt_dlp/version.py',
    ];

    foreach ($files as $file) {
        if (preg_match("/^__version__ = '([^']+)'/m", (string)@file_get_contents($file), $match)) {
            return $match[1];
        }
    }

    return '';
}

/**
 * Asks a media server who it is and which of its libraries are in the download folder (only reading: the Watch page
 * reads last-played times the same way).
 *
 * @param array<string, string> $server       Its settings: type, url, token, path_from, path_to
 * @param string                $download_dir The download folder
 *
 * @return array{ ok: bool, message: string } Whether it answered, and what was found
 */
function metube_test_media_server(array $server, string $download_dir): array
{
    $base = rtrim($server['url'], '/');

    if ($server['type'] === 'plex') {
        list($code, $body) = manage_http_request('GET', $base.'/library/sections', null, 10,
            ['X-Plex-Token: '.$server['token'], 'Accept: application/json']);
        $data = json_decode($body, true);

        if ($code !== 200 || !is_array($data) || !isset($data['MediaContainer'])) {
            return ['ok' => false, 'message' => 'Plex didn\'t answer as expected (HTTP '.$code.'): check the address and token'];
        }

        $found = [];

        foreach ($data['MediaContainer']['Directory'] ?? [] as $section) {
            foreach ($section['Location'] ?? [] as $location) {
                $path = metube_map_path($server, (string)($location['path'] ?? ''));

                if ($download_dir !== '' && ($path === $download_dir || strpos($path.'/', $download_dir.'/') === 0
                    || strpos($download_dir.'/', $path.'/') === 0)) {
                    $found[] = (string)$section['title'];
                }
            }
        }

        return ['ok' => true, 'message' => metube_found_message('Plex', count($data['MediaContainer']['Directory'] ?? []), $found)];
    }

    $headers = ['X-Emby-Token: '.$server['token'], 'Accept: application/json'];

    list($code, $body) = manage_http_request('GET', $base.'/Library/VirtualFolders', null, 10, $headers);
    $folders = json_decode($body, true);
    $name    = $server['type'] === 'emby' ? 'Emby' : 'Jellyfin';

    if ($code !== 200 || !is_array($folders)) {
        return ['ok' => false, 'message' => $name.' didn\'t answer as expected (HTTP '.$code.'): check the address and API key'];
    }

    $found = [];

    foreach ($folders as $folder) {
        foreach ($folder['Locations'] ?? [] as $location) {
            $path = metube_map_path($server, (string)$location);

            if ($download_dir !== '' && ($path === $download_dir || strpos($path.'/', $download_dir.'/') === 0
                || strpos($download_dir.'/', $path.'/') === 0)) {
                $found[] = (string)($folder['Name'] ?? '');
            }
        }
    }

    return ['ok' => true, 'message' => metube_found_message($name, count($folders), $found)];
}

/**
 * A media server's path as this NAS sees it (its "path as the server sees it" prefix replaced).
 *
 * @param array<string, string> $server Its settings
 * @param string                $path   Its path
 *
 * @return string The NAS's path
 */
function metube_map_path(array $server, string $path): string
{
    $from = rtrim($server['path_from'] ?? '', '/');
    $to   = rtrim($server['path_to'] ?? '', '/');

    if ($from !== '' && ($path === $from || strpos($path, $from.'/') === 0)) {
        return $to.substr($path, strlen($from));
    }

    return $path;
}

/**
 * What a media server check found, for the page.
 *
 * @param string       $name      The server (e.g. Plex)
 * @param int          $libraries How many libraries it has
 * @param list<string> $found     The ones in the download folder
 *
 * @return string The message
 */
function metube_found_message(string $name, int $libraries, array $found): string
{
    if (!$found) {
        return $name.' answered ('.$libraries.' libraries), but none is in the download folder yet: add the folder (or each person\'s folder in it) as a library there';
    }

    return $name.' answered: '.implode(', ', array_unique($found)).' '.(count(array_unique($found)) === 1 ? 'is' : 'are').' in the download folder';
}

/**
 * How many videos and audio files a person's folder holds (and its playlist folders, one level down).
 *
 * @param string $folder The folder
 *
 * @return int The count
 */
function metube_count_media(string $folder): int
{
    $count = 0;

    foreach (@scandir($folder) ?: [] as $entry) {
        if ($entry[0] === '.') {
            continue;
        }

        if (is_dir($folder.'/'.$entry)) {
            $count += count(preg_grep(METUBE_MEDIA_PATTERN, @scandir($folder.'/'.$entry) ?: []) ?: []);
        } elseif (preg_match(METUBE_MEDIA_PATTERN, $entry)) {
            $count++;
        }
    }

    return $count;
}
