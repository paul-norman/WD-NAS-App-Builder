<?php
// Prometheus' management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('prometheus');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="prometheus-manage">
    <?php manage_styles('prometheus-manage'); ?>

    <h2>Prometheus</h2>
    <table>
        <tr><td>Status</td><td data-pm="status">…</td></tr>
        <tr><td>Version</td><td data-pm="version">-</td></tr>
        <tr><td>Address</td><td data-pm="address">-</td></tr>
        <tr><td>Stored</td><td data-pm="storage">-</td></tr>
        <tr><td>Configuration</td><td data-pm="config">-</td></tr>
    </table>
    <p><a class="mg-button" data-pm="link" href="#" target="_blank" rel="noopener" hidden>Open Prometheus</a>
        <button type="button" data-pm-action="reload">Reload the configuration</button>
        <button type="button" data-pm-action="restart">Restart Prometheus</button></p>

    <h3>Targets</h3>
    <table data-pm="targets"></table>
    <p class="mg-note">Prometheus scrapes itself and the Node Exporter app (following its port and password) every 30
        seconds. Your own scrape jobs go in <code data-pm="scrape-path">scrape.d</code> (*.yml, see its README.txt) and rules
        in <code data-pm="rules-path">rules.d</code> - then reload. <span data-pm="own"></span></p>

    <h3>Settings</h3>
    <p><label>Keep <input type="number" data-pm="retention" min="1" max="3650" style="width: 6em"> days of history</label>
        <label><input type="checkbox" data-pm="all"> Reachable on port 9090 from the local network</label>
        <button type="button" data-pm-action="settings">Save</button></p>
    <p class="mg-note">Prometheus restarts. It has no login of its own, so it's only reachable on the NAS itself unless this
        is ticked (Grafana reaches it there). Older history is deleted as it expires.</p>

    <details class="mg-section">
        <summary>Prometheus' latest warnings</summary>
        <pre data-pm="log"></pre>
    </details>

    <p data-pm="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('prometheus', 'pm'); ?>

        let loaded = false;

        /**
         * A size, for showing (e.g. 5.2 MB).
         *
         * @param {number} bytes The size, in bytes
         *
         * @return {string} The size, with its unit
         */
        function formatSize(bytes) {
            return bytes >= 1073741824 ? (bytes / 1073741824).toFixed(1) + ' GB' : (bytes / 1048576).toFixed(1) + ' MB';
        }

        /**
         * Shows Prometheus' targets and their state. Names and errors come from Prometheus, so they're only ever set as
         * text.
         *
         * @param {Array.<Object>} targets   The targets: job, instance, url, health and error
         * @param {boolean}        answering Whether Prometheus answers
         *
         * @return {void}
         */
        function fillTargets(targets, answering) {
            let table = part('targets');

            table.textContent = '';

            if (!targets.length) {
                table.insertRow().insertCell().textContent = answering ? 'No targets' : '-';

                return;
            }

            let head = table.insertRow();

            ['Job', 'Instance', 'Address', 'State'].forEach(function (text) {
                let cell = head.insertCell();

                cell.textContent      = text;
                cell.style.fontWeight = 'bold';
            });

            targets.forEach(function (target) {
                let row = table.insertRow();

                row.insertCell().textContent = target.job;
                row.insertCell().textContent = target.instance;
                row.insertCell().textContent = target.url;

                let state = row.insertCell();

                state.textContent = target.health === 'up' ? 'up' : (target.health || 'unknown') + (target.error ? ': ' + target.error : '');
                state.className   = target.health === 'up' ? 'mg-ok' : (target.health === 'unknown' ? 'mg-note' : 'mg-bad');
            });
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
                let url    = 'http://' + window.location.hostname + ':9090/';

                status.textContent = !response.running ? 'Stopped' : (response.answering ? 'Running' : 'Starting… (replaying its recent data)');
                status.className = response.running && response.answering ? 'mg-ok' : 'mg-bad';

                part('version').textContent = response.version || '-';
                part('address').textContent = response.listen === 'all' ? url : '127.0.0.1:9090 (on the NAS itself only)';
                part('link').hidden         = response.listen !== 'all';
                part('link').href           = url;
                part('storage').textContent = formatSize(response.storage) + ', keeping ' + response.retention_days + ' days';

                let config = part('config');

                config.textContent = response.config_ok === null ? '-' : (response.config_ok ? 'loaded' : 'the last reload failed - Prometheus is using the previous configuration (see the warnings below)');
                config.className   = response.config_ok === false ? 'mg-bad' : '';

                part('scrape-path').textContent = response.data_path + '/scrape.d';
                part('rules-path').textContent  = response.data_path + '/rules.d';
                part('own').textContent         = response.own_files.length ? 'Your files: ' + response.own_files.join(', ') + '.' : '';

                // The settings are only filled in once, so a refresh doesn't undo changes being made
                if (!loaded) {
                    part('retention').value = response.retention_days;
                    part('all').checked     = response.listen === 'all';

                    loaded = true;
                }

                fillTargets(response.targets, response.answering);

                part('log').textContent = response.log.length ? response.log.join('\n') : 'Nothing logged';
            });
        }

        // Keep the page current, until the dashboard removes it
        <?php manage_timer_script(); ?>

        /**
         * Runs one of the API's actions, saying it's being done, then how it went - and shows the status again.
         *
         * @param {string} action  The API's action
         * @param {Object} data    What to post (a GET when there's none)
         * @param {string} working What to say meanwhile
         * @param {string} done    What to say once it's done
         *
         * @return {Promise} Done once it has answered
         */
        function act(action, data, working, done) {
            say(working, true);

            return call(action, data).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    refresh();

                    return;
                }

                say(done, true);
                setTimeout(refresh, 1000);
            });
        }

        button('reload').addEventListener('click', function () {
            act('reload', { confirm: 1 }, 'Reloading…', 'Configuration reloaded.');
        });

        button('restart').addEventListener('click', function () {
            act('restart', { confirm: 1 }, 'Restarting Prometheus…', 'Prometheus restarted.');
        });

        button('settings').addEventListener('click', function () {
            act('settings', { retention_days: part('retention').value, listen: part('all').checked ? 'all' : 'local' },
                'Saving…', 'Saved - Prometheus restarted.');
        });

        refresh();
    })();
    </script>
</div>
