<?php
// The MariaDB Exporter app's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('mysqld_exporter');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="mysqld_exporter-manage">
    <?php manage_styles('mysqld_exporter-manage'); ?>

    <h2>MariaDB Exporter</h2>
    <p>Gives Prometheus the NAS's MariaDB metrics (WD's own MariaDB, or the MariaDB app's: queries, connections, InnoDB), with a Grafana dashboard. It answers on the NAS itself only.</p>
    <table>
        <tr><td>Status</td><td data-mye="status">…</td></tr>
        <tr><td>Version</td><td data-mye="version">-</td></tr>
        <tr><td>MariaDB</td><td data-mye="connected">-</td></tr>
        <tr><td>Its login</td><td data-mye="login">-</td></tr>
        <tr><td>Prometheus</td><td data-mye="prometheus">-</td></tr>
        <tr><td>Grafana</td><td data-mye="grafana">-</td></tr>
    </table>
    <p><button type="button" data-mye-action="login">Set up its login again</button>
        <button type="button" data-mye-action="restart">Restart</button></p>
    <p data-mye="message"></p>

    <details data-mye="log-box" hidden>
        <summary>Its latest messages</summary>
        <pre data-mye="log"></pre>
    </details>

    <h3>How it works</h3>
    <ul>
        <li>It logs in to MariaDB as <code>mysqld_exporter@localhost</code>, a login the app creates with a password only it keeps. It can read MariaDB's status (<code>PROCESS</code>, <code>REPLICATION CLIENT</code> and <code>performance_schema</code>), not your data.</li>
        <li>Prometheus collects its metrics every 30 seconds, by itself, once the Prometheus app is installed. Its dashboard appears in Grafana's <em>NAS</em> folder.</li>
        <li>It listens on the NAS itself only (<code>127.0.0.1:9104</code>), and runs as its own user.</li>
    </ul>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('mysqld_exporter', 'mye'); ?>

        /**
         * Shows a value in one of the table's cells, as good news or a problem.
         *
         * @param {string}       name The cell
         * @param {string|Node}  text What it says
         * @param {boolean|null} good Whether it's good news (null: neither)
         *
         * @return {void}
         */
        function show(name, text, good) {
            let cell = part(name);

            cell.textContent = '';
            cell.append(text);
            cell.className = good === null ? '' : (good ? 'mg-ok' : 'mg-bad');
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

                show('status', !response.running ? 'Stopped' : (response.answering ? 'Running' : 'Starting…'), response.running && response.answering);
                show('version', response.version || '-', null);

                if (!response.database) {
                    show('connected', '-', false);
                } else if (!response.answering) {
                    show('connected', '-', null);
                } else {
                    show('connected', response.connected ? 'Connected' : 'Not reached - is MariaDB running (the MariaDB app, or WD\'s own)? Setting up its login again helps after a fresh start', response.connected);
                }

                let login = response.login;

                if (login.state === 'ok') {
                    show('login', 'mysqld_exporter@localhost, set up (' + login.time.replace('T', ' ').slice(0, 16) + ' UTC)', true);
                } else if (login.state === 'failed') {
                    show('login', 'Failed (' + login.time.replace('T', ' ').slice(0, 16) + ' UTC): ' + login.message, false);
                } else {
                    show('login', 'Not yet - it\'s set up once MariaDB answers', null);
                }

                let prometheus = response.prometheus;

                if (!prometheus.installed) {
                    show('prometheus', 'Not installed - install the Prometheus app to collect its metrics', null);
                } else if (prometheus.health === 'up') {
                    show('prometheus', 'Collecting its metrics', true);
                } else if (prometheus.health === 'down') {
                    show('prometheus', 'Can\'t collect them: ' + prometheus.error, false);
                } else {
                    show('prometheus', 'Not collecting them yet (is Prometheus running?)', null);
                }

                let grafana = response.grafana;

                if (!grafana.installed) {
                    show('grafana', 'Not installed - the Grafana app shows its dashboard', null);
                } else {
                    let url = grafana.url || (grafana.port ? 'http://' + window.location.hostname + ':' + grafana.port + grafana.path : '');

                    if (url) {
                        let link = document.createElement('a');

                        link.href        = url;
                        link.target      = '_blank';
                        link.rel         = 'noopener';
                        link.textContent = 'Its dashboard: MariaDB / MySQL (in the NAS folder)';

                        show('grafana', link, null);
                    } else {
                        show('grafana', 'Its dashboard is in Grafana\'s NAS folder: MariaDB / MySQL', null);
                    }
                }

                part('log-box').hidden = !response.log.length;
                part('log').textContent = response.log.join('\n');
            });
        }

        button('login').addEventListener('click', function () {
            button('login').disabled = true;
            say('Setting up its login in MariaDB (a new password)…', true);
            call('login', { confirm: 1 }).then(function (response) {
                button('login').disabled = false;

                if (!response.ok) {
                    say(response.error, false);
                    refresh();

                    return;
                }

                say('Its login is set up again, and it was restarted.', true);
                setTimeout(refresh, 2000);
            });
        });

        button('restart').addEventListener('click', function () {
            say('Restarting…', true);
            call('restart', { confirm: 1 }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return;
                }

                say('Restarted.', true);
                setTimeout(refresh, 2000);
            });
        });

        <?php manage_timer_script(); ?>
        refresh();
    })();
    </script>
</div>
