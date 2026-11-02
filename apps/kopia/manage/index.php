<?php
// Kopia's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('kopia');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="kopia-manage">
    <?php manage_styles('kopia-manage'); ?>

    <h2>Kopia</h2>
    <table>
        <tr><td>Status</td><td data-kp="status">…</td></tr>
        <tr><td>Version</td><td data-kp="version">-</td></tr>
        <tr><td>Address</td><td data-kp="address">-</td></tr>
        <tr><td>Repository</td><td data-kp="repo">-</td></tr>
    </table>
    <p><a class="mg-button" data-kp="link" href="#" target="_blank" rel="noopener">Open Kopia</a>
        <button type="button" data-kp-action="restart">Restart Kopia</button></p>

    <h3>Logging in</h3>
    <p>Log in to Kopia as <code>admin</code> with: <code data-kp="password">••••••••••••</code>
        <button type="button" data-kp-action="show">Show</button> <button type="button" data-kp-action="copy">Copy</button>
        <button type="button" data-kp-action="new-password">New password</button></p>
    <p class="mg-note">This is only Kopia's web interface login. The repository's own password (which encrypts the backups,
        set when the repository is created) is separate: keep a copy away from the NAS - without it the backups can't be
        restored.</p>

    <h3>Backups</h3>
    <table data-kp="sources"></table>
    <p class="mg-note">Folders to back up, their schedules and how many snapshots to keep are set in Kopia (Snapshots → New
        Snapshot, and Policies). The NAS's shares are under /mnt/HD/HD_a2 (e.g. /mnt/HD/HD_a2/Public).</p>

    <h3>Access</h3>
    <p><label><input type="checkbox" data-kp="local"> Only through the Nginx app (HTTPS)</label>
        <button type="button" data-kp-action="listen">Save</button></p>
    <p class="mg-note">Otherwise Kopia is also reachable on port 51515 from the local network, over plain HTTP. It can read
        and restore any file on the NAS, so HTTPS through the Nginx app is safer. Kopia restarts (a snapshot in progress
        resumes later).</p>

    <details class="mg-section">
        <summary>Kopia's latest output</summary>
        <pre data-kp="log"></pre>
    </details>

    <p data-kp="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('kopia', 'kp'); ?>
        <?php manage_secret_script(); ?>

        let loaded     = false;
        let siteStates = {
            no_nginx: 'the Nginx app isn\'t set up',
            no_domain: 'set a domain in the Nginx app for HTTPS',
            off:       'switched off in the Nginx app'
        };

        /**
         * A size, for showing (e.g. 5.2 MB).
         *
         * @param {number} bytes The size, in bytes
         *
         * @return {string} The size, with its unit
         */
        function formatSize(bytes) {
            let units = ['B', 'KB', 'MB', 'GB', 'TB'];
            let i     = 0;

            while (bytes >= 1000 && i < units.length - 1) {
                bytes /= 1000;

                i++;
            }

            return (i ? bytes.toFixed(1) : bytes) + ' ' + units[i];
        }

        /**
         * A time, for showing.
         *
         * @param {string} time The time ('' for none)
         *
         * @return {string} The time, or - for none
         */
        function formatTime(time) {
            return time ? new Date(time).toLocaleString() : '-';
        }

        /**
         * Shows the backup sources: each folder's last and next snapshot, its size and its state. Paths come from
         * Kopia, so they're only ever set as text.
         *
         * @param {Array.<Object>} sources The sources
         * @param {Object|null}    repo    The repository's status (whether it's connected)
         *
         * @return {void}
         */
        function fillSources(sources, repo) {
            let table = part('sources');

            table.textContent = '';

            if (!sources.length) {
                table.insertRow().insertCell().textContent = repo && repo.connected ? 'No folders backed up yet - add them in Kopia (Snapshots → New Snapshot)' :
                    'Connect Kopia to a repository first (open Kopia: where the backups are stored, e.g. Backblaze B2, S3, an SFTP server or a USB drive)';

                return;
            }

            let head = table.insertRow();

            ['Folder', 'Last snapshot', 'Size', 'Next', 'State'].forEach(function (text) {
                let cell = head.insertCell();

                cell.textContent      = text;
                cell.style.fontWeight = 'bold';
            });

            sources.forEach(function (source) {
                let row = table.insertRow();

                row.insertCell().textContent = source.path;
                row.insertCell().textContent = formatTime(source.last);
                row.insertCell().textContent = source.size === null ? '-' : formatSize(source.size);
                row.insertCell().textContent = formatTime(source.next);

                let state = row.insertCell();

                state.textContent = source.status === 'UPLOADING' ? 'backing up now' : (source.errors ? source.errors + ' file error(s) last time' : (source.last ? 'ok' : 'not backed up yet'));
                state.className   = source.errors || !source.last ? 'mg-bad' : 'mg-ok';
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

                // Its addresses: the Nginx app's (HTTPS), and port 51515 on the local network unless only through the
                // Nginx app
                let local     = 'http://' + window.location.hostname + ':51515/';
                let addresses = [];

                if (response.site.url) {
                    addresses.push(response.site.url);
                }

                if (response.listen === 'all') {
                    addresses.push(local);
                }

                part('address').textContent = (addresses.join(' and ') || 'none - turn off "Only through the Nginx app", or set the Nginx app up') +
                    (response.site.url ? '' : ' (HTTPS: ' + siteStates[response.site.state] + ')');
                part('address').className = addresses.length ? '' : 'mg-bad';
                part('link').hidden = !addresses.length;
                part('link').href = addresses[0] || '#';

                let repo = part('repo');

                repo.textContent = !response.repo ? '-' : (response.repo.connected ? 'connected' + (response.repo.description ? ': ' + response.repo.description : '') :
                    'not set up yet - open Kopia to create or connect a repository (where the backups go)');
                repo.className   = response.repo && !response.repo.connected ? 'mg-bad' : '';

                if (!loaded) {
                    part('local').checked = response.listen === 'local';

                    loaded = true;
                }

                fillSources(response.sources, response.repo);

                part('log').textContent = response.log.length ? response.log.join('\n') : 'Nothing logged';
            });
        }

        // Keep the page current (e.g. while a snapshot runs), until the dashboard removes it
        <?php manage_timer_script(); ?>
        <?php manage_act_script(); ?>

        button('restart').addEventListener('click', function () {
            act('restart', { confirm: 1 }, 'Restarting Kopia…', 'Kopia restarted.');
        });

        button('listen').addEventListener('click', function () {
            let local = part('local').checked;

            act('listen', { listen: local ? 'local' : 'all' }, 'Saving…', local ? 'Kopia is now only reachable through the Nginx app.' :
                'Kopia is reachable on port 51515 too.');
        });

        // The web interface's password: Show / Hide and Copy (fetched when first needed)
        let secret = secretControls(part('password'), button('show'), button('copy'), function () {
            return call('password', { show: 1 }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return null;
                }

                return response.password;
            });
        });

        button('new-password').addEventListener('click', function () {
            if (!window.confirm('Make a new password for Kopia\'s web interface? Kopia restarts.')) {
                return;
            }

            act('new_password', { confirm: 1 }, 'Making a new password…', 'New password in use.').then(function (response) {
                if (response) {
                    secret.set(response.password);
                }
            });
        });

        refresh();
    })();
    </script>
</div>
