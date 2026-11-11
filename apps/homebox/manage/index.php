<?php
// Homebox's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('homebox');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="homebox-manage">
    <?php manage_styles('homebox-manage'); ?>

    <h2>Homebox</h2>
    <table>
        <tr><td>Status</td><td data-hb="status">…</td></tr>
        <tr><td>Version</td><td data-hb="version">-</td></tr>
        <tr><td>Address</td><td data-hb="address">-</td></tr>
    </table>
    <p class="mg-note" data-hb="restart-note" hidden>The Nginx app's address for Homebox has changed: restart Homebox so
        that its links (e.g. on printed labels) use it.</p>
    <p><a class="mg-button" data-hb="link" href="#" target="_blank" rel="noopener">Open Homebox</a>
        <button type="button" data-hb-action="restart">Restart Homebox</button></p>

    <h3>Logging in</h3>
    <p>Email <code data-hb="admin">admin@homebox.local</code>, password <code data-hb="password">••••••••••••</code>
        <button type="button" data-hb-action="show">Show</button> <button type="button" data-hb-action="copy">Copy</button>
        <button type="button" data-hb-action="new-password">Reset the password</button></p>
    <p class="mg-note">The app made this account, so nobody else can claim Homebox. You can change its email and password
        in Homebox (Profile): this page then no longer knows the password - Reset the password sets a new one it shows
        (while the email is still this one). Add the rest of the household with Homebox's invitation links (Collection
        Options), which work while sign-ups are off.</p>

    <h3>A forgotten password</h3>
    <p><input type="email" data-hb="email" placeholder="Their email address" size="28">
        <button type="button" data-hb-action="reset-link">Make a reset link</button></p>
    <p data-hb="link-box" hidden><a data-hb="reset-link" href="#" target="_blank" rel="noopener"></a>
        <button type="button" data-hb-action="copy-link">Copy</button></p>
    <p class="mg-note">For any account: a link to set a new password, from Homebox itself - it works once, within an
        hour. Give it to them (Homebox can't email it without a mail server).</p>

    <h3>Backups</h3>
    <p data-hb="backups">-</p>
    <p><button type="button" data-hb-action="backup">Back up now</button></p>
    <p class="mg-note">Every night at 02:50: Homebox's database (copied safely while it runs) and its attachments
        (photos, receipts, manuals), in <code>Nas_Prog/_homebox/backups</code> (only the NAS's administrator can read
        them). To restore one, stop Homebox and unpack it into <code>Nas_Prog/_homebox/data</code>.</p>

    <h3>Settings</h3>
    <p><label><input type="checkbox" data-hb="local"> Only through the Nginx app (HTTPS)</label>
        <label><input type="checkbox" data-hb="signups"> Anyone can sign up</label>
        <label>Keep <input type="number" data-hb="keep" min="1" max="99" value="14"> backups</label>
        <button type="button" data-hb-action="settings">Save</button></p>
    <p class="mg-note">Otherwise it's also reachable on port 7745 from the local network, over plain HTTP. With sign-ups
        on, anyone who can reach Homebox can make an account (in a collection of their own). Homebox restarts.</p>

    <details class="mg-section">
        <summary>Homebox's latest log lines</summary>
        <pre data-hb="log"></pre>
    </details>

    <p data-hb="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('homebox', 'hb'); ?>
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

                // Its addresses: the Nginx app's (HTTPS), and port 7745 on the local network unless only through the
                // Nginx app
                let addresses = [];

                if (response.site.url) {
                    addresses.push(response.site.url);
                }

                if (response.listen === 'all') {
                    addresses.push(`http://${window.location.hostname}:7745/`);
                }

                let none  = 'none - turn off "Only through the Nginx app", or set the Nginx app up';
                let https = response.site.url ? '' : ` (HTTPS: ${siteStates[response.site.state]})`;

                part('address').textContent = `${addresses.join(' and ') || none}${https}`;
                part('address').className   = addresses.length ? '' : 'mg-bad';
                part('link').hidden         = !addresses.length;
                part('link').href           = addresses[0] || '#';
                part('restart-note').hidden = !response.restart_needed;
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
            act('restart', { confirm: 1 }, 'Restarting Homebox…', 'Homebox restarted.');
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
            if (!window.confirm('Set a new password for Homebox\'s admin account?')) {
                return;
            }

            act('new_password', { confirm: 1 }, 'Setting a new password…', 'New password in use.').then(function (response) {
                if (response) {
                    password.set(response.password);
                }
            });
        });

        button('reset-link').addEventListener('click', function () {
            part('link-box').hidden = true;

            act('reset_link', { email: part('email').value }, 'Asking Homebox…', 'Reset link made (it works once, within an hour).').then(function (response) {
                if (response) {
                    part('reset-link').href        = response.link;
                    part('reset-link').textContent = response.link;
                    part('link-box').hidden        = false;
                }
            });
        });

        button('copy-link').addEventListener('click', function () {
            copyText(part('reset-link').href).then(function (ok) {
                say(ok ? 'Copied.' : 'Couldn\'t copy: select the link and copy it.', ok);
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
            }, 'Saving…', 'Saved - Homebox restarted.');
        });

        refresh();
    })();
    </script>
</div>
