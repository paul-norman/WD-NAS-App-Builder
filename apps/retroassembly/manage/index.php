<?php
// RetroAssembly's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('retroassembly');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="retroassembly-manage">
    <?php manage_styles('retroassembly-manage'); ?>

    <h2>RetroAssembly</h2>
    <table>
        <tr><td>Status</td><td data-ra="status">…</td></tr>
        <tr><td>Version</td><td data-ra="version">-</td></tr>
        <tr><td>Address</td><td data-ra="address">-</td></tr>
    </table>
    <p><a class="mg-button" data-ra="link" href="#" target="_blank" rel="noopener">Open RetroAssembly</a>
        <button type="button" data-ra-action="restart">Restart RetroAssembly</button></p>

    <h3>Logging in</h3>
    <p>User name <code data-ra="admin">admin</code>, password <code data-ra="password">••••••••••••</code>
        <button type="button" data-ra-action="show">Show</button>
        <button type="button" data-ra-action="copy">Copy</button>
        <button type="button" data-ra-action="new-password">Reset the password</button></p>
    <p class="mg-note">The app made this account, so nobody else can claim RetroAssembly - and gave it a few free
        homebrew games to start with (delete them from each game's menu whenever you like). It's RetroAssembly's
        admin: add the rest of the household in RetroAssembly (Settings, Accounts), each with a library of their own or
        a view of yours. If you change its password in RetroAssembly, this page no longer knows it: Reset the password
        sets a new one it shows (and signs the account out everywhere).</p>

    <h3>Backups</h3>
    <p data-ra="backups">-</p>
    <p><button type="button" data-ra-action="backup">Back up now</button></p>
    <p class="mg-note">Every night at 02:50: RetroAssembly's database (copied safely while it runs) and its saves, save
        states and screenshots - not the games themselves (they can be large, and you have them already) - in
        <code>Nas_Prog/_retroassembly/backups</code> (only the NAS's administrator can read them). To restore one, stop
        RetroAssembly and unpack it into <code>Nas_Prog/_retroassembly/data</code>.</p>

    <h3>Settings</h3>
    <p><label><input type="checkbox" data-ra="local"> Only through the Nginx app (HTTPS)</label>
        <label><input type="checkbox" data-ra="signups"> Anyone can sign up</label>
        <label>Keep <input type="number" data-ra="keep" min="1" max="99" value="14"> backups</label>
        <button type="button" data-ra-action="settings">Save</button></p>
    <p class="mg-note">Otherwise it's also reachable on port 8098 from the local network, over plain HTTP. With sign-ups
        on, anyone who can reach RetroAssembly can make an account (with a library of their own). RetroAssembly
        restarts.</p>

    <details class="mg-section">
        <summary>RetroAssembly's latest log lines</summary>
        <pre data-ra="log"></pre>
    </details>

    <p data-ra="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('retroassembly', 'ra'); ?>
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
                part('admin').textContent   = response.admin;

                // Its addresses: the Nginx app's (HTTPS), and port 8098 on the local network unless only through the
                // Nginx app
                let addresses = [];

                if (response.site.url) {
                    addresses.push(response.site.url);
                }

                if (response.listen === 'all') {
                    addresses.push(`http://${window.location.hostname}:8098/`);
                }

                let none  = 'none - turn off "Only through the Nginx app", or set the Nginx app up';
                let https = response.site.url ? '' : ` (HTTPS: ${siteStates[response.site.state]})`;

                part('address').textContent = `${addresses.join(' and ') || none}${https}`;
                part('address').className   = addresses.length ? '' : 'mg-bad';
                part('link').hidden         = !addresses.length;
                part('link').href           = addresses[0] || '#';
                part('backups').textContent = backupsText(response.backups);

                if (!loaded) {
                    part('local').checked   = response.listen === 'local';
                    part('signups').checked = response.signups;
                    part('keep').value      = response.backup_keep;

                    loaded = true;
                }

                part('log').textContent = response.log.length ? response.log.join('\n') : 'Nothing logged';
            });
        }

        // Keep the page current, until the dashboard removes it
        <?php manage_timer_script(); ?>
        <?php manage_act_script(); ?>

        button('restart').addEventListener('click', function () {
            act('restart', { confirm: 1 }, 'Restarting RetroAssembly…', 'RetroAssembly restarted.');
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
            if (!window.confirm('Set a new password for RetroAssembly\'s admin account (signing it out everywhere)?')) {
                return;
            }

            act('new_password', { confirm: 1 }, 'Setting a new password…', 'New password in use.').then(function (response) {
                if (response) {
                    password.set(response.password);
                }
            });
        });

        button('backup').addEventListener('click', function () {
            act('backup', { confirm: 1 }, 'Backing up…', 'Backed up.');
        });

        button('settings').addEventListener('click', function () {
            act('settings', {
                listen:      part('local').checked ? 'local' : 'all',
                signups:     part('signups').checked ? 'on' : 'off',
                backup_keep: part('keep').value
            }, 'Saving…', 'Saved - RetroAssembly restarted.');
        });

        refresh();
    })();
    </script>
</div>
