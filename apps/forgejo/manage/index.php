<?php
// Forgejo's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('forgejo');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="forgejo-manage">
    <?php manage_styles('forgejo-manage'); ?>

    <h2>Forgejo</h2>
    <table>
        <tr><td>Status</td><td data-fg="status">…</td></tr>
        <tr><td>Version</td><td data-fg="version">-</td></tr>
        <tr><td>Address</td><td data-fg="address">-</td></tr>
        <tr><td>Git over SSH</td><td data-fg="ssh-address">-</td></tr>
        <tr><td>Repositories</td><td data-fg="repositories">-</td></tr>
    </table>
    <p class="mg-note" data-fg="restart-note" hidden>The Nginx app's address for Forgejo has changed: restart Forgejo so that
        it uses it (for its links and clone addresses).</p>
    <p><a class="mg-button" data-fg="link" href="#" target="_blank" rel="noopener">Open Forgejo</a>
        <button type="button" data-fg-action="restart">Restart Forgejo</button></p>

    <h3>Admin user</h3>
    <p>User name <code>nas-admin</code>, password <code data-fg="password">••••••••••••</code>
        <button type="button" data-fg-action="show">Show</button> <button type="button" data-fg-action="copy">Copy</button>
        <button type="button" data-fg-action="new-password">New password</button></p>
    <p class="mg-note">Nobody can see anything without logging in, and there are no sign-ups: create your own users in
        Forgejo (Site administration → User accounts), and add your SSH keys in each user's settings.</p>
    <pre data-fg="example"></pre>

    <h3>Backups</h3>
    <p>Forgejo's own dump of everything (repositories, database, settings, attachments, LFS files) to
        <code data-fg="backup-dir">-</code>, made while it runs.</p>
    <p><label>Back up <select data-fg="backup">
            <option value="daily">daily</option>
            <option value="weekly">weekly (Sundays)</option>
            <option value="off">never</option>
        </select></label>
        <label>Keep <input type="number" data-fg="backup-keep" min="1" max="30" style="width: 5em"> backups</label></p>
    <p><button type="button" data-fg-action="backup">Back up now</button> <span data-fg="backup-running" hidden>Backing
        up…</span></p>
    <table data-fg="backups"></table>

    <h3>Settings</h3>
    <p><label><input type="checkbox" data-fg="local"> Web only through the Nginx app (HTTPS)</label><br>
        <label><input type="checkbox" data-fg="ssh"> Git over SSH (port 2222)</label></p>
    <p><button type="button" data-fg-action="settings">Save</button></p>
    <p class="mg-note">Saves the backup settings too. Forgejo restarts.</p>

    <details class="mg-section">
        <summary>Forgejo's latest warnings</summary>
        <pre data-fg="log"></pre>
    </details>

    <p data-fg="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('forgejo', 'fg'); ?>
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

                status.textContent = !response.running ? 'Stopped' : (response.answering ? 'Running' : 'Starting…');
                status.className   = response.running && response.answering ? 'mg-ok' : 'mg-bad';

                part('version').textContent = response.version || '-';

                let base = response.base_url || '-';

                part('address').textContent      = base + (response.listen === 'local' ? ' (only through the Nginx app)' : '');
                part('ssh-address').textContent  = response.ssh_url || 'Off';
                part('repositories').textContent = response.repositories;
                part('link').href                = response.base_url || '#';
                part('restart-note').hidden      = !response.restart_needed;
                part('example').textContent      = 'git clone ' + base.replace(/\/?$/, '/') + '<user>/<repository>.git'
                    + (response.ssh_url ? '\ngit clone ' + response.ssh_url + '<user>/<repository>.git' : '');
                part('backup-dir').textContent   = response.backup_dir;
                part('backup-running').hidden    = !response.backup_running;
                button('backup').disabled        = response.backup_running;

                fillBackups(response.backups);

                if (!loaded) {
                    part('local').checked     = response.listen === 'local';
                    part('ssh').checked       = response.ssh;
                    part('backup').value      = response.backup;
                    part('backup-keep').value = response.backup_keep;

                    loaded = true;
                }

                part('log').textContent = response.log.length ? response.log.join('\n') : 'Nothing logged';
            });
        }

        // Keep the page current, until the dashboard removes it
        <?php manage_timer_script(); ?>
        <?php manage_act_script(); ?>

        button('restart').addEventListener('click', function () {
            act('restart', { confirm: 1 }, 'Restarting Forgejo…', 'Forgejo restarted.');
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
            if (!window.confirm('Give nas-admin a new password? It\'s logged out of Forgejo, and needs the new one to log in again.')) {
                return;
            }

            act('new_password', { confirm: 1 }, 'Setting a new password…', 'New password in use.').then(function (response) {
                if (response) {
                    password.set(response.password);
                }
            });
        });

        button('backup').addEventListener('click', function () {
            act('backup', { confirm: 1 }, 'Starting the backup…', 'Backing up - it shows in the list when done.');
        });

        button('settings').addEventListener('click', function () {
            act('settings', {
                listen:      part('local').checked ? 'local' : 'all',
                ssh:         part('ssh').checked ? 1 : 0,
                backup:      part('backup').value,
                backup_keep: part('backup-keep').value
            }, 'Saving…', 'Saved - Forgejo restarted.');
        });

        refresh();
    })();
    </script>
</div>
