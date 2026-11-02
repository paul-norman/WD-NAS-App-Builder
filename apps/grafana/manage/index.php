<?php
// Grafana's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('grafana');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="grafana-manage">
    <?php manage_styles('grafana-manage'); ?>

    <h2>Grafana</h2>
    <table>
        <tr><td>Status</td><td data-gf="status">…</td></tr>
        <tr><td>Version</td><td data-gf="version">-</td></tr>
        <tr><td>Address</td><td data-gf="address">-</td></tr>
        <tr><td>Data source</td><td data-gf="datasource">-</td></tr>
    </table>
    <p><a class="mg-button" data-gf="link" href="#" target="_blank" rel="noopener">Open Grafana</a>
        <button type="button" data-gf-action="restart">Restart Grafana</button></p>

    <h3>Admin account</h3>
    <p>Log in as <code>admin</code> with: <code data-gf="password">••••••••••••</code>
        <button type="button" data-gf-action="show">Show</button> <button type="button" data-gf-action="copy">Copy</button>
        <button type="button" data-gf-action="reset">Reset the password</button></p>
    <p class="mg-note">The first password is generated when Grafana's database is created. A password changed in Grafana
        itself isn't shown here; resetting sets a new random one.</p>

    <h3>Access</h3>
    <p><label><input type="checkbox" data-gf="local"> Only through the Nginx app (HTTPS)</label>
        <button type="button" data-gf-action="listen">Save</button></p>
    <p class="mg-note">Otherwise Grafana is also reachable on port 3000 from the local network (over plain HTTP). Grafana
        restarts.</p>

    <h3>Backups</h3>
    <p><label>Folder <input type="text" data-gf="backup-dir" size="40" spellcheck="false"></label>
        <label>Keep <input type="number" data-gf="backup-keep" min="1" max="365" style="width: 5em"> backups</label>
        <button type="button" data-gf-action="backup-settings">Save</button></p>
    <p><button type="button" data-gf-action="backup">Back up now</button>
        <span class="mg-note">Every day at 02:45: Grafana's database (copied safely while it runs), with its dashboards,
            users, data sources, alerts and settings, readable by root only.</span></p>
    <table data-gf="backups"></table>

    <details class="mg-section">
        <summary>Grafana's latest warnings</summary>
        <pre data-gf="log"></pre>
    </details>

    <p data-gf="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('grafana', 'gf'); ?>
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
                table.insertRow().insertCell().textContent = hasDb ? 'No backups yet' : 'No backups yet (there is nothing to back up until Grafana has started once)';

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

                status.textContent = !response.running ? 'Stopped' : (response.answering ? 'Running' : 'Starting… (the first start takes a minute or two)');
                status.className = response.running && response.answering ? 'mg-ok' : 'mg-bad';

                part('version').textContent = response.version || '-';

                // Its addresses: the Nginx app's (HTTPS), and port 3000 on the local network unless that's turned off
                let local     = 'http://' + window.location.hostname + ':3000/';
                let addresses = [];

                if (response.site.url) {
                    addresses.push(response.site.url);
                }

                if (response.listen === 'all') {
                    addresses.push(local);
                }

                part('address').textContent    = (addresses.join(' and ') || 'none') + (response.site.url ? '' : ' (HTTPS: ' + siteStates[response.site.state] + ')');
                part('address').className      = addresses.length ? '' : 'mg-bad';
                part('link').hidden            = !addresses.length;
                part('link').href              = addresses[0] || '#';
                part('datasource').textContent = response.prometheus ? 'the Prometheus app (with the NAS dashboards in the "NAS" folder)' :
                    'none set up - install the Prometheus app, then restart Grafana';
                part('datasource').className   = response.prometheus ? '' : 'mg-bad';

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
            act('restart', { confirm: 1 }, 'Restarting Grafana…', 'Grafana restarted.');
        });

        button('listen').addEventListener('click', function () {
            let local = part('local').checked;

            if (local && !window.confirm('Only allow access through the Nginx app? Port 3000 stops answering on the network.')) {
                return;
            }

            act('listen', { listen: local ? 'local' : 'all' }, 'Saving…', local ? 'Grafana is now only reachable through the Nginx app.' :
                'Grafana is reachable on port 3000 too.');
        });

        // The admin password: Show / Hide and Copy (fetched when first needed)
        let secret = secretControls(part('password'), button('show'), button('copy'), function () {
            return call('password', { show: 1 }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return null;
                }

                return response.password || '(none saved)';
            });
        });

        button('reset').addEventListener('click', function () {
            if (!window.confirm('Reset the admin account\'s password to a new random one?')) {
                return;
            }

            act('reset_password', { confirm: 1 }, 'Resetting the password…', 'Password reset - log in with the new one.').then(function (response) {
                if (response) {
                    secret.set(response.password);
                }
            });
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
