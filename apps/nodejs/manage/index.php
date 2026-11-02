<?php
// Node.js's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('nodejs');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="nodejs-manage">
    <?php manage_styles('nodejs-manage'); ?>

    <h2>Node.js</h2>
    <table>
        <tr><td>Node.js</td><td data-nj="node">…</td></tr>
        <tr><td>npm</td><td data-nj="npm">…</td></tr>
        <tr><td>Corepack</td><td data-nj="corepack">…</td></tr>
        <tr><td>pnpm</td><td data-nj="pnpm">…</td></tr>
    </table>
    <p class="mg-note"><code>node</code>, <code>npm</code>, <code>npx</code>, <code>pnpm</code>, <code>pnpx</code> and <code>corepack</code> can be used over SSH.</p>

    <h3>Test server</h3>
    <p>A small example server on port <code>30290</code>, showing that Node.js works on the NAS: <span data-nj="server">…</span></p>
    <p><a class="mg-button" data-nj="link" href="#" target="_blank" rel="noopener">Open the test server</a>
        <button type="button" data-nj-action="restart">Restart it</button></p>

    <p data-nj="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('nodejs', 'nj'); ?>

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

                ['node', 'npm', 'corepack', 'pnpm'].forEach(function (tool) {
                    part(tool).textContent = response.versions[tool] || 'not found';
                });

                let server = part('server');

                server.textContent = response.test_server;
                server.className   = response.test_server === 'running' ? 'mg-ok' : 'mg-bad';
            });
        }

        part('link').href = 'http://' + window.location.hostname + ':30290/';

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

        refresh();
    })();
    </script>
</div>
