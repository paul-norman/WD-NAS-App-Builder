<?php
// Uptime Kuma's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('uptime-kuma');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="uptime-kuma-manage">
    <?php manage_styles('uptime-kuma-manage'); ?>

    <h2>Uptime Kuma</h2>
    <table>
        <tr><td>Status</td><td data-uk="status">…</td></tr>
        <tr><td>Version</td><td data-uk="version">-</td></tr>
        <tr><td>Address</td><td data-uk="address">-</td></tr>
    </table>
    <p><a class="mg-button" data-uk="link" href="#" target="_blank" rel="noopener">Open Uptime Kuma</a>
        <button type="button" data-uk-action="restart">Restart Uptime Kuma</button></p>

    <h3>Access</h3>
    <p><label><input type="checkbox" data-uk="local"> Only through the Nginx app (HTTPS)</label>
        <button type="button" data-uk-action="listen">Save</button></p>
    <p class="mg-note">Otherwise Uptime Kuma is also reachable on port 3001 from the local network (over plain HTTP).
        Uptime Kuma restarts. Behind the Nginx app, turn on "Trust Proxy" in its Settings → Reverse Proxy, so that it logs
        the real addresses of its visitors.</p>

    <h3>Admin account</h3>
    <p data-uk="account">-</p>
    <p><button type="button" data-uk-action="reset">Reset the password</button>
        <span data-uk="new-password" hidden>New password: <code data-uk="password"></code>
        <button type="button" data-uk-action="copy">Copy</button></span></p>
    <p class="mg-note">Sets a new random password (shown here once) and logs every session out.</p>

    <h3>Backups</h3>
    <p><label>Folder <input type="text" data-uk="backup-dir" size="40" spellcheck="false"></label>
        <label>Keep <input type="number" data-uk="backup-keep" min="1" max="365" style="width: 5em"> backups</label>
        <button type="button" data-uk-action="backup-settings">Save</button></p>
    <p><button type="button" data-uk-action="backup">Back up now</button>
        <span class="mg-note">Every day at 02:30: the database (copied safely while Uptime Kuma runs, with its monitors,
            history and settings) and uploaded images, readable by root only.</span></p>
    <table data-uk="backups"></table>

    <details class="mg-section">
        <summary>Uptime Kuma's latest log</summary>
        <pre data-uk="log"></pre>
    </details>

    <p data-uk="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('uptime-kuma', 'uk'); ?>
        <?php manage_secret_script(); ?>

        let loaded     = false;
        let siteStates = {
            no_nginx:  'the Nginx app isn\'t set up',
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
            return bytes >= 1048576 ? (bytes / 1048576).toFixed(1) + ' MB' : Math.max(1, Math.round(bytes / 1024)) + ' KB';
        }

        /**
         * Shows the backups in their table.
         *
         * @param {Array.<Object>} backups The backups: name, time (seconds) and size
         * @param {boolean}        hasDb   Whether there's anything to back up yet
         *
         * @return {void}
         */
        function fillBackups(backups, hasDb) {
            let table = part('backups');

            table.textContent = '';

            if (!backups.length) {
                table.insertRow().insertCell().textContent = hasDb ? 'No backups yet' : 'No backups yet (there is nothing to back up until Uptime Kuma is set up)';

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

                status.textContent = !response.running ? 'Stopped' : (response.answering ? 'Running' : 'Starting… (the first start takes a minute)');
                status.className   = response.running && response.answering ? 'mg-ok' : 'mg-bad';

                part('version').textContent = response.version || '-';

                // Its addresses: the Nginx app's (HTTPS), and port 3001 on the local network unless that's turned off
                let local     = 'http://' + window.location.hostname + ':3001/';
                let addresses = [];

                if (response.site.url) {
                    addresses.push(response.site.url);
                }

                if (response.listen === 'all') {
                    addresses.push(local);
                }

                part('address').textContent = (addresses.join(' and ') || 'none') + (response.site.url ? '' : ' (HTTPS: ' + siteStates[response.site.state] + ')');
                part('address').className   = addresses.length ? '' : 'mg-bad';
                part('link').hidden         = !addresses.length;
                part('link').href           = addresses[0] || '#';
                part('account').textContent = response.user ? 'User name: ' + response.user : 'Not set up yet: open Uptime Kuma to create the admin account.';

                button('reset').disabled = !response.user;

                // The settings are only filled in once, so a refresh doesn't undo changes being made
                if (!loaded) {
                    part('local').checked          = response.listen === 'local';
                    part('backup-dir').value       = response.backup_dir;
                    part('backup-dir').placeholder = response.backup_dir_default;
                    part('backup-keep').value      = response.backup_keep;

                    loaded = true;
                }

                fillBackups(response.backups, response.has_db);

                part('log').textContent = response.log.length ? response.log.join('\n') : 'Nothing logged';
            });
        }

        // Keep the page current, until the dashboard removes it
        <?php manage_timer_script(); ?>

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

                say(done || response.message, true);
                refresh();

                return response;
            });
        }

        button('restart').addEventListener('click', function () {
            act('restart', { confirm: 1 }, 'Restarting Uptime Kuma…', 'Uptime Kuma restarted.');
        });

        button('listen').addEventListener('click', function () {
            let local = part('local').checked;

            if (local && !window.confirm('Only allow access through the Nginx app? Port 3001 stops answering on the network.')) {
                return;
            }

            act('listen', { listen: local ? 'local' : 'all' }, 'Saving…', local ? 'Uptime Kuma is now only reachable through the Nginx app.' :
                'Uptime Kuma is reachable on port 3001 too.');
        });

        button('reset').addEventListener('click', function () {
            if (!window.confirm('Reset the admin account\'s password? Every session is logged out.')) {
                return;
            }

            act('reset_password', { confirm: 1 }, 'Resetting the password…', 'Password reset - log in with the new one.').then(function (response) {
                if (!response) {
                    return;
                }

                part('password').textContent = response.password;
                part('new-password').hidden  = false;
            });
        });

        button('copy').addEventListener('click', function () {
            copyText(part('password').textContent);
        });

        button('backup-settings').addEventListener('click', function () {
            act('backup_settings', { dir: part('backup-dir').value, keep: part('backup-keep').value }, 'Saving…', 'Backup settings saved.');
        });

        button('backup').addEventListener('click', function () {
            act('backup_now', { confirm: 1 }, 'Backing up…');
        });

        refresh();
    })();
    </script>
</div>
