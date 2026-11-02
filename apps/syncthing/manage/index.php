<?php
// Syncthing's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('syncthing');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="syncthing-manage">
    <?php manage_styles('syncthing-manage'); ?>

    <h2>Syncthing</h2>
    <table>
        <tr><td>Status</td><td data-sy="status">…</td></tr>
        <tr><td>Version</td><td data-sy="version">-</td></tr>
        <tr><td>NAS device ID</td><td><code data-sy="device-id">-</code></td></tr>
        <tr><td>Usage reporting</td><td><span data-sy="usage">-</span> <button type="button" data-sy-action="usage-off" hidden>Turn off</button></td></tr>
    </table>
    <p class="mg-note">Other devices add the NAS with its device ID.</p>
    <p><a class="mg-button" data-sy="link" href="#" target="_blank" rel="noopener">Open Syncthing</a>
        <button type="button" data-sy-action="restart">Restart Syncthing</button></p>

    <h3>Logging in</h3>
    <p>Log in to Syncthing as <code data-sy="user">admin</code> with: <code data-sy="password">••••••••••••</code>
        <button type="button" data-sy-action="show">Show</button> <button type="button" data-sy-action="copy">Copy</button></p>
    <p><input type="text" data-sy="new" placeholder="New password (leave empty to generate one)" autocomplete="off" spellcheck="false">
        <button type="button" data-sy-action="set">Change password</button></p>
    <p class="mg-note">The new password takes effect immediately. Passwords are 12-128 characters: letters, digits and . _ ~ -
        (a password changed in Syncthing's own settings isn't shown here).</p>

    <h3>Folders</h3>
    <table data-sy="folders"></table>

    <h3>Devices</h3>
    <table data-sy="devices"></table>

    <p data-sy="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('syncthing', 'sy'); ?>
        <?php manage_secret_script(); ?>

        let states = {
            idle:             'up to date',
            scanning:         'scanning',
            'scan-waiting':   'waiting to scan',
            syncing:          'syncing',
            'sync-waiting':   'waiting to sync',
            'sync-preparing': 'preparing to sync',
            cleaning:         'cleaning up',
            error:            'error',
            paused:           'paused'
        };

        /**
         * Fills a table with rows of text ({ text, className } for a coloured cell). Folder and device names come from
         * Syncthing, so they're only ever set as text.
         *
         * @param {HTMLTableElement} table The table
         * @param {Array.<Array>}    rows  The rows
         * @param {string}           empty What to show when there are no rows
         *
         * @return {void}
         */
        function fillTable(table, rows, empty) {
            table.textContent = '';

            if (!rows.length) {
                table.insertRow().insertCell().textContent = empty;

                return;
            }

            rows.forEach(function (values) {
                let row = table.insertRow();

                values.forEach(function (value) {
                    let cell = row.insertCell();

                    if (value && typeof value === 'object') {
                        cell.textContent = value.text;
                        cell.className   = value.className;
                    } else {
                        cell.textContent = value;
                    }
                });
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

                status.textContent = !response.running ? 'Stopped' : (response.answering ? 'Running' : 'Starting…');
                status.className   = response.running && response.answering ? 'mg-ok' : 'mg-bad';

                if (!response.answering) {
                    return;
                }

                part('version').textContent   = response.version || '-';
                part('device-id').textContent = response.device_id;
                part('user').textContent      = response.gui_user || 'admin';

                let usage = part('usage');

                usage.textContent = response.usage_reporting > 0 ? 'on (anonymous statistics are sent to the Syncthing project)' :
                    (response.usage_reporting < 0 ? 'off' : 'not decided yet (Syncthing asks when its GUI is opened)');
                usage.className   = response.usage_reporting > 0 ? 'mg-bad' : (response.usage_reporting < 0 ? 'mg-ok' : '');

                button('usage-off').hidden = response.usage_reporting < 0;

                fillTable(part('folders'), response.folders.map(function (folder) {
                    let state = states[folder.state] || folder.state;

                    if (folder.need > 0) {
                        state += ' (' + folder.need + ' files to go)';
                    }

                    return [folder.label, folder.path, { text: state, className: folder.state === 'idle' ? 'mg-ok' : (folder.state === 'error' ? 'mg-bad' : 'mg-note') }];
                }), 'No folders yet - add them in Syncthing, using their full path on the NAS (e.g. /mnt/HD/HD_a2/<share>/<folder>)');

                fillTable(part('devices'), response.devices.map(function (device) {
                    return [device.name, device.paused ? { text: 'paused', className: 'mg-note' } :
                        { text: device.connected ? 'connected' : 'not connected', className: device.connected ? 'mg-ok' : 'mg-note' }];
                }), 'No other devices yet');
            });
        }

        part('link').href = 'http://' + window.location.hostname + ':8384/';

        // Keep the page current (e.g. while folders sync), until the dashboard removes it
        <?php manage_timer_script(10000); ?>

        button('restart').addEventListener('click', function () {
            if (!window.confirm('Restart Syncthing? Syncing pauses until it is back.')) {
                return;
            }

            say('Restarting Syncthing…', true);

            call('restart', { confirm: 1 }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return;
                }

                say('Syncthing restarted.', true);
                setTimeout(refresh, 3000);
            });
        });

        button('usage-off').addEventListener('click', function () {
            call('usage_reporting_off', { confirm: 1 }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return;
                }

                say('Usage reporting is off.', true);
                refresh();
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

            if (!window.confirm('Change the Syncthing password? You will need the new one to log in.')) {
                return;
            }

            call('set_password', { password: input.value }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return;
                }

                input.value = '';

                secret.set(response.password);

                say('Password changed - use it to log in to Syncthing.', true);
            });
        });

        refresh();
    })();
    </script>
</div>
