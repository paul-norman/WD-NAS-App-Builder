<?php
// Node.js's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('nodejs');
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="nodejs-manage">
	<?php manage_styles('nodejs-manage'); ?>

	<h2>Node.js</h2>
	<table>
		<tr><td>Node.js</td><td data-pg="node">…</td></tr>
		<tr><td>npm</td><td data-pg="npm">…</td></tr>
		<tr><td>Corepack</td><td data-pg="corepack">…</td></tr>
		<tr><td>pnpm</td><td data-pg="pnpm">…</td></tr>
	</table>
	<p class="mg-note"><code>node</code>, <code>npm</code>, <code>npx</code>, <code>pnpm</code>, <code>pnpx</code> and <code>corepack</code> can be used over SSH.</p>

	<h3>Test server</h3>
	<p>A small example server on port <code>30290</code>, showing that Node.js works on the NAS: <span data-pg="server">…</span></p>
	<p><a class="mg-button" data-pg="link" href="#" target="_blank" rel="noopener">Open the test server</a>
		<button type="button" data-pg-action="restart">Restart it</button></p>

	<p data-pg="message"></p>

	<script>
	// Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
	(function () {
		var root = document.getElementById('nodejs-manage');
		var api = '/apps/nodejs/api.php';
		var csrf = <?php echo json_encode(manage_csrf_token('nodejs')); ?>;

		function part(name) { return root.querySelector('[data-pg="' + name + '"]'); }
		function button(name) { return root.querySelector('[data-pg-action="' + name + '"]'); }

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

		function refresh() {
			return call('status').then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				['node', 'npm', 'corepack', 'pnpm'].forEach(function (tool) { part(tool).textContent = d.versions[tool] || 'not found'; });
				var server = part('server');
				server.textContent = d.test_server;
				server.className = d.test_server === 'running' ? 'mg-ok' : 'mg-bad';
			});
		}

		part('link').href = 'http://' + window.location.hostname + ':30290/';

		button('restart').addEventListener('click', function () {
			say('Restarting the test server…', true);
			call('restart', { confirm: 1 }).then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				say('The test server restarted.', true);
				setTimeout(refresh, 1000);
			});
		});

		refresh();
	})();
	</script>
</div>
