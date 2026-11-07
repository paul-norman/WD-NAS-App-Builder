<?php
// qBittorrent's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('qbittorrent');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="qbittorrent-manage">
    <?php manage_styles('qbittorrent-manage'); ?>

    <h2>qBittorrent</h2>
    <table>
        <tr><td>Status</td><td data-qbt="status">…</td></tr>
        <tr><td>Version</td><td data-qbt="version">-</td></tr>
        <tr><td>Torrents</td><td data-qbt="torrents">-</td></tr>
        <tr><td>Address</td><td data-qbt="address">-</td></tr>
    </table>
    <p><a class="mg-button" data-qbt="link" href="#" target="_blank" rel="noopener">Open qBittorrent</a>
        <button type="button" data-qbt-action="restart">Restart qBittorrent</button></p>

    <h3>Logging in</h3>
    <p>User name <code>admin</code>, password <code data-qbt="password">••••••••••••</code>
        <button type="button" data-qbt-action="show">Show</button> <button type="button" data-qbt-action="copy">Copy</button>
        <button type="button" data-qbt-action="new-password">New password</button></p>
    <p class="mg-note">For the web interface, and for remote apps (e.g. phone apps, or the Arr apps) on port
        8092.</p>

    <h3>Settings</h3>
    <p><label>Downloads folder <input type="text" data-qbt="download-dir" size="40" spellcheck="false"></label></p>
    <p><label>Peer port <input type="number" data-qbt="peer-port" min="1024" max="65535"></label>
        <label>Download limit <input type="number" data-qbt="down-limit" min="0"> KB/s</label>
        <label>Upload limit <input type="number" data-qbt="up-limit" min="0"> KB/s</label></p>
    <p><label><input type="checkbox" data-qbt="local"> Only through the Nginx app (HTTPS)</label>
        <button type="button" data-qbt-action="settings">Save</button></p>
    <p class="mg-note">The downloads folder must be in one of the NAS's shares; qBittorrent's files there can be changed
        by the NAS's users. Limits of 0 mean none. For other computers to connect to it, forward the peer port (TCP and
        UDP) to the NAS on your router, if it doesn't do so by itself (UPnP / NAT-PMP). qBittorrent restarts.</p>

    <details class="mg-section">
        <summary>qBittorrent's latest log lines</summary>
        <pre data-qbt="log"></pre>
    </details>

    <p data-qbt="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('qbittorrent', 'qbt'); ?>
        <?php manage_secret_script(); ?>

        let loaded = false;

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
                const url    = response.site.url || (response.listen === 'local' ? '' : response.address);

                status.textContent = !response.running ? 'Stopped' : (response.answering ? 'Running' : 'Starting…');
                status.className   = response.running && response.answering ? 'mg-ok' : 'mg-bad';

                part('version').textContent  = response.version || '-';
                part('torrents').textContent = response.answering
                    ? `${response.torrents} (↓ ${response.download} kB/s, ↑ ${response.upload} kB/s)`
                    : '-';
                part('address').textContent  = [response.site.url, response.listen === 'local' ? '' : response.address].filter(Boolean).join(' and ') || '-';
                part('link').href            = url || '#';

                if (!loaded) {
                    part('download-dir').value = response.download_dir;
                    part('peer-port').value    = response.peer_port;
                    part('down-limit').value   = response.down_limit;
                    part('up-limit').value     = response.up_limit;
                    part('local').checked      = response.listen === 'local';

                    loaded = true;
                }

                part('log').textContent = response.log.length ? response.log.join('\n') : 'Nothing logged';
            });
        }

        // Keep the page current, until the dashboard removes it
        <?php manage_timer_script(); ?>
        <?php manage_act_script(); ?>

        button('restart').addEventListener('click', function () {
            act('restart', { confirm: 1 }, 'Restarting qBittorrent…', 'qBittorrent restarted.');
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
            if (!window.confirm('Make a new password? Apps using the current one need the new one, and qBittorrent restarts.')) {
                return;
            }

            act('new_password', { confirm: 1 }, 'Making a new password…', 'New password in use.').then(function (response) {
                if (response) {
                    password.set(response.password);
                }
            });
        });

        button('settings').addEventListener('click', function () {
            act('settings', {
                download_dir: part('download-dir').value,
                peer_port:    part('peer-port').value,
                down_limit:   part('down-limit').value,
                up_limit:     part('up-limit').value,
                listen:       part('local').checked ? 'local' : 'all'
            }, 'Saving…', 'Saved - qBittorrent restarted.');
        });

        refresh();
    })();
    </script>
</div>
