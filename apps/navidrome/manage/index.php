<?php
// Navidrome's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('navidrome');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="navidrome-manage">
    <?php manage_styles('navidrome-manage'); ?>

    <h2>Navidrome</h2>
    <table>
        <tr><td>Status</td><td data-nd="status">…</td></tr>
        <tr><td>Version</td><td data-nd="version">-</td></tr>
        <tr><td>Address</td><td data-nd="address">-</td></tr>
    </table>
    <p class="mg-note" data-nd="restart-note" hidden>The Nginx app's address for Navidrome has changed: restart Navidrome so
        that its share links use it.</p>
    <p><a class="mg-button" data-nd="link" href="#" target="_blank" rel="noopener">Open Navidrome</a>
        <button type="button" data-nd-action="restart">Restart Navidrome</button></p>

    <h3>Admin user</h3>
    <p>User name <code>admin</code>, password <code data-nd="password">••••••••••••</code>
        <button type="button" data-nd-action="show">Show</button> <button type="button" data-nd-action="copy">Copy</button>
        <button type="button" data-nd-action="new-password">New password</button></p>
    <p class="mg-note">Create a user for each person in Navidrome (Settings → Users). Phones use any Subsonic app (e.g.
        Symfonium, Tempo or Substreamer on Android, play:Sub or Amperfy on iPhone) with the address above and their own
        user name and password. This page logs in as admin with this password, so keep it as the app set it.</p>

    <h3>Music</h3>
    <table data-nd="libraries"></table>
    <p><button type="button" data-nd-action="scan">Scan for changes</button>
        <button type="button" data-nd-action="full-scan">Rescan everything</button></p>
    <p class="mg-note">New and changed files are picked up by themselves as they appear, and everything is checked once a
        day. More music folders can be added in Navidrome (Settings → Libraries).</p>

    <h3>Settings</h3>
    <p><label>Music folder <input type="text" data-nd="music-folder" spellcheck="false"
        placeholder="/mnt/HD/HD_a2/Public/Music"></label> <span data-nd="music-note"></span></p>
    <p><label><input type="checkbox" data-nd="local"> Only through the Nginx app (HTTPS)</label><br>
        <label><input type="checkbox" data-nd="external"> Artist images and biographies (from Deezer, Last.fm and
            ListenBrainz)</label></p>
    <p><button type="button" data-nd-action="settings">Save</button></p>
    <p class="mg-note">Navidrome only reads the music, as its own user: the folder must be readable by everyone (shares
        normally are). Navidrome restarts.</p>

    <details class="mg-section">
        <summary>Backups</summary>
        <p>Navidrome backs up its database (users, playlists, favourites, play counts) every night to
            <code data-nd="backup-dir">-</code>, keeping 7. The music itself isn't in them.</p>
        <table data-nd="backups"></table>
    </details>

    <details class="mg-section">
        <summary>Navidrome's latest warnings</summary>
        <pre data-nd="log"></pre>
    </details>

    <p data-nd="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('navidrome', 'nd'); ?>
        <?php manage_secret_script(); ?>

        let loaded = false;

        /**
         * A size, for showing (e.g. 5.2 MB).
         *
         * @param {number} bytes The size, in bytes
         *
         * @return {string} The size, with its unit
         */
        function formatSize(bytes) {
            return bytes >= 1073741824 ? (bytes / 1073741824).toFixed(1) + ' GB'
                : (bytes >= 1048576 ? (bytes / 1048576).toFixed(1) + ' MB'
                    : Math.max(1, Math.round(bytes / 1024)) + ' KB');
        }

        /**
         * A time from Navidrome, for showing.
         *
         * @param {string} text The time
         *
         * @return {string} The time, or never (for none, or Navidrome's zero date)
         */
        function formatTime(text) {
            let date = new Date(text);

            return !text || date.getFullYear() < 2000 ? 'never' : date.toLocaleString();
        }

        /**
         * Shows Navidrome's libraries: each one's folder, what's in it and its last scan - or why there's nothing to
         * show.
         *
         * @param {Array.<Object>|null} libraries The libraries, or null if they couldn't be read
         * @param {boolean}             running   Whether Navidrome is running
         *
         * @return {void}
         */
        function fillLibraries(libraries, running) {
            let table = part('libraries');

            table.textContent = '';

            if (!libraries) {
                table.insertRow().insertCell().textContent = running
                    ? 'Can\'t log in to Navidrome as admin with the password above (make a new one to fix it)' : 'Navidrome isn\'t running';

                return;
            }

            libraries.forEach(function (library) {
                let row = table.insertRow();

                row.insertCell().textContent = library.name;
                row.insertCell().textContent = library.path;

                row = table.insertRow();

                row.insertCell();
                row.insertCell().textContent = library.songs + ' songs, ' + library.albums + ' albums, ' + library.artists
                    + ' artists (' + formatSize(library.size) + ') - ' + (library.scanning ? 'scanning…' : 'last scan: ' + formatTime(library.last_scan));
            });
        }

        /**
         * Shows the backups in their table.
         *
         * @param {Array.<Object>} backups The backups: name, time (seconds) and size
         *
         * @return {void}
         */
        function fillBackups(backups) {
            let table = part('backups');

            table.textContent = '';

            if (!backups.length) {
                table.insertRow().insertCell().textContent = 'No backups yet (the first is made tonight)';

                return;
            }

            backups.forEach(function (backup) {
                let row = table.insertRow();

                row.insertCell().textContent = backup.name;
                row.insertCell().textContent = new Date(backup.time * 1000).toLocaleString();
                row.insertCell().textContent = formatSize(backup.size);
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

                let status = part('status');

                status.textContent = !response.running ? 'Stopped' : (response.answering ? 'Running' : 'Starting…');
                status.className   = response.running && response.answering ? 'mg-ok' : 'mg-bad';

                part('version').textContent = response.version || '-';

                let addresses = [];

                if (response.site.url) {
                    addresses.push(response.site.url);
                }

                if (response.listen !== 'local' && response.local_url) {
                    addresses.push(response.local_url);
                }

                part('address').textContent = addresses.join(' or ') || '-';
                part('link').href           = response.site.url || response.local_url || '#';
                part('restart-note').hidden = !response.restart_needed;

                fillLibraries(response.libraries, response.running && response.answering);

                let note = part('music-note');

                note.textContent = response.music_readable ? '' : 'Navidrome can\'t read this folder';
                note.className   = 'mg-bad';

                part('backup-dir').textContent = response.backup_dir;

                fillBackups(response.backups);

                if (!loaded) {
                    part('music-folder').value = response.music_folder;
                    part('local').checked      = response.listen === 'local';
                    part('external').checked   = response.external;

                    loaded = true;
                }

                part('log').textContent = response.log.length ? response.log.join('\n') : 'Nothing logged';
            });
        }

        // Keep the page current, until the dashboard removes it
        <?php manage_timer_script(); ?>
        <?php manage_act_script(); ?>

        button('restart').addEventListener('click', function () {
            act('restart', { confirm: 1 }, 'Restarting Navidrome…', 'Navidrome restarted.');
        });

        button('scan').addEventListener('click', function () {
            act('scan', { full: 0 }, 'Starting a scan…', 'Scanning for changes.');
        });

        button('full-scan').addEventListener('click', function () {
            act('scan', { full: 1 }, 'Starting a full scan…', 'Rescanning everything - it can take a while for a large collection.');
        });

        // The admin password: Show / Hide and Copy (fetched when first needed)
        let password = secretControls(part('password'), button('show'), button('copy'), function () {
            return call('password', { show: 1 }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return null;
                }

                return response.password;
            });
        });

        button('new-password').addEventListener('click', function () {
            if (!window.confirm('Give admin a new password? Apps logged in as admin need the new one.')) {
                return;
            }

            act('new_password', { confirm: 1 }, 'Setting a new password…', 'New password in use.').then(function (response) {
                if (response) {
                    password.set(response.password);
                }
            });
        });

        button('settings').addEventListener('click', function () {
            act('settings', {
                music_folder: part('music-folder').value,
                listen:       part('local').checked ? 'local' : 'all',
                external:     part('external').checked ? 1 : 0
            }, 'Saving…', 'Saved - Navidrome restarted.');
        });

        refresh();
    })();
    </script>
</div>
