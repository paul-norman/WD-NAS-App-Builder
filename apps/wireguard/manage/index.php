<?php
// WireGuard's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
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

	<h3>Devices</h3>
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
		var root = document.getElementById('wireguard-manage');
		var api = '/apps/wireguard/api.php';
		var csrf = <?php echo json_encode(manage_csrf_token('wireguard')); ?>;
		var loaded = false;
		var shown = null;

		function part(name) { return root.querySelector('[data-wg="' + name + '"]'); }
		function button(name) { return root.querySelector('[data-wg-action="' + name + '"]'); }

		function say(text, good) {
			var message = part('message');
			message.textContent = text;
			message.className = good ? 'mg-ok' : 'mg-bad';
		}

		// API calls carry X-Requested-With (nasAdmin requires it) and this page's CSRF token
		function call(action, data) {
			var options = { method: data ? 'POST' : 'GET', credentials: 'same-origin',
				headers: { 'X-Requested-With': 'XMLHttpRequest', 'X-CSRF-Token': csrf } };
			if (data) {
				options.headers['Content-Type'] = 'application/x-www-form-urlencoded';
				options.body = new URLSearchParams(data).toString();
			}
			return fetch(api + '?action=' + action, options).then(function (response) {
				return response.json().catch(function () { return { ok: false, error: 'Unexpected response (' + response.status + ')' }; });
			});
		}

		function act(action, data, working, done) {
			say(working, true);
			return call(action, data).then(function (d) {
				if (!d.ok) { say(d.error, false); return null; }
				say(done, true);
				refresh();
				return d;
			});
		}

		function size(bytes) {
			return bytes >= 1073741824 ? (bytes / 1073741824).toFixed(1) + ' GB'
				: (bytes >= 1048576 ? (bytes / 1048576).toFixed(1) + ' MB' : Math.round(bytes / 1024) + ' KB');
		}

		function ago(seconds) {
			return seconds < 90 ? seconds + ' seconds ago' : (seconds < 5400 ? Math.round(seconds / 60) + ' minutes ago'
				: (seconds < 129600 ? Math.round(seconds / 3600) + ' hours ago' : Math.round(seconds / 86400) + ' days ago'));
		}

		// A device's state: connected (a handshake in the last 3 minutes - WireGuard renews them every 2), last seen, never
		function peerState(peer, now) {
			if (!peer.enabled) { return ['Switched off', '']; }
			if (!peer.live || !peer.live.handshake) { return ['Never connected', '']; }
			var since = now - peer.live.handshake;
			var traffic = ' - ' + size(peer.live.received) + ' in, ' + size(peer.live.sent) + ' out';
			return since < 180 ? ['Connected' + (peer.live.endpoint ? ' from ' + peer.live.endpoint : '') + traffic, 'mg-ok']
				: ['Last connected ' + ago(since) + traffic, ''];
		}

		function el(tag, text, className) {
			var node = document.createElement(tag);
			if (text) { node.textContent = text; }
			if (className) { node.className = className; }
			return node;
		}

		function fillPeers(peers, now) {
			var table = part('peers');
			table.textContent = '';
			if (!peers.length) {
				table.insertRow().insertCell().textContent = 'No devices yet';
				return;
			}
			peers.forEach(function (peer) {
				var row = table.insertRow();
				row.insertCell().textContent = peer.name;
				row.insertCell().textContent = peer.address;
				var state = peerState(peer, now);
				row.insertCell().appendChild(el('span', state[0], state[1]));
				var actions = row.insertCell();
				var view = el('button', 'Show configuration');
				var toggle = el('button', peer.enabled ? 'Switch off' : 'Switch on');
				var remove = el('button', 'Remove');
				[view, toggle, remove].forEach(function (b) { b.type = 'button'; actions.appendChild(b); actions.appendChild(document.createTextNode(' ')); });
				view.addEventListener('click', function () { showConfig(peer.id); });
				toggle.addEventListener('click', function () {
					act('switch_peer', { id: peer.id, enabled: peer.enabled ? 0 : 1 }, 'Updating…',
						peer.name + (peer.enabled ? ' switched off.' : ' switched on.'));
				});
				remove.addEventListener('click', function () {
					if (!window.confirm('Remove ' + peer.name + '? It can no longer connect (its configuration stops working).')) { return; }
					act('remove_peer', { id: peer.id }, 'Removing…', peer.name + ' removed.').then(function () {
						if (shown && shown.id === peer.id) { part('viewer').hidden = true; }
					});
				});
			});
		}

		function showConfig(id) {
			return call('peer_config', { id: id }).then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				shown = { id: id, file: d.file, config: d.config };
				part('viewer-name').textContent = d.name;
				part('config').textContent = d.config;
				part('qr').src = d.qr ? 'data:image/svg+xml;base64,' + d.qr : '';
				part('qr').hidden = !d.qr;
				part('viewer').hidden = false;
			});
		}

		button('download').addEventListener('click', function () {
			if (!shown) { return; }
			var link = document.createElement('a');
			link.href = URL.createObjectURL(new Blob([shown.config], { type: 'text/plain' }));
			link.download = shown.file;
			document.body.appendChild(link);
			link.click();
			setTimeout(function () { URL.revokeObjectURL(link.href); link.remove(); }, 1000);
		});

		button('close').addEventListener('click', function () { part('viewer').hidden = true; shown = null; });

		function refresh() {
			return call('status').then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				var status = part('status');
				status.textContent = d.running ? 'Running' : 'Stopped';
				status.className = d.running ? 'mg-ok' : 'mg-bad';
				part('version').textContent = d.version ? 'wireguard-go ' + d.version + (d.tools_version ? ', wg ' + d.tools_version : '') : '-';
				part('connect').textContent = d.endpoint ? d.endpoint + ':' + d.port + ' (UDP)' : 'not set yet';
				part('nas-address').textContent = d.address + (d.access !== 'nas' && d.lan.address ? ' - and ' + d.lan.address + ' as at home' : '');
				part('endpoint-note').hidden = !!d.endpoint;
				part('router-target').textContent = d.lan.address ? d.lan.address : 'its address';
				fillPeers(d.peers, d.now);
				if (!loaded) {
					part('endpoint').value = d.endpoint;
					part('endpoint').placeholder = d.suggested_endpoint || 'home.example.com';
					part('port').value = d.port;
					part('access').value = d.access;
					part('dns').value = d.dns;
					part('dns').placeholder = d.default_dns ? d.default_dns + ' (the NAS\'s)' : 'e.g. 192.168.1.1';
					part('subnet').value = d.subnet;
					if (d.lan.subnet) {
						part('access').querySelector('option[value="lan"]').textContent = 'The NAS and the home network (' + d.lan.subnet + ')';
					}
					loaded = true;
				}
				part('log').textContent = d.log.length ? d.log.join('\n') : 'Nothing logged';
			});
		}

		// Keep the page current (the devices' connections), until the dashboard removes it
		var timer = setInterval(function () {
			if (!document.body.contains(root)) { clearInterval(timer); return; }
			refresh();
		}, 15000);

		button('restart').addEventListener('click', function () {
			act('restart', { confirm: 1 }, 'Restarting WireGuard…', 'WireGuard restarted.');
		});

		button('add-peer').addEventListener('click', function () {
			var name = part('new-peer').value.trim();
			act('add_peer', { name: name }, 'Adding ' + name + '…', name + ' added - scan its QR code or download its configuration.').then(function (d) {
				if (d) { part('new-peer').value = ''; showConfig(d.id); }
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
