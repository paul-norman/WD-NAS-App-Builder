<?php
// Tautulli's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('tautulli');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="tautulli-manage">
    <?php manage_styles('tautulli-manage'); ?>

    <h2>Tautulli</h2>
    <table>
        <tr><td>Status</td><td data-tt="status">…</td></tr>
        <tr><td>Version</td><td data-tt="version">-</td></tr>
        <tr><td>Address</td><td data-tt="address">-</td></tr>
        <tr><td>Set up</td><td data-tt="setup">-</td></tr>
    </table>
    <p><a class="mg-button" data-tt="link" href="#" target="_blank" rel="noopener">Open Tautulli</a>
        <button type="button" data-tt-action="restart">Restart Tautulli</button></p>

    <h3>Logging in</h3>
    <p>Tautulli asks for the user name <code>admin</code> and this password: <code data-tt="password">••••••••••••</code>
        <button type="button" data-tt-action="show">Show</button> <button type="button" data-tt-action="copy">Copy</button></p>
    <p><input type="text" data-tt="new" placeholder="New password (leave empty to generate one)" autocomplete="off" spellcheck="false">
        <button type="button" data-tt-action="set">Change password</button></p>
    <p class="mg-note">Tautulli restarts with the new password. Passwords are 12-128 characters: letters, digits and . _ ~ -
        (A password changed in Tautulli's own settings isn't shown here.)</p>

    <h3>The first time</h3>
    <p>Tautulli's setup asks for the Plex server to follow: <span data-tt="plex">-</span> Signing in with your Plex account
        there gives it Plex's token. Tautulli's own updates are turned off: the Store updates it.</p>

    <h3>Access</h3>
    <p><label><input type="checkbox" data-tt="local"> Only through the Nginx app (HTTPS)</label>
        <button type="button" data-tt-action="listen">Save</button></p>
    <p class="mg-note">Otherwise Tautulli is also reachable on port 8181 from the local network, over plain HTTP (the
        password then crosses the network unencrypted). Tautulli restarts.</p>

    <details class="mg-section">
        <summary>Tautulli's latest warnings</summary>
        <pre data-tt="log"></pre>
    </details>

    <p data-tt="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('tautulli', 'tt'); ?>
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

                // Its addresses: the Nginx app's (HTTPS), and port 8181 on the local network unless only through the
                // Nginx app
                let addresses = [];

                if (response.site.url) {
                    addresses.push(response.site.url);
                }

                if (response.listen === 'all') {
                    addresses.push('http://' + window.location.hostname + ':8181/');
                }

                part('address').textContent = (addresses.join(' and ') || 'none - turn off "Only through the Nginx app", or set the Nginx app up') +
                    (response.site.url ? '' : ' (HTTPS: ' + siteStates[response.site.state] + ')');
                part('address').className   = addresses.length ? '' : 'mg-bad';
                part('link').hidden         = !addresses.length;
                part('link').href           = addresses[0] || '#';
                part('setup').textContent   = response.set_up ? 'Yes' : 'Not yet - open Tautulli to run its setup';
                part('setup').className     = response.set_up ? 'mg-ok' : '';
                part('plex').textContent    = response.plex ? 'Plex Media Server is installed on this NAS - its address is 127.0.0.1, port 32400.' :
                    'Plex Media Server isn\'t installed on this NAS (it can be installed from the Store) - give the address of the one to follow.';

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
            act('restart', { confirm: 1 }, 'Restarting Tautulli…', 'Tautulli restarted.');
        });

        button('listen').addEventListener('click', function () {
            let local = part('local').checked;

            act('listen', { listen: local ? 'local' : 'all' }, 'Saving…', local ? 'Tautulli is now only reachable through the Nginx app.' :
                'Tautulli is reachable on port 8181 too.');
        });

        // Its login's password: Show / Hide and Copy (fetched when first needed)
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
            act('set_password', { password: part('new').value.trim() }, 'Saving the password (Tautulli restarts)…', 'New password in use.').then(function (response) {
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
