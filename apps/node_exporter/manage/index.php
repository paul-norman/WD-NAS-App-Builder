<?php
// Node Exporter's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('node_exporter');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="node_exporter-manage">
    <?php manage_styles('node_exporter-manage'); ?>

    <h2>Node Exporter</h2>
    <table>
        <tr><td>Status</td><td data-ne="status">…</td></tr>
        <tr><td>Version</td><td data-ne="version">-</td></tr>
        <tr><td>Metrics</td><td><code data-ne="url">-</code> <button type="button" data-ne-action="copy-url">Copy</button></td></tr>
        <tr><td>WD storage metrics</td><td data-ne="wd">…</td></tr>
        <tr><td>Storage health</td><td data-ne="health">-</td></tr>
    </table>
    <p><a class="mg-button" data-ne="link" href="#" target="_blank" rel="noopener">Open metrics</a>
        <button type="button" data-ne-action="restart">Restart Node Exporter</button></p>

    <h3>Settings</h3>
    <p><label>Port <input type="number" data-ne="port" min="1024" max="65535" style="width: 7em"></label>
        <label><input type="checkbox" data-ne="auth"> Require a password to read the metrics</label>
        <button type="button" data-ne-action="save">Save</button></p>
    <p data-ne="first-password" hidden><input type="text" data-ne="auth-password" placeholder="Password (leave empty to generate one)"
        autocomplete="off" spellcheck="false"> <span class="mg-note">for the user name <code>prometheus</code> - shown below once saved</span></p>
    <p class="mg-note">Node Exporter restarts. Without a password, anyone on the local network can read the metrics (they
        show the NAS's activity, not files or settings).</p>
    <div data-ne="auth-section" hidden>
        <p>User name: <code data-ne="user">prometheus</code>, password: <code data-ne="password">••••••••••••</code>
            <button type="button" data-ne-action="show">Show</button> <button type="button" data-ne-action="copy">Copy</button></p>
        <p><input type="text" data-ne="new" placeholder="New password (leave empty to generate one)" autocomplete="off" spellcheck="false">
            <button type="button" data-ne-action="set">Change password</button></p>
        <p class="mg-note">The new password takes effect immediately. Passwords are 12-128 characters: letters, digits and . _ ~ -</p>
    </div>

    <h3>Storage (as WD sees it)</h3>
    <table data-ne="disks" style="margin-bottom: 1rem"></table>
    <table data-ne="raids" style="margin-bottom: 1rem"></table>
    <table data-ne="volumes"></table>

    <h3>Prometheus and Grafana</h3>
    <p>Add the NAS to Prometheus's <code>prometheus.yml</code>
        <button type="button" data-ne-action="copy-config">Copy</button></p>
    <pre data-ne="config"></pre>
    <p class="mg-note">In Grafana, the "Node Exporter Full" dashboard (ID 1860) shows the system metrics; WD's storage
        metrics all start with <code>wd_</code> (e.g. <code>wd_health</code>, <code>wd_disk_temperature_celsius</code>,
        <code>wd_raid_disks</code>).</p>

    <details class="mg-section" data-ne="log-section" hidden>
        <summary>Node Exporter's latest warnings</summary>
        <pre data-ne="log"></pre>
    </details>

    <p data-ne="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('node_exporter', 'ne'); ?>
        <?php manage_secret_script(); ?>

        let healths   = [['Healthy', 'mg-ok'], ['Degraded', 'mg-bad'], ['Critical', 'mg-bad']];
        let loaded    = false;
        let savedAuth = false;

        /**
         * A size, for showing (e.g. 4.0 TB, in powers of 1000 as disks are sold).
         *
         * @param {number} bytes The size, in bytes
         *
         * @return {string} The size, with its unit
         */
        function formatBytes(bytes) {
            let units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
            let i     = 0;

            while (bytes >= 1000 && i < units.length - 1) {
                bytes /= 1000;

                i++;
            }

            return (i ? bytes.toFixed(1) : bytes) + ' ' + units[i];
        }

        /**
         * Fills a table with a header row and rows of text ({ text, className } for a coloured cell).
         *
         * @param {HTMLTableElement} table The table
         * @param {Array.<string>}   head  The header row's titles
         * @param {Array.<Array>}    rows  The rows
         * @param {string}           empty What to show when there are no rows
         *
         * @return {void}
         */
        function fillTable(table, head, rows, empty) {
            table.textContent = '';

            if (!rows.length) {
                table.insertRow().insertCell().textContent = empty;

                return;
            }

            let header = table.insertRow();

            head.forEach(function (title) {
                let cell = header.insertCell();

                cell.textContent      = title;
                cell.style.fontWeight = 'bold';
            });

            rows.forEach(function (values) {
                let row = table.insertRow();

                values.forEach(function (value) {
                    let cell = row.insertCell();

                    if (value && typeof value === 'object') {
                        cell.textContent = value.text;
                        cell.className = value.className;
                    } else {
                        cell.textContent = value;
                    }
                });
            });
        }

        /**
         * Prometheus' scrape configuration for this NAS, to copy.
         *
         * @param {Object} status The status: port, auth and user
         *
         * @return {string} The YAML
         */
        function scrapeConfig(status) {
            let lines = ['scrape_configs:', '  - job_name: wd-nas', '    static_configs:',
                '      - targets: [\'' + window.location.hostname + ':' + status.port + '\']'];

            if (status.auth) {
                lines.push('    basic_auth:', '      username: ' + status.user, '      password: \'<the password above>\'');
            }

            return lines.join('\n');
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

                status.textContent = !response.running ? 'Stopped' : (response.answering ? 'Running' : 'Starting… (or port ' + response.port + ' is in use)');
                status.className   = response.running && response.answering ? 'mg-ok' : 'mg-bad';

                part('version').textContent = response.version || '-';

                let url = 'http://' + window.location.hostname + ':' + response.port + '/metrics';

                part('url').textContent     = url;
                part('link').href           = url;
                part('user').textContent    = response.user;
                part('auth-section').hidden = !response.auth;

                savedAuth = response.auth;

                part('config').textContent = scrapeConfig(response);

                // The settings are only filled in once, so a refresh doesn't undo changes being made
                if (!loaded) {
                    part('port').value   = response.port;
                    part('auth').checked = response.auth;

                    loaded = true;
                }

                showFirstPassword();

                let metrics = part('wd');

                metrics.textContent = !response.wd_running ? 'Not running' : (!response.wd_collected ? 'WD\'s records could not be read' :
                    'Updated ' + response.wd_age + ' seconds ago');
                metrics.className = response.wd_running && response.wd_collected ? 'mg-ok' : 'mg-bad';

                let health = response.health === null ? ['-', ''] : healths[response.health];

                part('health').textContent = health[0];
                part('health').className = health[1];

                fillTable(part('disks'), ['Bay', 'Disk', 'Model', 'Temperature', 'State', 'SMART'], response.disks.map(function (disk) {
                    let state = disk.failed ? { text: 'failed', className: 'mg-bad' } :
                        (!disk.healthy || disk.over_temperature ? { text: disk.over_temperature ? 'too hot' : 'unhealthy', className: 'mg-bad' } :
                        { text: disk.sleeping ? 'healthy (asleep)' : 'healthy', className: 'mg-ok' });

                    // The disk's own SMART assessment, and its problem sectors (reallocated, pending, uncorrectable)
                    let smart = disk.smart_healthy === undefined ? { text: 'not read yet', className: 'mg-note' } :
                        (!disk.smart_healthy ? { text: 'failed', className: 'mg-bad' } : (disk.bad_sectors ?
                        { text: 'passed, ' + disk.bad_sectors + ' problem sector' + (disk.bad_sectors === 1 ? '' : 's'), className: 'mg-bad' } :
                        { text: 'passed', className: 'mg-ok' }));

                    return [disk.bay, disk.disk, disk.info || '', disk.temperature_celsius !== undefined ? disk.temperature_celsius + ' °C' : '-', state, smart];
                }), 'No disks found');

                let raids = response.raids.filter(function (raid) {
                    return !raid.system;
                });

                fillTable(part('raids'), ['RAID', 'Level', 'Disks', 'State'], raids.map(function (raid) {
                    let disks = raid.disks_working + ' of ' + raid.disks_total + ' working';

                    if (raid.disks_failed) {
                        disks += ', ' + raid.disks_failed + ' failed';
                    }

                    if (raid.disks_rebuilding) {
                        disks += ', ' + raid.disks_rebuilding + ' rebuilding';
                    }

                    return [raid.raid, (raid.level || '').toUpperCase(), disks, { text: raid.state, className: raid.state === 'clean' ? 'mg-ok' : 'mg-bad' }];
                }), 'No RAID arrays (or JBOD)');

                fillTable(part('volumes'), ['Volume', 'Mounted at', 'Used', 'State'], response.volumes.map(function (volume) {
                    let used = volume.size_bytes ? formatBytes(volume.used_bytes) + ' of ' + formatBytes(volume.size_bytes) +
                        ' (' + Math.round(100 * volume.used_bytes / volume.size_bytes) + '%)' : '-';

                    return [volume.volume, volume.info || '', used, volume.mounted ? { text: 'mounted', className: 'mg-ok' } :
                        { text: volume.unlocked ? 'not mounted' : 'locked', className: 'mg-bad' }];
                }), 'No volumes found');

                part('log-section').hidden = !response.log.length;
                part('log').textContent    = response.log.join('\n');
            });
        }

        // Keep the page current, until the dashboard removes it
        <?php manage_timer_script(); ?>

        /**
         * Shows the first password's field while "Require a password" is ticked but not yet on (an empty one is
         * generated).
         *
         * @return {void}
         */
        function showFirstPassword() {
            part('first-password').hidden = !part('auth').checked || savedAuth;
        }

        part('auth').addEventListener('change', showFirstPassword);

        button('copy-url').addEventListener('click', function () {
            copyText(part('url').textContent);
        });

        button('copy-config').addEventListener('click', function () {
            copyText(part('config').textContent);
        });

        button('restart').addEventListener('click', function () {
            say('Restarting Node Exporter…', true);

            call('restart', { confirm: 1 }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return;
                }

                say('Node Exporter restarted.', true);
                setTimeout(refresh, 2000);
            });
        });

        button('save').addEventListener('click', function () {
            say('Saving…', true);

            let password = part('first-password').hidden ? '' : part('auth-password').value;

            call('settings', { port: part('port').value, auth: part('auth').checked ? 1 : 0, password: password }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return;
                }

                part('auth-password').value = '';

                secret.reset();

                say('Saved - Node Exporter restarted. The Prometheus app follows by itself; update any other Prometheus to match.', true);
                setTimeout(refresh, 2000);
            });
        });

        // The password: Show / Hide and Copy (fetched when first needed)
        let secret = secretControls(part('password'), button('show'), button('copy'), function () {
            return call('password', { show: 1 }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return null;
                }

                return response.password || '(none saved)';
            });
        });

        button('set').addEventListener('click', function () {
            let input = part('new');

            if (!window.confirm('Change the password? Any Prometheus scraping the NAS needs the new one (the Prometheus app follows by itself).')) {
                return;
            }

            call('set_password', { password: input.value }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return;
                }

                input.value = '';

                secret.set(response.password);
                say('Password changed. The Prometheus app follows by itself; update any other Prometheus to match.', true);
            });
        });

        refresh();
    })();
    </script>
</div>
