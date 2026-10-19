<?php
// Tailscale's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('tailscale');
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="tailscale-manage">
	<?php manage_styles('tailscale-manage'); ?>

	<h2>Tailscale</h2>
	<table>
		<tr><td>Status</td><td data-ts="state">…</td></tr>
		<tr><td>Tailnet</td><td data-ts="tailnet">-</td></tr>
		<tr><td>NAS name</td><td data-ts="name">-</td></tr>
		<tr><td>NAS addresses</td><td data-ts="ips">-</td></tr>
		<tr><td>Login server</td><td data-ts="server">-</td></tr>
		<tr><td>Version</td><td data-ts="version">-</td></tr>
	</table>

	<div data-ts="login-box" hidden>
		<h3>Log in</h3>
		<p>Add the NAS to your Tailscale network: start a login, then open the link and sign in.</p>
		<p><label>Login server <span class="mg-note">(leave empty for Tailscale's own, or enter a self-hosted
			<a href="https://headscale.net/" target="_blank" rel="noopener">Headscale</a> server)</span>:</label><br>
			<input type="text" data-ts="login-server" placeholder="e.g. https://headscale.example.com" autocomplete="off" spellcheck="false"></p>
		<p><button type="button" data-ts-action="login">Log in</button></p>
		<p data-ts="auth" hidden>Open: <a data-ts="auth-link" href="#" target="_blank" rel="noopener"></a><br>
			<span class="mg-note">This page updates by itself once the NAS is connected.</span></p>
	</div>

	<div data-ts="connected-box" hidden>
		<h3>Sharing</h3>
		<p><label><input type="checkbox" data-ts="share"> Share networks with the tailnet (subnet router):</label><br>
			<input type="text" data-ts="routes" placeholder="e.g. 192.168.1.0/24" autocomplete="off" spellcheck="false"></p>
		<p><label><input type="checkbox" data-ts="exit"> Offer the NAS as an exit node (route other devices' internet traffic through it)</label></p>
		<p><button type="button" data-ts-action="save">Save</button></p>
		<p class="mg-note">Shared networks and exit nodes must also be approved in the
			<a href="https://login.tailscale.com/admin/machines" target="_blank" rel="noopener">Tailscale admin console</a>.</p>

		<h3>Devices</h3>
		<table data-ts="peers"></table>

		<h3>Log out</h3>
		<p><button type="button" data-ts-action="logout">Log out of Tailscale</button>
			<span class="mg-note">The NAS leaves the tailnet until it logs in again.</span></p>
	</div>

	<div data-ts="privacy-box" hidden>
		<h3>Privacy</h3>
		<p><label><input type="checkbox" data-ts="upload-logs"> Send logs and diagnostics to Tailscale</label>
			<button type="button" data-ts-action="logs">Save</button><br>
			<span class="mg-note">Off by default. Tailscale's support needs them, so only turn this on when asking them for help. Saving restarts Tailscale.</span></p>
		<p class="mg-note">The NAS also keeps its own DNS servers (e.g. a Pi-hole) rather than switching to Tailscale's MagicDNS: other devices are still reachable by their Tailscale addresses.</p>
	</div>

	<p data-ts="message"></p>

	<script>
	// Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
	(function () {
		var root = document.getElementById('tailscale-manage');
		var api = '/apps/tailscale/api.php';
		var csrf = <?php echo json_encode(manage_csrf_token('tailscale')); ?>;
		var states = { Running: 'Connected', NeedsLogin: 'Logged out', NeedsMachineAuth: 'Waiting for approval in the Tailscale admin console',
			Stopped: 'Disconnected (tailscale down)', Starting: 'Starting', NoState: 'Starting' };
		var lanSubnet = '';

		function part(name) { return root.querySelector('[data-ts="' + name + '"]'); }

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

		// Device names come from the tailnet, so they are only ever set as text
		function showPeers(peers) {
			var table = part('peers');
			table.textContent = '';
			if (!peers.length) {
				table.insertRow().insertCell().textContent = 'No other devices yet';
				return;
			}
			peers.sort(function (a, b) { return (b.online - a.online) || a.name.localeCompare(b.name); });
			peers.forEach(function (peer) {
				var row = table.insertRow();
				[peer.name, peer.ip, peer.os, peer.online ? 'online' : 'offline'].forEach(function (text, i) {
					var cell = row.insertCell();
					cell.textContent = text;
					if (i === 3) { cell.className = peer.online ? 'mg-ok' : 'mg-note'; }
				});
			});
		}

		function refresh() {
			return call('status').then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				var state = part('state');
				if (!d.running) {
					state.textContent = 'Not running - enable the Tailscale app';
					state.className = 'mg-bad';
					part('login-box').hidden = part('connected-box').hidden = part('privacy-box').hidden = true;
					return;
				}
				state.textContent = states[d.state] || d.state;
				state.className = d.state === 'Running' ? 'mg-ok' : 'mg-bad';
				part('tailnet').textContent = d.tailnet || '-';
				part('name').textContent = d.name || '-';
				part('ips').textContent = d.ips.length ? d.ips.join(', ') : '-';
				part('version').textContent = d.version;
				part('server').textContent = d.login_server === d.default_server ? "Tailscale's own" : d.login_server;
				part('privacy-box').hidden = false;
				part('upload-logs').checked = d.upload_logs;
				lanSubnet = d.lan_subnet;

				part('login-box').hidden = d.state !== 'NeedsLogin';
				part('connected-box').hidden = d.state !== 'Running';
				if (d.auth_url) {
					part('auth').hidden = false;
					part('auth-link').href = d.auth_url;
					part('auth-link').textContent = d.auth_url;
				}
				if (d.state === 'Running') {
					part('share').checked = d.routes.length > 0;
					part('routes').value = d.routes.length ? d.routes.join(', ') : lanSubnet;
					part('exit').checked = d.exit_node;
					showPeers(d.peers);
				}
			});
		}

		// Keep the page current (e.g. while a login completes), until the dashboard removes it
		var timer = setInterval(function () {
			if (!document.body.contains(root)) { clearInterval(timer); return; }
			refresh();
		}, 5000);

		root.querySelector('[data-ts-action="login"]').addEventListener('click', function () {
			say('Starting the login…', true);
			call('login', { login_server: part('login-server').value }).then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				say('', true);
				refresh();
			});
		});

		root.querySelector('[data-ts-action="save"]').addEventListener('click', function () {
			var share = part('share').checked;
			call('set_options', { routes: share ? part('routes').value : '', exit_node: part('exit').checked ? 1 : '' }).then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				say('Saved - remember to approve it in the Tailscale admin console.', true);
				refresh();
			});
		});

		root.querySelector('[data-ts-action="logs"]').addEventListener('click', function () {
			say('Restarting Tailscale…', true);
			call('set_logs', { upload_logs: part('upload-logs').checked ? 1 : '' }).then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				say(d.upload_logs ? 'Logs are now sent to Tailscale.' : 'Logs are no longer sent to Tailscale.', true);
				setTimeout(refresh, 2000);
			});
		});

		root.querySelector('[data-ts-action="logout"]').addEventListener('click', function () {
			if (!window.confirm('Log the NAS out of Tailscale? It will leave your tailnet until it logs in again.')) { return; }
			call('logout', { confirm: 1 }).then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				say('Logged out.', true);
				refresh();
			});
		});

		refresh();
	})();
	</script>
</div>
