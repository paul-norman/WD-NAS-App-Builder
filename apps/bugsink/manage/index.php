<?php
// Bugsink's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('bugsink');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="bugsink-manage">
    <?php manage_styles('bugsink-manage'); ?>

    <h2>Bugsink</h2>
    <table>
        <tr><td>Status</td><td data-bs="status">…</td></tr>
        <tr><td>Version</td><td data-bs="version">-</td></tr>
        <tr><td>Address</td><td data-bs="address">-</td></tr>
        <tr><td>Its worker</td><td data-bs="worker">-</td></tr>
    </table>
    <p><a class="mg-button" data-bs="link" href="#" target="_blank" rel="noopener">Open Bugsink</a>
        <button type="button" data-bs-action="restart">Restart Bugsink</button></p>

    <h3>Logging in</h3>
    <p>Its admin user is <code>admin</code>, with this password: <code data-bs="password">••••••••••••</code>
        <button type="button" data-bs-action="show">Show</button> <button type="button" data-bs-action="copy">Copy</button></p>
    <p><input type="text" data-bs="new" placeholder="New password (leave empty to generate one)" autocomplete="off" spellcheck="false">
        <button type="button" data-bs-action="set">Change password</button></p>
    <p class="mg-note">The new password is in use at once. Passwords are 12-128 characters: letters, digits and . _ ~ -
        (A password changed in Bugsink itself isn't shown here.) Other people get an invitation link from the admin
        (Users, in Bugsink): the NAS sends no email.</p>

    <h3>Reporting errors to it</h3>
    <p>Make a team and a project in Bugsink: the project shows its DSN, which your programs' Sentry SDK is given (Bugsink
        speaks Sentry's protocol). Its DSNs use the address <code data-bs="base">-</code> - so programs elsewhere must be
        able to reach it there.</p>

    <h3>Access</h3>
    <p><label><input type="checkbox" data-bs="local"> Only through the Nginx app (HTTPS)</label>
        <button type="button" data-bs-action="listen">Save</button></p>
    <p class="mg-note">Otherwise Bugsink is also reachable on port 8000 from the local network, over plain HTTP (the
        password then crosses the network unencrypted). Bugsink restarts.</p>

    <details class="mg-section">
        <summary>Bugsink's latest warnings</summary>
        <pre data-bs="log"></pre>
    </details>

    <p data-bs="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('bugsink', 'bs'); ?>
        <?php manage_secret_script(); ?>

        let loaded     = false;
        let siteStates = {
            no_nginx:  'the Nginx app isn\'t set up',
            no_domain: 'set a domain in the Nginx app',
            off:       'switched off in the Nginx app'
        };

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

                // Its addresses: the Nginx app's (HTTPS), and port 8000 on the local network unless only through the
                // Nginx app
                let addresses = [];

                if (response.site.url) {
                    addresses.push(response.site.url);
                }

                if (response.listen === 'all') {
                    addresses.push('http://' + window.location.hostname + ':8000/');
                }

                part('address').textContent = (addresses.join(' and ') || 'none - turn off "Only through the Nginx app", or set the Nginx app up') +
                    (response.site.url ? '' : ' (HTTPS: ' + siteStates[response.site.state] + ')');
                part('address').className   = addresses.length ? '' : 'mg-bad';
                part('link').hidden         = !addresses.length;
                part('link').href           = addresses[0] || '#';
                part('worker').textContent  = response.worker ? 'Running' : 'Stopped - events aren\'t turned into issues: restart Bugsink';
                part('worker').className    = response.worker ? 'mg-ok' : 'mg-bad';
                part('base').textContent    = response.base_url || '-';

                if (!loaded) {
                    part('local').checked = response.listen === 'local';

                    loaded = true;
                }

                part('log').textContent = response.log.length ? response.log.join('\n') : 'Nothing logged';
            });
        }

        // Keep the page current, until the dashboard removes it
        <?php manage_timer_script(); ?>
        <?php manage_act_script(); ?>

        button('restart').addEventListener('click', function () {
            act('restart', { confirm: 1 }, 'Restarting Bugsink…', 'Bugsink restarted.');
        });

        button('listen').addEventListener('click', function () {
            let local = part('local').checked;

            act('listen', { listen: local ? 'local' : 'all' }, 'Saving…', local ? 'Bugsink is now only reachable through the Nginx app.' :
                'Bugsink is reachable on port 8000 too.');
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
