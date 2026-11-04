<?php
// The Valkey Exporter app's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('redis_exporter');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="redis_exporter-manage">
    <?php manage_styles('redis_exporter-manage'); ?>

    <h2>Valkey Exporter</h2>
    <p>Gives Prometheus the Valkey app's metrics (memory, clients, commands and keys), with a Grafana dashboard. It answers on the NAS itself only.</p>
    <table>
        <tr><td>Status</td><td data-rde="status">…</td></tr>
        <tr><td>Version</td><td data-rde="version">-</td></tr>
        <tr><td>Valkey</td><td data-rde="connected">-</td></tr>
        <tr><td>Valkey's password</td><td data-rde="login">-</td></tr>
        <tr><td>Prometheus</td><td data-rde="prometheus">-</td></tr>
        <tr><td>Grafana</td><td data-rde="grafana">-</td></tr>
    </table>
    <p><button type="button" data-rde-action="login">Read Valkey's password again</button>
        <button type="button" data-rde-action="restart">Restart</button></p>
    <p data-rde="message"></p>

    <details data-rde="log-box" hidden>
        <summary>Its latest messages</summary>
        <pre data-rde="log"></pre>
    </details>

    <h3>How it works</h3>
    <ul>
        <li>It uses the Valkey app's password (Valkey has one), read again every time it starts.</li>
        <li>Prometheus collects its metrics every 30 seconds, by itself, once the Prometheus app is installed. Its dashboard appears in Grafana's <em>NAS</em> folder.</li>
        <li>It listens on the NAS itself only (<code>127.0.0.1:9121</code>), and runs as its own user.</li>
    </ul>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('redis_exporter', 'rde'); ?>

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
                    show('connected', 'The Valkey app isn\'t installed', false);
                } else if (!response.answering) {
                    show('connected', '-', null);
                } else {
                    show('connected', response.connected ? 'Connected' : 'Not reached - is Valkey running? If its password was changed, read it again', response.connected);
                }

                let login = response.login;

                if (login.state === 'ok') {
                    show('login', 'Read (' + login.time.replace('T', ' ').slice(0, 16) + ' UTC)', true);
                } else if (login.state === 'failed') {
                    show('login', 'Failed (' + login.time.replace('T', ' ').slice(0, 16) + ' UTC): ' + login.message, false);
                } else {
                    show('login', 'Not yet - it\'s set up once Valkey answers', null);
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
                        link.textContent = 'Its dashboard: Valkey (Redis) (in the NAS folder)';

                        show('grafana', link, null);
                    } else {
                        show('grafana', 'Its dashboard is in Grafana\'s NAS folder: Valkey (Redis)', null);
                    }
                }

                part('log-box').hidden = !response.log.length;
                part('log').textContent = response.log.join('\n');
            });
        }

        button('login').addEventListener('click', function () {
            button('login').disabled = true;
            say('Reading Valkey\'s password again…', true);
            call('login', { confirm: 1 }).then(function (response) {
                button('login').disabled = false;

                if (!response.ok) {
                    say(response.error, false);
                    refresh();

                    return;
                }

                say('Valkey\'s password was read again, and it was restarted.', true);
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
