<?php
// Compass Web's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('compass-web');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="compass-web-manage">
    <?php manage_styles('compass-web-manage'); ?>

    <h2>Compass Web</h2>
    <table>
        <tr><td>Status</td><td data-cw="status">…</td></tr>
        <tr><td>Version</td><td data-cw="version">-</td></tr>
        <tr><td>Address</td><td data-cw="address">-</td></tr>
        <tr><td>MongoDB</td><td data-cw="mongodb">-</td></tr>
    </table>
    <p><a class="mg-button" data-cw="link" href="#" target="_blank" rel="noopener">Open Compass Web</a>
        <button type="button" data-cw-action="restart">Restart Compass Web</button></p>

    <h3>Logging in</h3>
    <p>It asks for the user <code>admin</code>, with this password: <code data-cw="password">••••••••••••</code>
        <button type="button" data-cw-action="show">Show</button> <button type="button" data-cw-action="copy">Copy</button></p>
    <p><input type="text" data-cw="new" placeholder="New password (leave empty to generate one)" autocomplete="off" spellcheck="false">
        <button type="button" data-cw-action="set">Change password</button></p>
    <p class="mg-note">Compass Web restarts with the new password. Passwords are 12-128 characters: letters, digits and
        . _ ~ - Once in, it works on MongoDB as the MongoDB app's administrator (all rights on every database).</p>

    <h3>Access</h3>
    <p><label><input type="checkbox" data-cw="local"> Only through the Nginx app (HTTPS)</label>
        <button type="button" data-cw-action="listen">Save</button></p>
    <p class="mg-note">Otherwise Compass Web is also reachable on port 8087 from the local network, over plain HTTP
        (the password then crosses the network unencrypted). Compass Web restarts.</p>

    <details class="mg-section">
        <summary>Compass Web's latest warnings</summary>
        <pre data-cw="log"></pre>
    </details>

    <p data-cw="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('compass-web', 'cw'); ?>
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

                // Its addresses: the Nginx app's (HTTPS), and port 8087 on the local network unless only through the
                // Nginx app
                let addresses = [];

                if (response.site.url) {
                    addresses.push(response.site.url);
                }

                if (response.listen === 'all') {
                    addresses.push('http://' + window.location.hostname + ':8087/');
                }

                part('address').textContent = (addresses.join(' and ') || 'none - turn off "Only through the Nginx app", or set the Nginx app up') +
                    (response.site.url ? '' : ' (HTTPS: ' + siteStates[response.site.state] + ')');
                part('address').className   = addresses.length ? '' : 'mg-bad';
                part('link').hidden         = !addresses.length;
                part('link').href           = addresses[0] || '#';
                part('mongodb').textContent = response.mongodb ? 'The MongoDB app, as its administrator' : 'The MongoDB app isn\'t set up: install and start it first';
                part('mongodb').className   = response.mongodb ? 'mg-ok' : 'mg-bad';

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
            act('restart', { confirm: 1 }, 'Restarting Compass Web…', 'Compass Web restarted.');
        });

        button('listen').addEventListener('click', function () {
            let local = part('local').checked;

            act('listen', { listen: local ? 'local' : 'all' }, 'Saving…', local ? 'Compass Web is now only reachable through the Nginx app.' :
                'Compass Web is reachable on port 8087 too.');
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
            act('set_password', { password: part('new').value.trim() }, 'Saving the password…', 'New password in use (Compass Web restarted).').then(function (response) {
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
