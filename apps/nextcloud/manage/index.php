<?php
// Nextcloud's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('nextcloud');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="nextcloud-manage">
    <?php manage_styles('nextcloud-manage'); ?>

    <h2>Nextcloud</h2>
    <table>
        <tr><td>Status</td><td data-nc="status">…</td></tr>
        <tr><td>Version</td><td data-nc="version">-</td></tr>
        <tr><td>Address</td><td data-nc="address">-</td></tr>
        <tr><td>Database</td><td data-nc="db">-</td></tr>
    </table>
    <p><a class="mg-button" data-nc="link" href="#" target="_blank" rel="noopener">Open Nextcloud</a>
        <button type="button" data-nc-action="scan">Find new files</button>
        <button type="button" data-nc-action="restart">Restart Nextcloud</button></p>
    <p class="mg-note">Find new files: files put straight into Nextcloud's data folder (not through Nextcloud) aren't seen
        until it looks for them.</p>

    <h3>Logging in</h3>
    <p>Its administrator logs in as <code>admin</code>, with this password: <code data-nc="password">••••••••••••</code>
        <button type="button" data-nc-action="show">Show</button> <button type="button" data-nc-action="copy">Copy</button></p>
    <p><input type="text" data-nc="new" placeholder="New password (leave empty to generate one)" autocomplete="off" spellcheck="false">
        <button type="button" data-nc-action="set">Change password</button></p>
    <p class="mg-note">The new password is in use at once. Passwords are 12-72 characters: letters, digits and . _ ~ - (A
        password changed in Nextcloud itself isn't shown here.) Other people's accounts are added in Nextcloud (Accounts),
        each with a password of their own.</p>

    <h3>Access</h3>
    <p><label><input type="checkbox" data-nc="local"> Only through the Nginx app (HTTPS)</label>
        <button type="button" data-nc-action="listen">Save</button></p>
    <p class="mg-note">Otherwise Nextcloud is also reachable on port 8097 from the local network, over plain HTTP (passwords
        then cross the network unencrypted). Nextcloud restarts.</p>

    <h3>Backups</h3>
    <p><label>Folder <input type="text" data-nc="backup-dir" size="40" spellcheck="false"></label>
        <label>Keep <input type="number" data-nc="backup-keep" min="1" max="365" style="width: 5em"> backups</label>
        <button type="button" data-nc-action="backup-settings">Save</button></p>
    <p><button type="button" data-nc-action="backup">Back up now</button>
        <span class="mg-note">Every day at 03:45: its whole database (its accounts, shares, calendars, contacts and the
            files' records - copied safely while Nextcloud runs), readable by root only. The files themselves are in its
            data folder (back it up with e.g. the Kopia app).</span></p>
    <table data-nc="backups"></table>

    <details class="mg-section">
        <summary>Nextcloud's latest warnings and errors</summary>
        <pre data-nc="log"></pre>
    </details>

    <p data-nc="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('nextcloud', 'nc'); ?>
        <?php manage_secret_script(); ?>

        let loaded     = false;
        let siteStates = {
            no_nginx:  'the Nginx app isn\'t set up',
            no_domain: 'set a domain in the Nginx app',
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
            return bytes >= 1048576 ? `${(bytes / 1048576).toFixed(1)} MB` : `${Math.max(1, Math.round(bytes / 1024))} KB`;
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
                table.insertRow().insertCell().textContent = 'No backups yet';

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

                status.textContent = !response.running ? 'Stopped' : (response.answering ? (response.maintenance ? 'Running (in maintenance mode)' : 'Running') : 'Starting… (its first start installs it: a few minutes)');
                status.className   = response.running && response.answering ? 'mg-ok' : 'mg-bad';

                part('version').textContent = response.version || '-';

                // Its addresses: the Nginx app's (HTTPS), and port 8097 on the local network unless only through the
                // Nginx app
                let addresses = [];

                if (response.site.url) {
                    addresses.push(response.site.url);
                }

                if (response.listen === 'all') {
                    addresses.push(`http://${window.location.hostname}:8097/`);
                }

                part('address').textContent = (addresses.join(' and ') || 'none - turn off "Only through the Nginx app", or set the Nginx app up') +
                    (response.site.url ? '' : ` (HTTPS: ${siteStates[response.site.state]})`);
                part('address').className   = addresses.length ? '' : 'mg-bad';
                part('link').hidden         = !addresses.length;
                part('link').href           = addresses[0] || '#';

                // Its database, in the PostgreSQL app
                let db = part('db');

                if (!response.postgresql) {
                    db.textContent = 'The PostgreSQL app isn\'t installed: Nextcloud keeps everything in it';
                } else if (response.db.state === 'ok') {
                    db.textContent = 'nextcloud, in the PostgreSQL app';
                } else {
                    db.textContent = response.db.state === 'failed' ? `Not set up: ${response.db.message}` : 'Not set up yet';
                }

                db.className = response.postgresql && response.db.state === 'ok' ? 'mg-ok' : 'mg-bad';

                if (!loaded) {
                    part('local').checked          = response.listen === 'local';
                    part('backup-dir').value       = response.backup_dir;
                    part('backup-dir').placeholder = response.backup_dir_default;
                    part('backup-keep').value      = response.backup_keep;

                    loaded = true;
                }

                fillBackups(response.backups);
                part('log').textContent = response.log.length ? response.log.join('\n') : 'Nothing logged';
            });
        }

        // Keep the page current, until the dashboard removes it
        <?php manage_timer_script(); ?>
        <?php manage_act_script(); ?>

        button('restart').addEventListener('click', function () {
            act('restart', { confirm: 1 }, 'Restarting Nextcloud…', 'Nextcloud restarted.');
        });

        button('listen').addEventListener('click', function () {
            let local = part('local').checked;

            act('listen', { listen: local ? 'local' : 'all' }, 'Saving…', local ? 'Nextcloud is now only reachable through the Nginx app.' :
                'Nextcloud is reachable on port 8097 too.');
        });

        button('backup-settings').addEventListener('click', function () {
            act('backup_settings', { dir: part('backup-dir').value, keep: part('backup-keep').value }, 'Saving…', 'Backup settings saved.');
        });

        button('scan').addEventListener('click', function () {
            act('scan', { confirm: 1 }, 'Looking for new files…', 'Looking for new files - they show in Nextcloud once found.');
        });

        button('backup').addEventListener('click', function () {
            act('backup_now', { confirm: 1 }, 'Backing up…');
        });

        // Its administrator's password: Show / Hide and Copy (fetched when first needed)
        let secret = secretControls(part('password'), button('show'), button('copy'), function () {
            return call('password', { show: 1 }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return null;
                }

                return response.password;
            });
        });

        button('set').addEventListener('click', function () {
            act('set_password', { password: part('new').value.trim() }, 'Saving the password…', 'New password in use.').then(function (response) {
                if (response) {
                    secret.set(response.password);

                    part('new').value = '';
                }
            });
        });

        refresh();
    })();
    </script>
</div>
