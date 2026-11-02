<?php
// Icecast's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('icecast');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="icecast-manage">
    <?php manage_styles('icecast-manage'); ?>

    <h2>Icecast</h2>
    <table>
        <tr><td>Status</td><td data-ic="status">…</td></tr>
        <tr><td>Version</td><td data-ic="version">-</td></tr>
        <tr><td>Address</td><td data-ic="address">-</td></tr>
    </table>
    <p><a class="mg-button" data-ic="link" href="#" target="_blank" rel="noopener">Open Icecast</a>
        <button type="button" data-ic-action="restart">Restart Icecast</button></p>

    <h3>Passwords</h3>
    <table>
        <tr><td>Admin</td><td>user <code>admin</code>, password <code data-ic="admin-password">••••••••••••</code>
            <button type="button" data-ic-action="admin-show">Show</button> <button type="button" data-ic-action="admin-copy">Copy</button>
            <button type="button" data-ic-action="admin-new">New password</button></td></tr>
        <tr><td>Broadcasting</td><td>user <code>source</code>, password <code data-ic="source-password">••••••••••••</code>
            <button type="button" data-ic-action="source-show">Show</button> <button type="button" data-ic-action="source-copy">Copy</button>
            <button type="button" data-ic-action="source-new">New password</button></td></tr>
    </table>
    <p class="mg-note">Admin: Icecast's own admin pages (listeners, moving them between streams, kicking a stream off).
        Broadcasting: what software sending a stream to Icecast logs in with (see below). A new password restarts Icecast.</p>

    <h3>On air</h3>
    <table data-ic="mounts"></table>

    <h3>Station from a folder</h3>
    <p><label><input type="checkbox" data-ic="autodj"> Broadcast a folder of music from the NAS, around the clock</label></p>
    <p><label>Music folder <input type="text" data-ic="music-folder" spellcheck="false" placeholder="/mnt/HD/HD_a2/Public/Shared Music"></label>
        <span data-ic="music-note"></span></p>
    <p><label>Its address <code data-ic="mount-base">/</code><input type="text" data-ic="mount" spellcheck="false" placeholder="radio" style="width: 10rem"></label>
        <label>Quality <select data-ic="bitrate">
            <option value="64">64 kbps (MP3)</option><option value="96">96 kbps (MP3)</option><option value="128">128 kbps (MP3)</option>
            <option value="192">192 kbps (MP3)</option><option value="256">256 kbps (MP3)</option><option value="320">320 kbps (MP3)</option>
        </select></label>
        <label><input type="checkbox" data-ic="shuffle"> Shuffle</label></p>
    <p><label>Station name <input type="text" data-ic="station-name" maxlength="60"></label></p>
    <p><label>Description <input type="text" data-ic="station-description" maxlength="200" style="width: 34rem"></label></p>
    <p><button type="button" data-ic-action="save">Save</button>
        <button type="button" data-ic-action="skip">Next track</button>
        <button type="button" data-ic-action="rescan">Find new music</button></p>
    <p class="mg-note" data-ic="tracks"></p>
    <p class="mg-note">Every music file in the folder and its subfolders is played (MP3, FLAC, Ogg, Opus, AAC/M4A, WAV, WMA,
        APE, WavPack...), turned into one MP3 stream with each track's artist and title. New music is found every night, or
        straight away with "Find new music". The folder must be readable by everyone (shares normally are).</p>

    <h3>Broadcasting live</h3>
    <p>From a PC with broadcasting software (e.g. <a href="https://danielnoethen.de/butt/" target="_blank" rel="noopener">BUTT</a>,
        Mixxx or OBS): server <code data-ic="live-server">-</code>, port <code>8010</code>, mount point e.g.
        <code>/live</code> (any but the station's), user <code>source</code> and the broadcasting password above. Listeners
        tune in at the mount point's address while it's on air.</p>

    <h3>Settings</h3>
    <p><label><input type="checkbox" data-ic="local"> Only through the Nginx app (HTTPS) - live broadcasts from other
        computers then can't connect</label></p>
    <p><label>Listeners at once (each stream) <input type="number" data-ic="max-listeners" min="1" max="500" style="width: 7rem"></label></p>
    <p><button type="button" data-ic-action="save-settings">Save</button></p>
    <p class="mg-note">Each listener takes the stream's quality in upload bandwidth (e.g. 10 listeners at 128 kbps: about
        1.3 Mbit/s). Listeners on the internet need the Nginx app's address, or your router to pass port 8010 on to the NAS.
        Icecast restarts.</p>

    <details class="mg-section">
        <summary>Icecast's log</summary>
        <pre data-ic="log"></pre>
    </details>

    <p data-ic="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('icecast', 'ic'); ?>
        <?php manage_secret_script(); ?>

        let loaded = false;
        let base   = '';

        <?php manage_act_script(); ?>

        /**
         * Shows what's on air: each mount's address, what it's playing and its listeners.
         *
         * @param {Array.<Object>} mounts  The mounts: mount, name, title, listeners and peak
         * @param {boolean}        running Whether Icecast is running
         *
         * @return {void}
         */
        function fillMounts(mounts, running) {
            let table = part('mounts');

            table.textContent = '';

            if (!mounts.length) {
                table.insertRow().insertCell().textContent = running ? 'Nothing on air' : 'Icecast isn\'t running';

                return;
            }

            mounts.forEach(function (mount) {
                let row  = table.insertRow();
                let link = document.createElement('a');

                link.href = base + mount.mount;
                link.target = '_blank';
                link.rel = 'noopener';
                link.textContent = base + mount.mount;

                row.insertCell().appendChild(link);
                row.insertCell().textContent = (mount.name ? mount.name + ': ' : '') + (mount.title || '-');
                row.insertCell().textContent = mount.listeners + (mount.listeners === 1 ? ' listener' : ' listeners')
                    + ' (most: ' + mount.peak + ')';
            });
        }

        /**
         * Loads the app's status from its API and shows it.
         *
         * @return {Promise} Done once it's shown
         */
        function refresh() {
            return call('status').then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return;
                }

                let settings = response.settings;
                let status   = part('status');

                status.textContent = !response.running ? 'Stopped' : 'Running' + (settings.autodj ? (response.station_running ? ', the station is on air' : ', the station isn\'t playing') : '');
                status.className   = response.running && (!settings.autodj || response.station_running) ? 'mg-ok' : 'mg-bad';

                part('version').textContent = response.version || '-';

                let addresses = [];

                if (response.site.url) {
                    addresses.push(response.site.url);
                }

                if (settings.listen !== 'local' && response.local_url) {
                    addresses.push(response.local_url);
                }

                base = (response.site.url || response.local_url || '').replace(/\/$/, '');

                part('address').textContent     = addresses.join(' or ') || '-';
                part('link').href               = base ? base + '/' : '#';
                part('mount-base').textContent  = base + '/';
                part('live-server').textContent = settings.listen === 'local' ? '(not reachable: only through the Nginx app)' : (response.host || 'the NAS\'s address');

                fillMounts(response.mounts, response.running);

                part('tracks').textContent = settings.autodj ? response.tracks + ' tracks in the playlist' : '';

                let note = part('music-note');

                note.textContent = response.music_readable ? '' : 'Icecast can\'t read this folder';
                note.className = 'mg-bad';

                if (!loaded) {
                    part('autodj').checked            = settings.autodj;
                    part('music-folder').value        = settings.music_folder;
                    part('mount').value               = settings.mount;
                    part('bitrate').value             = String(settings.bitrate);
                    part('shuffle').checked           = settings.shuffle;
                    part('station-name').value        = settings.station_name;
                    part('station-description').value = settings.station_description;
                    part('local').checked             = settings.listen === 'local';
                    part('max-listeners').value       = settings.max_listeners;

                    loaded = true;
                }

                part('log').textContent = response.log.length ? response.log.join('\n') : 'Nothing logged';
            });
        }

        // Keep the page current, until the dashboard removes it
        <?php manage_timer_script(); ?>

        // The passwords: Show / Hide and Copy (fetched when first needed), and new ones
        ['admin', 'source'].forEach(function (name) {
            let secret = secretControls(part(name + '-password'), button(name + '-show'), button(name + '-copy'), function () {
                return call('password', { name: name }).then(function (response) {
                    if (!response.ok) {
                        say(response.error, false);

                        return null;
                    }

                    return response.password;
                });
            });

            button(name + '-new').addEventListener('click', function () {
                let what = name === 'admin' ? 'Icecast\'s admin pages' : 'broadcasting (software sending live streams needs the new one)';

                if (!window.confirm('A new password for ' + what + '? Icecast restarts.')) {
                    return;
                }

                act('new_password', { name: name }, 'Setting a new password…', 'New password in use - Icecast restarted.').then(function (response) {
                    if (response) {
                        secret.set(response.password);
                    }
                });
            });
        });

        /**
         * Saves the settings (Icecast restarts).
         *
         * @return {void}
         */
        function saveSettings() {
            act('settings', {
                autodj:              part('autodj').checked ? 1 : 0,
                music_folder:        part('music-folder').value,
                mount:               part('mount').value,
                bitrate:             part('bitrate').value,
                shuffle:             part('shuffle').checked ? 1 : 0,
                station_name:        part('station-name').value,
                station_description: part('station-description').value,
                listen:              part('local').checked ? 'local' : 'all',
                max_listeners:       part('max-listeners').value
            }, 'Saving…', 'Saved - Icecast restarted.');
        }

        button('save').addEventListener('click', saveSettings);
        button('save-settings').addEventListener('click', saveSettings);

        button('skip').addEventListener('click', function () {
            act('skip', { confirm: 1 }, 'Skipping…', 'Playing the next track.');
        });

        button('rescan').addEventListener('click', function () {
            act('rescan', { confirm: 1 }, 'Looking for new music…', 'The playlist is up to date.');
        });

        button('restart').addEventListener('click', function () {
            act('restart', { confirm: 1 }, 'Restarting Icecast…', 'Icecast restarted.');
        });

        refresh();
    })();
    </script>
</div>
