<?php
// Vaultwarden's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('vaultwarden');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="vaultwarden-manage">
    <?php manage_styles('vaultwarden-manage'); ?>

    <h2>Vaultwarden</h2>
    <table>
        <tr><td>Status</td><td data-vw="status">…</td></tr>
        <tr><td>Version</td><td data-vw="version">-</td></tr>
        <tr><td>Address</td><td data-vw="address">-</td></tr>
    </table>
    <p class="mg-note" data-vw="restart-note" hidden>The Nginx app's address for Vaultwarden has changed: restart Vaultwarden
        so that its links (e.g. in emails) use it.</p>
    <p><a class="mg-button" data-vw="link" href="#" target="_blank" rel="noopener" hidden>Open Vaultwarden</a>
        <a class="mg-button" data-vw="admin-link" href="#" target="_blank" rel="noopener" hidden>Admin panel</a>
        <button type="button" data-vw-action="restart">Restart Vaultwarden</button></p>

    <h3>Admin panel</h3>
    <p>Admin token: <code data-vw="token">••••••••••••</code>
        <button type="button" data-vw-action="show">Show</button> <button type="button" data-vw-action="copy">Copy</button>
        <button type="button" data-vw-action="new-token">New token</button></p>
    <p class="mg-note">The admin panel (at /admin) holds Vaultwarden's other settings: email (SMTP), two-step login,
        invitations, users and organisations. Only its hash is given to Vaultwarden; a new token restarts it.</p>

    <h3>Accounts</h3>
    <p><label><input type="checkbox" data-vw="signups"> Allow new accounts to sign up</label>
        <button type="button" data-vw-action="signups">Save</button></p>
    <p class="mg-note">Turn this off once your accounts exist; others can still be invited from the admin panel (which
        needs email set up, in its SMTP settings). Vaultwarden restarts.</p>

    <h3>Backups</h3>
    <p><label>Folder <input type="text" data-vw="backup-dir" size="40" spellcheck="false"></label>
        <label>Keep <input type="number" data-vw="backup-keep" min="1" max="365" style="width: 5em"> backups</label>
        <button type="button" data-vw-action="backup-settings">Save</button></p>
    <p><button type="button" data-vw-action="backup">Back up now</button>
        <span class="mg-note">Every day at 02:15: the database (copied safely while Vaultwarden runs), attachments, sends,
            its keys and admin panel settings, readable by root only.</span></p>
    <table data-vw="backups"></table>

    <details class="mg-section">
        <summary>Vaultwarden's latest warnings</summary>
        <pre data-vw="log"></pre>
    </details>

    <p data-vw="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('vaultwarden', 'vw'); ?>
        <?php manage_secret_script(); ?>

        let loaded     = false;
        let siteStates = {
            no_nginx:  'The Nginx app isn\'t set up - it serves Vaultwarden over HTTPS, which its web vault needs',
            no_domain: 'Set a domain in the Nginx app first: Vaultwarden is then at https://vaultwarden.<domain>',
            off:       'Switched off in the Nginx app (turn its Vaultwarden entry back on there)'
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
                table.insertRow().insertCell().textContent = hasDb ? 'No backups yet' : 'No backups yet (there is nothing to back up until an account is created)';

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

                part('version').textContent = response.version ? response.version + (response.web_vault ? ' (web vault ' + response.web_vault + ')' : '') : '-';

                let address = part('address');

                address.textContent = response.site.url || siteStates[response.site.state];
                address.className   = response.site.url ? '' : 'mg-bad';

                part('link').hidden         = part('admin-link').hidden = !response.site.url;
                part('link').href           = response.site.url;
                part('admin-link').href     = response.site.url + 'admin';
                part('restart-note').hidden = !response.restart_needed;

                // The settings are only filled in once, so a refresh doesn't undo changes being made
                if (!loaded) {
                    part('signups').checked        = response.signups;
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
            act('restart', { confirm: 1 }, 'Restarting Vaultwarden…', 'Vaultwarden restarted.');
        });

        button('signups').addEventListener('click', function () {
            let on = part('signups').checked;

            act('signups', { on: on ? 1 : 0 }, 'Saving…', on ? 'New accounts can sign up.' : 'Sign-ups are off.');
        });

        // The admin token: Show / Hide and Copy (fetched when first needed)
        let secret = secretControls(part('token'), button('show'), button('copy'), function () {
            return call('token', { show: 1 }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return null;
                }

                return response.token;
            });
        });

        button('new-token').addEventListener('click', function () {
            if (!window.confirm('Make a new admin token? The current one stops working, and Vaultwarden restarts.')) {
                return;
            }

            act('new_token', { confirm: 1 }, 'Making a new token…', 'New admin token in use.').then(function (response) {
                if (response) {
                    secret.set(response.token);
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
