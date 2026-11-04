<?php
// Headlamp's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('headlamp');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="headlamp-manage">
    <?php manage_styles('headlamp-manage'); ?>

    <h2>Headlamp</h2>
    <table>
        <tr><td>Status</td><td data-hl="status">…</td></tr>
        <tr><td>Cluster</td><td data-hl="cluster">-</td></tr>
        <tr><td>Address</td><td data-hl="address">-</td></tr>
    </table>
    <p class="mg-note mg-bad" data-hl="cluster-note" hidden></p>
    <p><a class="mg-button" data-hl="link" href="#" target="_blank" rel="noopener">Open Headlamp</a>
        <button type="button" data-hl-action="restart">Restart Headlamp</button></p>

    <h3>Logging in</h3>
    <p>Headlamp asks for a token: <code data-hl="token">••••••••••••</code>
        <button type="button" data-hl-action="show">Show</button> <button type="button" data-hl-action="copy">Copy</button>
        <button type="button" data-hl-action="new-token">New token</button></p>
    <p class="mg-note">It's the token of the cluster's <code>headlamp-admin</code> account (cluster-admin): full
        control of the cluster, and through it of the NAS. Keep it private; a new token stops the old one working within
        seconds.</p>

    <h3>Settings</h3>
    <p><label><input type="checkbox" data-hl="local"> Only through the Nginx app (HTTPS)</label>
        <button type="button" data-hl-action="settings">Save</button></p>
    <p class="mg-note">Otherwise Headlamp is also on the local network at port 4466, over plain HTTP. Headlamp restarts.</p>

    <details class="mg-section">
        <summary>Headlamp's latest warnings</summary>
        <pre data-hl="log"></pre>
    </details>

    <p data-hl="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('headlamp', 'hl'); ?>
        <?php manage_secret_script(); ?>

        let loaded = false;

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

                const status  = part('status');
                const cluster = part('cluster');
                const note    = part('cluster-note');
                const url     = response.site.url || (response.listen === 'local' ? '' : response.address);

                status.textContent = !response.running ? 'Stopped' : (response.answering ? 'Running' : 'Starting…');
                status.className   = response.running && response.answering ? 'mg-ok' : 'mg-bad';

                cluster.textContent = response.cluster ? (response.k3s ? "The k3s app's (running)" : "The k3s app's (stopped)") : 'None';
                cluster.className   = response.cluster && response.k3s ? 'mg-ok' : 'mg-bad';

                note.hidden = response.cluster && response.k3s;

                if (!response.k3s_found) {
                    note.textContent = "The k3s app's cluster wasn't found: install and start the k3s app, then restart Headlamp.";
                } else if (!response.cluster) {
                    note.textContent = 'The k3s app has started since Headlamp did: restart Headlamp.';
                } else {
                    note.textContent = 'The k3s app is stopped: Headlamp shows its cluster once it runs.';
                }

                part('address').textContent = [response.site.url, response.listen === 'local' ? '' : response.address].filter(Boolean).join(' and ') || '-';
                part('link').href           = url || '#';

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
            act('restart', { confirm: 1 }, 'Restarting Headlamp…', 'Headlamp restarted.');
        });

        // The token: Show / Hide and Copy (fetched when first needed)
        const token = secretControls(part('token'), button('show'), button('copy'), function () {
            return call('token', { show: 1 }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return null;
                }

                return response.token;
            });
        });

        button('new-token').addEventListener('click', function () {
            if (!window.confirm('Make a new token? Anyone logged in with the current one is logged out.')) {
                return;
            }

            act('new_token', { confirm: 1 }, 'Making a new token…', 'New token in use.').then(function (response) {
                if (response) {
                    token.set(response.token);
                }
            });
        });

        button('settings').addEventListener('click', function () {
            act('settings', { listen: part('local').checked ? 'local' : 'all' }, 'Saving…', 'Saved - Headlamp restarted.');
        });

        refresh();
    })();
    </script>
</div>
