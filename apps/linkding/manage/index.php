<?php
// linkding's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('linkding');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="linkding-manage">
    <?php manage_styles('linkding-manage'); ?>

    <h2>linkding</h2>
    <table>
        <tr><td>Status</td><td data-ld="status">…</td></tr>
        <tr><td>Version</td><td data-ld="version">-</td></tr>
        <tr><td>Address</td><td data-ld="address">-</td></tr>
        <tr><td>Its worker</td><td data-ld="worker">-</td></tr>
    </table>
    <p><a class="mg-button" data-ld="link" href="#" target="_blank" rel="noopener">Open linkding</a>
        <button type="button" data-ld-action="restart">Restart linkding</button></p>

    <h3>Logging in</h3>
    <p>Its admin user is <code>admin</code>, with this password: <code data-ld="password">••••••••••••</code>
        <button type="button" data-ld-action="show">Show</button>
        <button type="button" data-ld-action="copy">Copy</button></p>
    <p><input type="password" data-ld="new" placeholder="New password (leave empty to generate one)" autocomplete="new-password">
        <button type="button" data-show-for="new">Show</button>
        <button type="button" data-ld-action="set">Change password</button></p>
    <p class="mg-note">The app made this account on linkding's first start (linkding has no sign-ups, so nobody else can
        claim it). Add the rest of the household in linkding's admin pages (Settings, Admin, Users), each with bookmarks
        of their own. If you change the password in linkding, this page no longer knows it: set a new one here.</p>
    <p data-ld="password-message"></p>

    <h3>Backups</h3>
    <p data-ld="backups">-</p>
    <p><button type="button" data-ld-action="backup">Back up now</button></p>
    <p class="mg-note">Every night at 03:20: linkding's own full backup - its bookmarks, tags, notes, uploaded files,
        favicons and previews, as a .zip - in <code>Nas_Prog/_linkding/backups</code> (only the NAS's administrator can
        read them). To restore one, stop linkding and unpack it into <code>Nas_Prog/_linkding/data</code>.</p>

    <h3>Settings</h3>
    <p><label><input type="checkbox" data-ld="local"> Only through the Nginx app (HTTPS)</label>
        <label>Keep <input type="number" data-ld="keep" min="1" max="99" value="14"> backups</label>
        <button type="button" data-ld-action="settings">Save</button></p>
    <p class="mg-note">Otherwise it's also reachable on port 9099 from the local network, over plain HTTP. linkding
        restarts.</p>

    <details class="mg-section">
        <summary>linkding's latest warnings and errors</summary>
        <pre data-ld="log"></pre>
    </details>

    <p data-ld="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('linkding', 'ld'); ?>
        <?php manage_secret_script(); ?>

        let loaded     = false;
        let siteStates = {
            no_nginx:  'the Nginx app isn\'t set up',
            no_domain: 'set a domain in the Nginx app',
            off:       'switched off in the Nginx app'
        };

        /**
         * The backups, as the page says them.
         *
         * @param {Array.<Object>} backups The newest backups: name, size (bytes) and time (seconds since 1970)
         *
         * @return {string} The text
         */
        function backupsText(backups) {
            if (!backups.length) {
                return 'None yet.';
            }

            let latest = backups[0];
            let size   = latest.size >= 1048576 ? `${(latest.size / 1048576).toFixed(1)} MB` : `${Math.max(1, Math.round(latest.size / 1024))} KB`;

            return `Latest: ${new Date(latest.time * 1000).toLocaleString()} (${size}, ${latest.name})`;
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

                // Its addresses: the Nginx app's (HTTPS), and port 9099 on the local network unless only through the
                // Nginx app
                let addresses = [];

                if (response.site.url) {
                    addresses.push(response.site.url);
                }

                if (response.listen === 'all') {
                    addresses.push(`http://${window.location.hostname}:9099/`);
                }

                let none  = 'none - turn off "Only through the Nginx app", or set the Nginx app up';
                let https = response.site.url ? '' : ` (HTTPS: ${siteStates[response.site.state]})`;

                part('address').textContent = `${addresses.join(' and ') || none}${https}`;
                part('address').className   = addresses.length ? '' : 'mg-bad';
                part('link').hidden         = !addresses.length;
                part('link').href           = addresses[0] || '#';
                let stopped = 'Stopped - no favicons, previews or snapshots: restart linkding';

                part('worker').textContent  = response.worker ? 'Running' : stopped;
                part('worker').className    = response.worker ? 'mg-ok' : 'mg-bad';
                part('backups').textContent = backupsText(response.backups);

                if (!loaded) {
                    part('local').checked = response.listen === 'local';
                    part('keep').value    = response.backup_keep;

                    loaded = true;
                }

                part('log').textContent = response.log.length ? response.log.join('\n') : 'Nothing logged';
            });
        }

        // Keep the page current, until the dashboard removes it
        <?php manage_timer_script(); ?>
        <?php manage_act_script(); ?>

        button('restart').addEventListener('click', function () {
            act('restart', { confirm: 1 }, 'Restarting linkding…', 'linkding restarted.');
        });

        // Its admin user's password: Show / Hide and Copy (fetched when first needed)
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
            act('set_password', { password: part('new').value.trim() }, 'Saving the password…', 'New password in use.', 'password-message').then(function (response) {
                if (response) {
                    secret.set(response.password);

                    part('new').value = '';
                }
            });
        });

        button('backup').addEventListener('click', function () {
            act('backup', { confirm: 1 }, 'Backing up…', 'Backed up.');
        });

        button('settings').addEventListener('click', function () {
            act('settings', {
                listen:      part('local').checked ? 'local' : 'all',
                backup_keep: part('keep').value
            }, 'Saving…', 'Saved - linkding restarted.');
        });

        refresh();
    })();
    </script>
</div>
