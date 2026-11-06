<?php
// MongoDB's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('mongodb');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="mongodb-manage">
    <?php manage_styles('mongodb-manage'); ?>

    <h2>MongoDB</h2>
    <table>
        <tr><td>Status</td><td data-mg="status">…</td></tr>
        <tr><td>Version</td><td data-mg="version">-</td></tr>
        <tr><td>Address</td><td data-mg="address">-</td></tr>
    </table>
    <p><button type="button" data-mg-action="restart">Restart MongoDB</button></p>

    <h3>Its administrator</h3>
    <p>User <code>admin</code> (all rights, on every database), with this password: <code data-mg="password">••••••••••••</code>
        <button type="button" data-mg-action="show">Show</button> <button type="button" data-mg-action="copy">Copy</button></p>
    <p><input type="text" data-mg="new" placeholder="New password (leave empty to generate one)" autocomplete="off" spellcheck="false">
        <button type="button" data-mg-action="set">Change password</button></p>
    <p class="mg-note">The new password is in use at once (the Compass Web app follows it). Passwords are 12-128
        characters: letters, digits and . _ ~ - Connection string:
        <code data-mg="uri">mongodb://admin:&lt;password&gt;@&lt;address&gt;:27017/?authSource=admin</code></p>

    <h3>Databases</h3>
    <table data-mg="databases"></table>
    <p><input type="text" data-mg="dbname" placeholder="New database (e.g. myapp)" autocomplete="off" spellcheck="false">
        <button type="button" data-mg-action="create">Create, with its own login</button></p>
    <p class="mg-note">Each database made here gets a login of the same name, with rights on it alone (read, write,
        indexes) and a generated password - shown once, below. Making it again gives the login a new password.</p>
    <p data-mg="created" hidden></p>

    <h3>Access and memory</h3>
    <p><label><input type="checkbox" data-mg="network"> Reachable from the local network (port 27017)</label></p>
    <p><label>Memory for its cache <select data-mg="cache">
        <option value="256">256 MB</option>
        <option value="512">512 MB</option>
        <option value="1024">1 GB</option>
        <option value="2048">2 GB</option>
        <option value="4096">4 GB</option>
    </select></label> <button type="button" data-mg-action="settings">Save</button></p>
    <p class="mg-note">Otherwise only programs on the NAS itself reach it. Logins are always needed; its connections
        aren't encrypted (no TLS) - keep it to your own network. MongoDB restarts.</p>

    <h3>Backups</h3>
    <p><label>Folder <input type="text" data-mg="backup-dir" size="40" spellcheck="false"></label>
        <label>Keep <input type="number" data-mg="backup-keep" min="1" max="365" style="width: 5em"> backups</label>
        <button type="button" data-mg-action="backup-settings">Save</button></p>
    <p><button type="button" data-mg-action="backup">Back up now</button>
        <span class="mg-note">Every day at 03:15: every database (mongodump, while MongoDB runs), in one compressed
            archive readable by root only.</span></p>
    <table data-mg="backups"></table>

    <details class="mg-section">
        <summary>MongoDB's latest warnings</summary>
        <pre data-mg="log"></pre>
    </details>

    <p data-mg="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('mongodb', 'mg'); ?>
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
            return bytes >= 1048576 ? (bytes / 1048576).toFixed(1) + ' MB' : Math.max(1, Math.round(bytes / 1024)) + ' KB';
        }

        /**
         * Shows a list in a table, one row per entry.
         *
         * @param {HTMLTableElement} table   The table
         * @param {Array.<Array>}    rows    Each row's cells (text)
         * @param {string}           nothing What to show when there are none
         *
         * @return {void}
         */
        function fillTable(table, rows, nothing) {
            table.textContent = '';

            if (!rows.length) {
                table.insertRow().insertCell().textContent = nothing;

                return;
            }

            rows.forEach(function (cells) {
                let row = table.insertRow();

                cells.forEach(function (text) {
                    row.insertCell().textContent = text;
                });
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
                part('address').textContent = response.listen === 'all' ? window.location.hostname + ':27017 (and 127.0.0.1:27017 on the NAS)' :
                    '127.0.0.1:27017 (programs on the NAS itself only)';
                part('uri').textContent     = 'mongodb://admin:<password>@' + (response.listen === 'all' ? window.location.hostname : '127.0.0.1') +
                    ':27017/?authSource=admin';

                fillTable(part('databases'), response.databases.map(function (d) {
                    return [d.name, formatSize(d.size)];
                }), response.answering ? 'No databases yet' : 'Shown once MongoDB is running');
                fillTable(part('backups'), response.backups.map(function (b) {
                    return [b.name, new Date(b.time * 1000).toLocaleString(), formatSize(b.size)];
                }), 'No backups yet');

                if (!loaded) {
                    part('network').checked        = response.listen === 'all';
                    part('cache').value            = String(response.cache_mb);
                    part('backup-dir').value       = response.backup_dir;
                    part('backup-dir').placeholder = response.backup_dir_default;
                    part('backup-keep').value      = response.backup_keep;

                    loaded = true;
                }

                part('log').textContent = response.log.length ? response.log.join('\n') : 'Nothing logged';
            });
        }

        // Keep the page current, until the dashboard removes it
        <?php manage_timer_script(); ?>
        <?php manage_act_script(); ?>

        button('restart').addEventListener('click', function () {
            act('restart', { confirm: 1 }, 'Restarting MongoDB…', 'MongoDB restarted.');
        });

        button('settings').addEventListener('click', function () {
            act('settings', { listen: part('network').checked ? 'all' : 'local', cache_mb: part('cache').value }, 'Saving…', 'Saved: MongoDB restarted.');
        });

        button('create').addEventListener('click', function () {
            act('create_db', { name: part('dbname').value.trim() }, 'Creating…').then(function (response) {
                if (response) {
                    let created = part('created');

                    created.hidden      = false;
                    created.textContent = 'Database ' + response.user + ': its login is ' + response.user + ', password ' + response.password +
                        ' (not shown again) - mongodb://' + response.user + ':' + response.password + '@127.0.0.1:27017/' + response.user;
                    part('dbname').value = '';
                }
            });
        });

        button('backup-settings').addEventListener('click', function () {
            act('backup_settings', { dir: part('backup-dir').value, keep: part('backup-keep').value }, 'Saving…', 'Backup settings saved.');
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
