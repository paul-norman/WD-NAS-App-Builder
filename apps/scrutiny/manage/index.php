<?php
// Scrutiny's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('scrutiny');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="scrutiny-manage">
    <?php manage_styles('scrutiny-manage'); ?>

    <h2>Scrutiny</h2>
    <table>
        <tr><td>Status</td><td data-sc="status">…</td></tr>
        <tr><td>Version</td><td data-sc="version">-</td></tr>
        <tr><td>Address</td><td data-sc="address">-</td></tr>
        <tr><td>Disks last read</td><td data-sc="last-collect">-</td></tr>
    </table>
    <p><a class="mg-button" data-sc="link" href="#" target="_blank" rel="noopener">Open Scrutiny</a>
        <button type="button" data-sc-action="collect">Read the disks now</button>
        <button type="button" data-sc-action="restart">Restart Scrutiny</button></p>
    <p class="mg-note" data-sc="no-site" hidden>Scrutiny has no login of its own, so it's only reachable through the Nginx
        app (which asks for the login below): install the Nginx app, and set its domain, to open it.</p>

    <h3>Disks</h3>
    <table data-sc="disks"></table>
    <p class="mg-note">Read hourly. A disk that's asleep is left asleep - its last reading stays until it next wakes.</p>

    <h3>Logging in</h3>
    <p>User name <code>admin</code>, password <code data-sc="password">••••••••••••</code>
        <button type="button" data-sc-action="show">Show</button> <button type="button" data-sc-action="copy">Copy</button>
        <button type="button" data-sc-action="new-password">New password</button></p>
    <p class="mg-note">Asked for by the Nginx app, before Scrutiny's pages.</p>

    <h3>Alerts</h3>
    <p><label>To the ntfy app's topic <input type="text" data-sc="ntfy-topic" size="16" spellcheck="false" placeholder="e.g. nas"></label>
        <button type="button" data-sc-action="settings">Save</button>
        <button type="button" data-sc-action="test-alert">Send a test alert</button></p>
    <p class="mg-note" data-sc="ntfy-note">When a disk fails its SMART check, or Scrutiny judges it likely to fail (from
        the failure rates of each attribute's values), it alerts this topic of the <a href="https://ntfy.sh/" target="_blank"
        rel="noopener">ntfy</a> app - empty for none. Scrutiny restarts.</p>

    <details class="mg-section">
        <summary>The disk reader's latest log lines</summary>
        <pre data-sc="log"></pre>
    </details>

    <p data-sc="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('scrutiny', 'sc'); ?>
        <?php manage_secret_script(); ?>

        let loaded = false;

        /**
         * A size in bytes, as disks are sold (TB / GB: powers of 1000).
         *
         * @param {number} bytes The size
         *
         * @return {string} It, e.g. 8 TB
         */
        function size(bytes) {
            return bytes >= 1e12 ? `${Math.round(bytes / 1e11) / 10} TB` : `${Math.round(bytes / 1e9)} GB`;
        }

        /**
         * Shows the disks: each one's name, model and size, health, temperature and when it was last read.
         *
         * @param {Array.<Object>} disks The disks
         *
         * @return {void}
         */
        function fillDisks(disks) {
            let table = part('disks');

            table.textContent = '';

            if (!disks.length) {
                table.insertRow().insertCell().textContent = 'None yet: the disks are read hourly (or now, with the button above).';

                return;
            }

            disks.forEach(function (disk) {
                let row    = table.insertRow();
                let health = document.createElement('td');

                row.insertCell().textContent = `/dev/${disk.name}`;
                row.insertCell().textContent = `${disk.model} (${size(disk.capacity)}, ${disk.serial})`;
                health.textContent           = disk.status === 'passed' ? 'Healthy' : `Failed - ${disk.status.replace('failed ', '')}`;
                health.className             = disk.status === 'passed' ? 'mg-ok' : 'mg-bad';
                row.appendChild(health);
                row.insertCell().textContent = disk.temperature ? `${disk.temperature} °C` : '-';
                row.insertCell().textContent = disk.read ? new Date(disk.read).toLocaleString() : '-';
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

                const status = part('status');
                const last   = part('last-collect');

                status.textContent = !response.running ? 'Stopped' : (response.answering ? 'Running' : 'Starting…');
                status.className   = response.running && response.answering ? 'mg-ok' : 'mg-bad';

                part('version').textContent = response.version || '-';
                part('address').textContent = response.site.url || '-';
                part('link').href           = response.site.url || '#';
                part('link').hidden         = !response.site.url;
                part('no-site').hidden      = !!response.site.url;

                last.textContent = response.collecting
                    ? 'Reading them now…'
                    : (response.last_collect ? `${new Date(response.last_collect * 1000).toLocaleString()}${response.collect_ok ? '' : ' (with problems: see the log below)'}` : 'Not yet');
                last.className   = response.last_collect && !response.collect_ok && !response.collecting ? 'mg-bad' : '';

                fillDisks(response.disks);

                if (!loaded) {
                    part('ntfy-topic').value = response.ntfy_topic;

                    loaded = true;
                }

                button('test-alert').disabled = !response.ntfy_topic || !response.ntfy;
                part('log').textContent       = response.log.length ? response.log.join('\n') : 'Nothing logged';
            });
        }

        // Keep the page current, until the dashboard removes it
        <?php manage_timer_script(); ?>
        <?php manage_act_script(); ?>

        button('restart').addEventListener('click', function () {
            act('restart', { confirm: 1 }, 'Restarting Scrutiny…', 'Scrutiny restarted.');
        });

        button('collect').addEventListener('click', function () {
            act('collect', { confirm: 1 }, 'Reading the disks…', 'Reading the disks - their data shows in a moment.');
        });

        // The password: Show / Hide and Copy (fetched when first needed)
        const password = secretControls(part('password'), button('show'), button('copy'), function () {
            return call('password', { show: 1 }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return null;
                }

                return response.password;
            });
        });

        button('new-password').addEventListener('click', function () {
            if (!window.confirm('Make a new password?')) {
                return;
            }

            act('new_password', { confirm: 1 }, 'Making a new password…', 'New password in use.').then(function (response) {
                if (response) {
                    password.set(response.password);
                }
            });
        });

        button('settings').addEventListener('click', function () {
            act('settings', { ntfy_topic: part('ntfy-topic').value.trim() }, 'Saving…', 'Saved - Scrutiny restarted.');
        });

        button('test-alert').addEventListener('click', function () {
            act('test_alert', { confirm: 1 }, 'Sending a test alert…', 'Test alert sent.');
        });

        refresh();
    })();
    </script>
</div>
