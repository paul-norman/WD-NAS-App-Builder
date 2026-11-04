<?php
// The Postgres Exporter app's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('postgres_exporter');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="postgres_exporter-manage">
    <?php manage_styles('postgres_exporter-manage'); ?>

    <h2>Postgres Exporter</h2>
    <p>Gives Prometheus the PostgreSQL app's metrics (its activity, transactions, cache and locks), with a Grafana dashboard. It answers on the NAS itself only.</p>
    <table>
        <tr><td>Status</td><td data-pge="status">…</td></tr>
        <tr><td>Version</td><td data-pge="version">-</td></tr>
        <tr><td>PostgreSQL</td><td data-pge="connected">-</td></tr>
        <tr><td>Its login</td><td data-pge="login">-</td></tr>
        <tr><td>Prometheus</td><td data-pge="prometheus">-</td></tr>
        <tr><td>Grafana</td><td data-pge="grafana">-</td></tr>
    </table>
    <p><button type="button" data-pge-action="login">Set up its login again</button>
        <button type="button" data-pge-action="restart">Restart</button></p>
    <p data-pge="message"></p>

    <details data-pge="log-box" hidden>
        <summary>Its latest messages</summary>
        <pre data-pge="log"></pre>
    </details>

    <h3>How it works</h3>
    <ul>
        <li>It logs in to PostgreSQL as <code>postgres_exporter</code>, a login the app creates with a password only it keeps. That login is in <code>pg_monitor</code>: it can read PostgreSQL's statistics, not your data.</li>
        <li>Prometheus collects its metrics every 30 seconds, by itself, once the Prometheus app is installed. Its dashboard appears in Grafana's <em>NAS</em> folder.</li>
        <li>It listens on the NAS itself only (<code>127.0.0.1:9187</code>), and runs as its own user.</li>
    </ul>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('postgres_exporter', 'pge'); ?>

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
                    show('connected', 'The PostgreSQL app isn\'t installed', false);
                } else if (!response.answering) {
                    show('connected', '-', null);
                } else {
                    show('connected', response.connected ? 'Connected' : 'Not reached - is PostgreSQL running? Setting up its login again helps if PostgreSQL was started afresh', response.connected);
                }

                let login = response.login;

                if (login.state === 'ok') {
                    show('login', 'postgres_exporter, set up (' + login.time.replace('T', ' ').slice(0, 16) + ' UTC)', true);
                } else if (login.state === 'failed') {
                    show('login', 'Failed (' + login.time.replace('T', ' ').slice(0, 16) + ' UTC): ' + login.message, false);
                } else {
                    show('login', 'Not yet - it\'s set up once PostgreSQL answers', null);
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
                        link.textContent = 'Its dashboard: PostgreSQL (in the NAS folder)';

                        show('grafana', link, null);
                    } else {
                        show('grafana', 'Its dashboard is in Grafana\'s NAS folder: PostgreSQL', null);
                    }
                }

                part('log-box').hidden = !response.log.length;
                part('log').textContent = response.log.join('\n');
            });
        }

        button('login').addEventListener('click', function () {
            button('login').disabled = true;
            say('Setting up its login in PostgreSQL (a new password)…', true);
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
