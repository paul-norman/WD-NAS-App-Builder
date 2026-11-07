<?php
// The template app's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('template');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="template-manage">
    <?php manage_styles('template-manage'); ?>

    <h2>Template</h2>
    <table>
        <tr><td>Status</td><td data-tp="status">…</td></tr>
        <tr><td>Version</td><td data-tp="version">-</td></tr>
        <tr><td>Address</td><td data-tp="address">-</td></tr>
    </table>
    <p><a class="mg-button" data-tp="link" href="#" target="_blank" rel="noopener">Open Template</a>
        <button type="button" data-tp-action="restart">Restart Template</button></p>

    <h3>Access</h3>
    <p><label><input type="checkbox" data-tp="local"> Only through the Nginx app (HTTPS)</label>
        <button type="button" data-tp-action="listen">Save</button></p>
    <p class="mg-note">Otherwise it's also reachable on port 8090 from the local network, over plain HTTP. It restarts.</p>

    <details class="mg-section">
        <summary>Its latest log lines</summary>
        <pre data-tp="log"></pre>
    </details>

    <p data-tp="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('template', 'tp'); ?>

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

                // Its addresses: the Nginx app's (HTTPS), and port 8090 on the local network unless only through the
                // Nginx app
                let addresses = [];

                if (response.site.url) {
                    addresses.push(response.site.url);
                }

                if (response.listen === 'all') {
                    addresses.push(`http://${window.location.hostname}:8090/`);
                }

                let none  = 'none - turn off "Only through the Nginx app", or set the Nginx app up';
                let https = response.site.url ? '' : ` (HTTPS: ${siteStates[response.site.state]})`;

                part('address').textContent = `${addresses.join(' and ') || none}${https}`;
                part('address').className   = addresses.length ? '' : 'mg-bad';
                part('link').hidden         = !addresses.length;
                part('link').href           = addresses[0] || '#';

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
            act('restart', { confirm: 1 }, 'Restarting Template…', 'Template restarted.');
        });

        button('listen').addEventListener('click', function () {
            let local = part('local').checked;

            act('listen', { listen: local ? 'local' : 'all' }, 'Saving…', local ?
                'Template is now only reachable through the Nginx app.' : 'Template is reachable on port 8090 too.');
        });

        refresh();
    })();
    </script>
</div>
