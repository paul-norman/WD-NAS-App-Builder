<?php
// AdGuard Home's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('adguardhome');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="adguardhome-manage">
    <?php manage_styles('adguardhome-manage'); ?>

    <h2>AdGuard Home</h2>
    <table>
        <tr><td>Status</td><td data-ag="status">…</td></tr>
        <tr><td>Version</td><td data-ag="version">-</td></tr>
        <tr><td>DNS server</td><td data-ag="dns">-</td></tr>
        <tr><td>Web interface</td><td data-ag="address">-</td></tr>
    </table>
    <p class="mg-bad" data-ag="problem" hidden></p>
    <p><a class="mg-button" data-ag="link" href="#" target="_blank" rel="noopener">Open AdGuard Home</a>
        <button type="button" data-ag-action="restart">Restart AdGuard Home</button></p>
    <p class="mg-note">To block ads and trackers on every device, set the NAS's address above as the DNS server in your
        router's DHCP settings (devices pick it up when they next reconnect) - or on a single device to try it first.
        AdGuard Home runs as its own user, never as root: the NAS's firewall forwards DNS (port 53) to it.</p>

    <h3>Logging in</h3>
    <p>User name <code data-ag="admin">admin</code>, password <code data-ag="password">••••••••••••</code>
        <button type="button" data-ag-action="show">Show</button>
        <button type="button" data-ag-action="copy">Copy</button></p>
    <p><input type="password" data-ag="new" placeholder="New password (leave empty to generate one)" autocomplete="new-password">
        <button type="button" data-show-for="new">Show</button>
        <button type="button" data-ag-action="new-password">Change password</button></p>
    <p data-ag="password-message"></p>
    <p class="mg-note">The app made this account before AdGuard Home first started, so nobody else can claim it. Reset
        the password sets a new one this page shows (AdGuard Home restarts, and everyone signs in again).</p>

    <h3>Backups</h3>
    <p data-ag="backups">-</p>
    <p><button type="button" data-ag-action="backup">Back up now</button></p>
    <p class="mg-note">Every night at 02:50: AdGuard Home's settings - block lists, your own rules, clients, rewrites,
        upstream servers (not its statistics or query log) - in <code>Nas_Prog/_adguardhome/backups</code> (only the
        NAS's administrator can read them). To restore one, stop AdGuard Home and unpack it into
        <code>Nas_Prog/_adguardhome/work</code>.</p>

    <h3>Settings</h3>
    <p><label><input type="checkbox" data-ag="local"> Web interface only through the Nginx app (HTTPS)</label>
        <label>Keep <input type="number" data-ag="keep" min="1" max="99" value="14"> backups</label>
        <button type="button" data-ag-action="settings">Save</button></p>
    <p class="mg-note">Otherwise its web interface is also reachable on port 8094 from the local network, over plain
        HTTP. Its DNS server is always on the network. AdGuard Home restarts.</p>

    <details class="mg-section">
        <summary>AdGuard Home's latest log lines</summary>
        <pre data-ag="log"></pre>
    </details>

    <p data-ag="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('adguardhome', 'ag'); ?>
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
            let size   = `${Math.max(1, Math.round(latest.size / 1024))} KB`;

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
                part('problem').textContent = response.problem;
                part('problem').hidden      = !response.problem;

                // Its DNS server: the NAS's addresses, while the firewall forwards port 53 to it
                let dns = part('dns');

                dns.textContent = response.forwarding ? response.dns.join(', ') : 'not answering on the network';
                dns.className   = response.forwarding ? 'mg-ok' : 'mg-bad';

                // Its web interface: the Nginx app's address (HTTPS), and port 8094 on the local network unless only
                // through the Nginx app
                let addresses = [];

                if (response.site.url) {
                    addresses.push(response.site.url);
                }

                if (response.listen === 'all') {
                    addresses.push(`http://${window.location.hostname}:8094/`);
                }

                let none  = 'none - turn off "Only through the Nginx app", or set the Nginx app up';
                let https = response.site.url ? '' : ` (HTTPS: ${siteStates[response.site.state]})`;

                part('address').textContent = `${addresses.join(' and ') || none}${https}`;
                part('address').className   = addresses.length ? '' : 'mg-bad';
                part('link').hidden         = !addresses.length;
                part('link').href           = addresses[0] || '#';
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
            act('restart', { confirm: 1 }, 'Restarting AdGuard Home…', 'AdGuard Home restarted.');
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
            if (!window.confirm('Set a new password for AdGuard Home\'s admin account (it restarts)?')) {
                return;
            }

            act('new_password', { confirm: 1, password: part('new').value.trim() }, 'Setting a new password…', 'New password in use.', 'password-message').then(function (response) {
                if (response) {
                    part('new').value = '';

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
                backup_keep: part('keep').value
            }, 'Saving…', 'Saved - AdGuard Home restarted.');
        });

        refresh();
    })();
    </script>
</div>
