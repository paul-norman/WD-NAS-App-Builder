<?php
// Go's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('golang');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="golang-manage">
    <?php manage_styles('golang-manage'); ?>

    <h2>Go</h2>
    <table>
        <tr><td>Go</td><td data-go="version">…</td></tr>
        <tr><td>Telemetry</td><td><span data-go="telemetry">…</span> <button type="button" data-go-action="telemetry" hidden>Turn off</button></td></tr>
    </table>
    <p class="mg-note"><code>go</code> and <code>gofmt</code> can be used over SSH. Go's telemetry is turned off when the app is
        installed; it only comes back on if it's turned on again (e.g. <code>go telemetry on</code>).</p>

    <h3>Test server</h3>
    <p>A small example server on port <code>30289</code>, showing that Go works on the NAS: <span data-go="server">…</span></p>
    <p><a class="mg-button" data-go="link" href="#" target="_blank" rel="noopener">Open the test server</a>
        <button type="button" data-go-action="restart">Restart it</button></p>

    <p data-go="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('golang', 'go'); ?>

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

                part('version').textContent   = response.version || 'not found';
                part('telemetry').textContent = response.telemetry || 'unknown';
                part('telemetry').className   = response.telemetry === 'off' ? 'mg-ok' : 'mg-bad';
                button('telemetry').hidden    = response.telemetry === 'off';

                let server = part('server');

                server.textContent = response.test_server;
                server.className   = response.test_server === 'running' ? 'mg-ok' : 'mg-bad';
            });
        }

        part('link').href = 'http://' + window.location.hostname + ':30289/';

        button('restart').addEventListener('click', function () {
            say('Restarting the test server…', true);
            call('restart', { confirm: 1 }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return;
                }

                say('The test server restarted.', true);
                setTimeout(refresh, 1000);
            });
        });

        button('telemetry').addEventListener('click', function () {
            call('telemetry_off', { confirm: 1 }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return;
                }

                say('Telemetry is off.', true);
                refresh();
            });
        });

        refresh();
    })();
    </script>
</div>
