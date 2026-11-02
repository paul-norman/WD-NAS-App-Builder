<?php
// Icecast management actions (JSON), for NAS admins only - see manage_helpers.php
require_once __DIR__.'/manage_helpers.php';

manage_require_admin('icecast');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path      = dirname(__DIR__);
$apps_path     = dirname($app_path);
$data_path     = $apps_path.'/_icecast';
$settings_file = $data_path.'/settings';
$ctl           = $app_path.'/ice_ctl.sh';

require $app_path.'/lib/ice.php';

const ICE_BITRATES = [64, 96, 128, 192, 256, 320];

/**
 * The app's settings, with defaults.
 *
 * @param string $file The settings file (KEY=value lines, also read by the app's control script)
 *
 * @return array<string, string> The settings
 */
function ice_settings(string $file): array
{
    $settings = [
        'STATION_NAME'        => 'NAS Radio',
        'STATION_DESCRIPTION' => '',
        'LISTEN'              => 'all',
        'MAX_LISTENERS'       => '50',
        'AUTODJ'              => '0',
        'MUSIC_FOLDER'        => '/mnt/HD/HD_a2/Public',
        'MOUNT'               => 'radio',
        'BITRATE'             => '128',
        'SHUFFLE'             => '1'
    ];

    foreach (@file($file, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
        if (preg_match('/^([A-Z_]+)=(.*)$/', $line, $m) && isset($settings[$m[1]])) {
            $settings[$m[1]] = $m[2];
        }
    }

    return $settings;
}

/**
 * Restarts Icecast with its control script (stop, then start), failing the request if it doesn't start.
 *
 * @param string $ctl The app's control script
 *
 * @return void
 */
function ice_restart(string $ctl): void
{
    manage_run(['/bin/sh', $ctl, 'stop']);

    list($code, $output) = manage_run(['/bin/sh', $ctl, 'start']);

    if ($code !== 0) {
        manage_fail(500, 'Icecast could not be started: '.$output);
    }
}

// Messages Icecast 2.5 logs about every stream and title update from ezstream (its libshout predates 2.5), which mean
// nothing is wrong: left out of the page's view of the log
const ICE_LOG_NOISE = '/util_http_select_best Input string does not parse as KVA|legacy SOURCE-style metadata update|uses safe method GET on \\/admin\\/metadata|Unsupported or legacy stream type: "audio\\/mpeg"/';

/**
 * The last lines of a log, without blank ones or the noise ICE_LOG_NOISE matches.
 *
 * @param string $file  The log
 * @param int    $lines How many
 *
 * @return list<string> The lines
 */
function ice_log(string $file, int $lines): array
{
    return array_slice(array_values(array_filter(@file($file, FILE_IGNORE_NEW_LINES) ?: [], function (string $line): bool {
        return trim($line) !== '' && !preg_match(ICE_LOG_NOISE, $line);
    })), -$lines);
}

$settings = ice_settings($settings_file);
$action   = $_GET['action'] ?? 'status';

if ($action === 'status') {
    $running = manage_pid_running('/var/run/icecast.pid');
    // Its streams (mounts), from its own status page: one is an object, several a list
    $mounts  = [];

    if ($running) {
        list($code, $body) = manage_http_get(ICE_TARGET.'/status-json.xsl');

        $status  = $code === 200 ? json_decode($body, true) : null;
        $sources = $status['icestats']['source'] ?? [];

        if (isset($sources['listenurl'])) {
            $sources = [$sources];
        }

        foreach ($sources as $source) {
            $mounts[] = [
                'mount'     => (string)parse_url($source['listenurl'], PHP_URL_PATH),
                'name'      => isset($source['server_name']) ? (string)$source['server_name'] : '',
                'title'     => isset($source['title']) ? (string)$source['title'] : '',
                'listeners' => isset($source['listeners']) ? (int)$source['listeners'] : 0,
                'peak'      => isset($source['listener_peak']) ? (int)$source['listener_peak'] : 0,
                'info'      => isset($source['audio_info']) ? (string)$source['audio_info'] : ''];
        }
    }
    $host     = isset($_SERVER['HTTP_HOST']) ? preg_replace('/:\d+$/', '', $_SERVER['HTTP_HOST']) : '';
    $playlist = $data_path.'/run/playlist.m3u';

    list($readable) = manage_run(['/bin/sh', $ctl, 'check-folder', $settings['MUSIC_FOLDER']]);

    manage_json([
        'running'         => $running,
        'station_running' => manage_pid_running('/var/run/ezstream.pid'),
        'version'         => preg_match('/^Version:\s*(\S+)/m', (string)@file_get_contents($app_path.'/apkg.rc'), $m) ? $m[1] : '',
        'site'            => manage_nginx_site($apps_path, ICE_TARGET),
        'local_url'       => $host !== '' ? 'http://'.$host.':8010/' : '',
        'host'            => $host,
        'mounts'          => $mounts,
        'tracks'          => is_file($playlist) ? count(file($playlist, FILE_SKIP_EMPTY_LINES)) : 0,
        'music_readable'  => $readable === 0,
        'log'             => array_merge(ice_log($data_path.'/run/logs/error.log', 15), ice_log($data_path.'/run/logs/ezstream.log', 10)),
        'settings'        => [
            'station_name'        => $settings['STATION_NAME'],
            'station_description' => $settings['STATION_DESCRIPTION'],
            'listen'              => $settings['LISTEN'] === 'local' ? 'local' : 'all',
            'max_listeners'       => (int)$settings['MAX_LISTENERS'],
            'autodj'              => $settings['AUTODJ'] === '1',
            'music_folder'        => $settings['MUSIC_FOLDER'],
            'mount'               => $settings['MOUNT'],
            'bitrate'             => (int)$settings['BITRATE'],
            'shuffle'             => $settings['SHUFFLE'] === '1',
        ],
    ]);
}

manage_require_action('icecast');

$name = isset($_POST['name']) ? (string)$_POST['name'] : '';

if ($action === 'password') {
    if ($name !== 'admin' && $name !== 'source') {
        manage_fail(400, 'Unknown password');
    }

    manage_json(['password' => trim((string)@file_get_contents($data_path.'/'.$name.'_password'))]);
}

if ($action === 'new_password') {
    if ($name !== 'admin' && $name !== 'source') {
        manage_fail(400, 'Unknown password');
    }

    list($code, $output) = manage_run(['/bin/sh', $ctl, 'new-password', $name]);

    if ($code !== 0) {
        manage_fail(500, 'A new password could not be made: '.$output);
    }

    // Icecast reads its passwords when it starts, and the station uses the source password
    ice_restart($ctl);
    manage_json(['password' => trim((string)@file_get_contents($data_path.'/'.$name.'_password'))]);
}

if ($action === 'settings') {
    $value = function (string $key): string {
        return isset($_POST[$key]) ? trim((string)$_POST[$key]) : '';
    };

    $station     = $value('station_name');
    $description = $value('station_description');
    $folder      = rtrim($value('music_folder'), '/');
    $mount       = strtolower(trim($value('mount'), '/'));
    $max         = (int)$value('max_listeners');
    $bitrate     = (int)$value('bitrate');
    $autodj      = !empty($_POST['autodj']);

    if ($station === '' || mb_strlen($station) > 60 || preg_match('/[\x00-\x1f]/', $station)) {
        manage_fail(400, 'Give the station a name (up to 60 characters)');
    }

    if (mb_strlen($description) > 200 || preg_match('/[\x00-\x1f]/', $description)) {
        manage_fail(400, 'The description is up to 200 characters, on one line');
    }

    if ($max < 1 || $max > 500) {
        manage_fail(400, 'Listeners at once: from 1 to 500');
    }

    if (!in_array($bitrate, ICE_BITRATES, true)) {
        manage_fail(400, 'Unknown bitrate: '.$bitrate);
    }

    if (!preg_match('/^[a-z0-9][a-z0-9._-]{0,39}$/', $mount)) {
        manage_fail(400, 'The station\'s address (e.g. radio) is up to 40 lower case letters, digits, dots, dashes and underscores');
    }

    if (!preg_match('#^/mnt/[^\x00-\x1f]+$#', $folder) || strpos($folder, '/..') !== false || preg_match('#^/mnt/HD/HD_[a-z][0-9]+/Nas_Prog(/|$)#', $folder)) {
        manage_fail(400, 'The music folder must be a folder on the NAS (not in Nas_Prog), e.g. /mnt/HD/HD_a2/Public/Shared Music');
    }

    if ($autodj) {
        if (!is_dir($folder)) {
            manage_fail(400, 'No such folder: '.$folder);
        }

        list($readable) = manage_run(['/bin/sh', $ctl, 'check-folder', $folder]);

        if ($readable !== 0) {
            manage_fail(400, 'Icecast\'s user can\'t read '.$folder.' - give everyone read access to it (shares normally have it)');
        }
    }
    $text = 'STATION_NAME='.$station."\n"
       .'STATION_DESCRIPTION='.$description."\n"
       .'LISTEN='.($value('listen') === 'local' ? 'local' : 'all')."\n"
       .'MAX_LISTENERS='.$max."\n"
       .'AUTODJ='.($autodj ? 1 : 0)."\n"
       .'MUSIC_FOLDER='.$folder."\n"
       .'MOUNT='.$mount."\n"
       .'BITRATE='.$bitrate."\n"
       .'SHUFFLE='.(empty($_POST['shuffle']) ? 0 : 1)."\n";

    if (!manage_write_file($settings_file, $text)) {
        manage_fail(500, 'The settings could not be saved');
    }

    ice_restart($ctl);
    manage_json();
}

if ($action === 'skip' || $action === 'rescan') {
    manage_run(['/bin/sh', $ctl, $action === 'skip' ? 'skip' : 'playlist']);
    manage_json();
}

if ($action === 'restart') {
    ice_restart($ctl);
    manage_json();
}

manage_fail(400, 'Unknown action');
