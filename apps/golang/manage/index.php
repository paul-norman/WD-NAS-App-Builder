<?php
// Go's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('golang');
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="golang-manage">
	<?php manage_styles('golang-manage'); ?>

	<h2>Go</h2>
	<table>
		<tr><td>Go</td><td data-pg="version">…</td></tr>
		<tr><td>Telemetry</td><td><span data-pg="telemetry">…</span> <button type="button" data-pg-action="telemetry" hidden>Turn off</button></td></tr>
	</table>
	<p class="mg-note"><code>go</code> and <code>gofmt</code> can be used over SSH. Go's telemetry is turned off when the app is
		installed; it only comes back on if it's turned on again (e.g. <code>go telemetry on</code>).</p>

	<h3>Test server</h3>
	<p>A small example server on port <code>30289</code>, showing that Go works on the NAS: <span data-pg="server">…</span></p>
	<p><a class="mg-button" data-pg="link" href="#" target="_blank" rel="noopener">Open the test server</a>
		<button type="button" data-pg-action="restart">Restart it</button></p>

	<p data-pg="message"></p>

	<script>
	// Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
	(function () {
		var root = document.getElementById('golang-manage');
		var api = '/apps/golang/api.php';
		var csrf = <?php echo json_encode(manage_csrf_token('golang')); ?>;

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
				part('version').textContent = d.version || 'not found';
				part('telemetry').textContent = d.telemetry || 'unknown';
				part('telemetry').className = d.telemetry === 'off' ? 'mg-ok' : 'mg-bad';
				button('telemetry').hidden = d.telemetry === 'off';
				var server = part('server');
				server.textContent = d.test_server;
				server.className = d.test_server === 'running' ? 'mg-ok' : 'mg-bad';
			});
		}

		part('link').href = 'http://' + window.location.hostname + ':30289/';

		button('restart').addEventListener('click', function () {
			say('Restarting the test server…', true);
			call('restart', { confirm: 1 }).then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				say('The test server restarted.', true);
				setTimeout(refresh, 1000);
			});
		});

		button('telemetry').addEventListener('click', function () {
			call('telemetry_off', { confirm: 1 }).then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				say('Telemetry is off.', true);
				refresh();
			});
		});

		refresh();
	})();
	</script>
</div>
