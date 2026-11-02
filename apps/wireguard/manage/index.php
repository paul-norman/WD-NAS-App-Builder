<?php
// WireGuard's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('wireguard');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="wireguard-manage">
    <?php manage_styles('wireguard-manage'); ?>
    <style>
        #wireguard-manage [data-wg="viewer"] { border: 1px solid #ddd; padding: 0.5rem 1rem; margin: 0.5rem 0; }
        #wireguard-manage [data-wg="qr"] { width: 260px; height: 260px; background: #fff; image-rendering: pixelated; }
        #wireguard-manage [data-wg="config"] { white-space: pre; font-size: 0.85em; }
        #wireguard-manage .wg-columns { display: flex; flex-wrap: wrap; gap: 1.5rem; align-items: flex-start; }
        #wireguard-manage .wg-columns > div:last-child { flex: 1; min-width: 20rem; }
        #wireguard-manage select { min-width: 22rem; }
        #wireguard-manage h3 [data-wg-action="refresh"] { vertical-align: middle; margin-left: 0.5rem; padding: 0 0.4rem; line-height: 1; }
        #wireguard-manage h3 [data-wg-action="refresh"] svg { width: 14px; height: 14px; vertical-align: middle; }
        #wireguard-manage .wg-spin svg { animation: wg-spin 0.8s linear infinite; }
        @keyframes wg-spin { to { transform: rotate(360deg); } }
    </style>

    <h2>WireGuard</h2>
    <table>
        <tr><td>Status</td><td data-wg="status">…</td></tr>
        <tr><td>Version</td><td data-wg="version">-</td></tr>
        <tr><td>Devices connect to</td><td data-wg="connect">-</td></tr>
        <tr><td>The NAS in the VPN</td><td data-wg="nas-address">-</td></tr>
    </table>
    <p class="mg-bad" data-wg="endpoint-note" hidden>Set the address devices connect to (under Settings) before adding them.</p>
    <p><button type="button" data-wg-action="restart">Restart WireGuard</button></p>

    <h3>Devices <button type="button" data-wg-action="refresh" title="Refresh the devices' connections" aria-label="Refresh">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
            <path d="M21 12a9 9 0 0 1-15.5 6.2L3 16"/><path d="M3 21v-5h5"/><path d="M3 12a9 9 0 0 1 15.5-6.2L21 8"/><path d="M21 3v5h-5"/></svg></button></h3>
    <table data-wg="peers"></table>
    <p><label>New device <input type="text" data-wg="new-peer" autocomplete="off" placeholder="e.g. Paul's phone"></label>
        <button type="button" data-wg-action="add-peer">Add device</button></p>
    <div data-wg="viewer" hidden>
        <p><b data-wg="viewer-name"></b></p>
        <div class="wg-columns">
            <div><img data-wg="qr" alt="QR code"><br><span class="mg-note">Scan with the WireGuard app (Add a tunnel →
                Scan from QR code)</span></div>
            <div><pre data-wg="config"></pre>
                <p><button type="button" data-wg-action="download">Download the configuration</button>
                    <button type="button" data-wg-action="close">Close</button></p>
                <p class="mg-note">On a laptop: import the downloaded file in the WireGuard app. The configuration holds the
                    device's own key - keep it private.</p></div>
        </div>
    </div>
    <p class="mg-note">Each device gets its own keys and address: one per phone or laptop. Switching one off or removing it
        cuts it off straight away.</p>

    <h3>Settings</h3>
    <p><label>Devices connect to <input type="text" data-wg="endpoint" spellcheck="false" placeholder="home.example.com"></label>
        <label>port (UDP) <input type="number" data-wg="port" min="1024" max="65535" style="width: 7rem"></label></p>
    <p><label>Devices can reach <select data-wg="access">
        <option value="nas">The NAS only</option>
        <option value="lan">The NAS and the home network</option>
        <option value="all">Everything: all their internet traffic goes through home</option>
    </select></label></p>
    <p><label>DNS servers <input type="text" data-wg="dns" spellcheck="false"></label></p>
    <p><label>Address range <input type="text" data-wg="subnet" spellcheck="false" placeholder="10.8.0.0/24"></label></p>
    <p><button type="button" data-wg-action="settings">Save</button></p>
    <p class="mg-note"><b>Your router</b> must pass the UDP port above on to the NAS (<span data-wg="router-target">its
        address</span>): look for "port forwarding" in its settings. "Devices connect to" is your home's address on the
        internet: a domain name that points to it (e.g. from your router's dynamic DNS) or its IP address. DNS servers: what
        the devices use for names while connected (by default the NAS's own - e.g. your router or Pi-hole). Changing these
        means adding the devices' configurations to them again. WireGuard restarts.</p>

    <details class="mg-section">
        <summary>WireGuard's log</summary>
        <pre data-wg="log"></pre>
    </details>

    <p data-wg="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('wireguard', 'wg'); ?>

        let loaded = false;
        let shown  = null;

        /**
         * Runs one of the API's actions, saying it's being done, then how it went - and shows the status again.
         *
         * @param {string} action  The API's action
         * @param {Object} data    What to post (a GET when there's none)
         * @param {string} working What to say meanwhile
         * @param {string} done    What to say once it's done
         *
         * @return {Promise.<(Object|null)>} Its answer (null if it failed)
         */
        function act(action, data, working, done) {
            say(working, true);

            return call(action, data).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return null;
                }

                say(done, true);
                refresh();

                return response;
            });
        }

        /**
         * A size, for showing (e.g. 5.2 MB).
         *
         * @param {number} bytes The size, in bytes
         *
         * @return {string} The size, with its unit
         */
        function formatSize(bytes) {
            return bytes >= 1073741824 ? (bytes / 1073741824).toFixed(1) + ' GB'
                : (bytes >= 1048576 ? (bytes / 1048576).toFixed(1) + ' MB' : Math.round(bytes / 1024) + ' KB');
        }

        /**
         * How long ago something was, for showing.
         *
         * @param {number} seconds How many seconds ago
         *
         * @return {string} e.g. 5 minutes ago
         */
        function formatTimeAgo(seconds) {
            return seconds < 90 ? seconds + ' seconds ago' : (seconds < 5400 ? Math.round(seconds / 60) + ' minutes ago'
                : (seconds < 129600 ? Math.round(seconds / 3600) + ' hours ago' : Math.round(seconds / 86400) + ' days ago'));
        }

        /**
         * A device's state: connected (a handshake in the last 3 minutes - WireGuard renews them every 2), last
         * connected, never connected, or switched off.
         *
         * @param {Object} peer The device, with what WireGuard knows of it (live)
         * @param {number} now  The time now, in seconds
         *
         * @return {Array.<string>} [its state, a class name for it]
         */
        function peerState(peer, now) {
            if (!peer.enabled) {
                return ['Switched off', ''];
            }

            if (!peer.live || !peer.live.handshake) {
                return ['Never connected', ''];
            }

            let since   = now - peer.live.handshake;
            let traffic = ' - ' + formatSize(peer.live.received) + ' in, ' + formatSize(peer.live.sent) + ' out';

            return since < 180 ? ['Connected' + (peer.live.endpoint ? ' from ' + peer.live.endpoint : '') + traffic, 'mg-ok']
                : ['Last connected ' + formatTimeAgo(since) + traffic, ''];
        }

        /**
         * Makes an element, with its text (set as text) and class.
         *
         * @param {string} tag       Its tag
         * @param {string} text      Its text ('' for none)
         * @param {string} className Its class names ('' for none)
         *
         * @return {HTMLElement} The element
         */
        function element(tag, text, className) {
            let node = document.createElement(tag);

            if (text) {
                node.textContent = text;
            }

            if (className) {
                node.className = className;
            }

            return node;
        }

        /**
         * Shows the devices: each one's name, address and state, with Show configuration, Switch on / off and Remove.
         *
         * @param {Array.<Object>} peers The devices
         * @param {number}         now   The time now, in seconds
         *
         * @return {void}
         */
        function fillPeers(peers, now) {
            let table = part('peers');

            table.textContent = '';

            if (!peers.length) {
                table.insertRow().insertCell().textContent = 'No devices yet';

                return;
            }

            peers.forEach(function (peer) {
                let row = table.insertRow();

                row.insertCell().textContent = peer.name;
                row.insertCell().textContent = peer.address;

                let state = peerState(peer, now);

                row.insertCell().appendChild(element('span', state[0], state[1]));

                let actions = row.insertCell();
                let view    = element('button', 'Show configuration');
                let toggle  = element('button', peer.enabled ? 'Switch off' : 'Switch on');
                let remove  = element('button', 'Remove');

                [view, toggle, remove].forEach(function (button) {
                    button.type = 'button';

                    actions.appendChild(button);
                    actions.appendChild(document.createTextNode(' '));
                });

                view.addEventListener('click', function () {
                    showConfig(peer.id);
                });

                toggle.addEventListener('click', function () {
                    act('switch_peer', { id: peer.id, enabled: peer.enabled ? 0 : 1 }, 'Updating…',
                        peer.name + (peer.enabled ? ' switched off.' : ' switched on.'));
                });

                remove.addEventListener('click', function () {
                    if (!window.confirm('Remove ' + peer.name + '? It can no longer connect (its configuration stops working).')) {
                        return;
                    }

                    act('remove_peer', { id: peer.id }, 'Removing…', peer.name + ' removed.').then(function () {
                        if (shown && shown.id === peer.id) {
                            part('viewer').hidden = true;
                        }
                    });
                });
            });
        }

        /**
         * Shows a device's configuration and its QR code.
         *
         * @param {string} id The device's id
         *
         * @return {Promise} Done once it's shown
         */
        function showConfig(id) {
            return call('peer_config', { id: id }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return;
                }

                shown = {
                    id:     id,
                    file:   response.file,
                    config: response.config
                };

                part('viewer-name').textContent = response.name;
                part('config').textContent      = response.config;
                part('qr').src                  = response.qr ? 'data:image/svg+xml;base64,' + response.qr : '';
                part('qr').hidden               = !response.qr;
                part('viewer').hidden           = false;
            });
        }

        button('download').addEventListener('click', function () {
            if (!shown) {
                return;
            }

            let link = document.createElement('a');

            link.href     = URL.createObjectURL(new Blob([shown.config], { type: 'text/plain' }));
            link.download = shown.file;

            document.body.appendChild(link);

            link.click();

            setTimeout(function () {
                URL.revokeObjectURL(link.href);

                link.remove();
            }, 1000);
        });

        button('close').addEventListener('click', function () {
            part('viewer').hidden = true;

            shown = null;
        });

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

                status.textContent = response.running ? 'Running' : 'Stopped';
                status.className   = response.running ? 'mg-ok' : 'mg-bad';

                part('version').textContent       = response.version ? 'wireguard-go ' + response.version + (response.tools_version ? ', wg ' + response.tools_version : '') : '-';
                part('connect').textContent       = response.endpoint ? response.endpoint + ':' + response.port + ' (UDP)' : 'not set yet';
                part('nas-address').textContent   = response.address + (response.access !== 'nas' && response.lan.address ? ' - and ' + response.lan.address + ' as at home' : '');
                part('endpoint-note').hidden      = !!response.endpoint;
                part('router-target').textContent = response.lan.address ? response.lan.address : 'its address';

                fillPeers(response.peers, response.now);

                if (!loaded) {
                    part('endpoint').value       = response.endpoint;
                    part('endpoint').placeholder = response.suggested_endpoint || 'home.example.com';
                    part('port').value           = response.port;
                    part('access').value         = response.access;
                    part('dns').value            = response.dns;
                    part('dns').placeholder      = response.default_dns ? response.default_dns + ' (the NAS\'s)' : 'e.g. 192.168.1.1';
                    part('subnet').value         = response.subnet;

                    if (response.lan.subnet) {
                        part('access').querySelector('option[value="lan"]').textContent = 'The NAS and the home network (' + response.lan.subnet + ')';
                    }

                    loaded = true;
                }

                part('log').textContent = response.log.length ? response.log.join('\n') : 'Nothing logged';
            });
        }

        // Keep the page current (the devices' connections), until the dashboard removes it
        <?php manage_timer_script(); ?>

        // Now, rather than at the next 15-second refresh: the devices' connections as they are
        button('refresh').addEventListener('click', function () {
            let refreshButton = button('refresh');

            refreshButton.classList.add('wg-spin');
            refreshButton.disabled = true;

            refresh().then(function () {
                setTimeout(function () {
                    refreshButton.classList.remove('wg-spin');

                    refreshButton.disabled = false;
                }, 400);
            });
        });

        button('restart').addEventListener('click', function () {
            act('restart', { confirm: 1 }, 'Restarting WireGuard…', 'WireGuard restarted.');
        });

        button('add-peer').addEventListener('click', function () {
            let name = part('new-peer').value.trim();

            act('add_peer', { name: name }, 'Adding ' + name + '…', name + ' added - scan its QR code or download its configuration.').then(function (response) {
                if (response) {
                    part('new-peer').value = '';

                    showConfig(response.id);
                }
            });
        });

        button('settings').addEventListener('click', function () {
            act('settings', { endpoint: part('endpoint').value, port: part('port').value, access: part('access').value,
                dns: part('dns').value, subnet: part('subnet').value }, 'Saving…', 'Saved - WireGuard restarted.');
        });

        refresh();
    })();
    </script>
</div>
