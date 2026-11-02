<?php
// The logs app's (Loki + Vector) management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only,
// see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('loki');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="loki-manage">
    <?php manage_styles('loki-manage'); ?>

    <h2>Loki</h2>
    <table>
        <tr><td>Loki</td><td data-lk="loki">…</td></tr>
        <tr><td>Vector</td><td data-lk="vector">…</td></tr>
        <tr><td>Stored</td><td data-lk="storage">-</td></tr>
        <tr><td>Viewing</td><td data-lk="viewing">-</td></tr>
    </table>
    <p><button type="button" data-lk-action="restart">Restart Loki and Vector</button></p>

    <h3>Collected in the last 24 hours</h3>
    <table data-lk="logs"></table>

    <h3>Settings</h3>
    <p><label>Keep <input type="number" data-lk="retention" min="1" max="3650" style="width: 6em"> days of logs</label></p>
    <p><label><input type="checkbox" data-lk="system"> The NAS's own logs (/var/log: system, kernel, SSH, Samba, WD's services)</label><br>
        <label><input type="checkbox" data-lk="apps"> The apps' logs (Nas_Prog/_&lt;app&gt;/*.log, the Nginx app's, the app scripts')</label><br>
        <label><input type="checkbox" data-lk="docker"> Docker containers' output <span class="mg-note" data-lk="docker-note"></span></label></p>
    <p><button type="button" data-lk-action="settings">Save</button>
        <span class="mg-note">Loki and Vector restart. Older logs are deleted as they expire.</span></p>

    <details class="mg-section">
        <summary>Loki's and Vector's latest warnings</summary>
        <pre data-lk="log"></pre>
    </details>

    <p data-lk="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('loki', 'lk'); ?>

        let sources = { system: 'NAS', app: 'App', docker: 'Docker' };
        let loaded  = false;

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
         * Shows the logs collected, by source. Names come from Loki, so they're only ever set as text.
         *
         * @param {Array.<Object>} logs  The logs: source, app and lines
         * @param {boolean}        ready Whether Loki is ready
         *
         * @return {void}
         */
        function fillLogs(logs, ready) {
            let table = part('logs');

            table.textContent = '';

            if (!logs.length) {
                table.insertRow().insertCell().textContent = ready ? 'Nothing yet (the first lines arrive within a minute)' : '-';

                return;
            }

            let head = table.insertRow();

            ['Source', 'Log', 'Lines'].forEach(function (text) {
                let cell = head.insertCell();

                cell.textContent      = text;
                cell.style.fontWeight = 'bold';
            });

            logs.forEach(function (log) {
                let row = table.insertRow();

                row.insertCell().textContent = sources[log.source] || log.source;
                row.insertCell().textContent = log.app;
                row.insertCell().textContent = log.lines.toLocaleString();
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

                let loki = part('loki');

                loki.textContent = (!response.loki_running ? 'Stopped' : (response.loki_ready ? 'Running' : 'Starting… ' + (response.loki_state || ''))) +
                    (response.loki_version ? ' - ' + response.loki_version + ', on the NAS itself only (127.0.0.1:3100)' : '');
                loki.className   = response.loki_running && response.loki_ready ? 'mg-ok' : 'mg-bad';

                let vector = part('vector');

                vector.textContent = (response.vector_running ? 'Running' : 'Stopped') + (response.vector_version ? ' - ' + response.vector_version + ', reading the logs and sending them to Loki' : '');
                vector.className   = response.vector_running ? 'mg-ok' : 'mg-bad';

                part('storage').textContent     = formatSize(response.storage) + ', keeping ' + response.retention_days + ' days';
                part('viewing').textContent     = response.grafana ? 'In Grafana: Dashboards → NAS → NAS logs, or Explore with the Loki data source' :
                    'Install the Grafana app to search and view the logs';
                part('docker-note').textContent = response.docker_running ? '' : '(Docker isn\'t running - restart this app after starting it)';

                // The settings are only filled in once, so a refresh doesn't undo changes being made
                if (!loaded) {
                    part('retention').value = response.retention_days;
                    part('system').checked  = response.system_logs;
                    part('apps').checked    = response.app_logs;
                    part('docker').checked  = response.docker_logs;

                    loaded = true;
                }

                fillLogs(response.logs, response.loki_ready);

                let log = [].concat(response.loki_log.map(function (line) {
                    return 'loki: ' + line;
                }), response.vector_log.map(function (line) {
                    return 'vector: ' + line;
                }));

                part('log').textContent = log.length ? log.join('\n') : 'Nothing logged';
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

                    return;
                }

                say(done, true);
                setTimeout(refresh, 2000);
            });
        }

        button('restart').addEventListener('click', function () {
            act('restart', { confirm: 1 }, 'Restarting…', 'Loki and Vector restarted.');
        });

        button('settings').addEventListener('click', function () {
            act('settings', { retention_days: part('retention').value, system_logs: part('system').checked ? 1 : 0,
                app_logs: part('apps').checked ? 1 : 0, docker_logs: part('docker').checked ? 1 : 0 }, 'Saving…', 'Saved - Loki and Vector restarted.');
        });

        refresh();
    })();
    </script>
</div>
