<?php
// Prometheus' management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('prometheus');
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="prometheus-manage">
	<?php manage_styles('prometheus-manage'); ?>

	<h2>Prometheus</h2>
	<table>
		<tr><td>Status</td><td data-pm="status">…</td></tr>
		<tr><td>Version</td><td data-pm="version">-</td></tr>
		<tr><td>Address</td><td data-pm="address">-</td></tr>
		<tr><td>Stored</td><td data-pm="storage">-</td></tr>
		<tr><td>Configuration</td><td data-pm="config">-</td></tr>
	</table>
	<p><a class="mg-button" data-pm="link" href="#" target="_blank" rel="noopener" hidden>Open Prometheus</a>
		<button type="button" data-pm-action="reload">Reload the configuration</button>
		<button type="button" data-pm-action="restart">Restart Prometheus</button></p>

	<h3>Targets</h3>
	<table data-pm="targets"></table>
	<p class="mg-note">Prometheus scrapes itself and the Node Exporter app (following its port and password) every 30
		seconds. Your own scrape jobs go in <code data-pm="scrape-path">scrape.d</code> (*.yml, see its README.txt) and rules
		in <code data-pm="rules-path">rules.d</code> - then reload. <span data-pm="own"></span></p>

	<h3>Settings</h3>
	<p><label>Keep <input type="number" data-pm="retention" min="1" max="3650" style="width: 6em"> days of history</label>
		<label><input type="checkbox" data-pm="all"> Reachable on port 9090 from the local network</label>
		<button type="button" data-pm-action="settings">Save</button></p>
	<p class="mg-note">Prometheus restarts. It has no login of its own, so it's only reachable on the NAS itself unless this
		is ticked (Grafana reaches it there). Older history is deleted as it expires.</p>

	<details class="mg-section">
		<summary>Prometheus' latest warnings</summary>
		<pre data-pm="log"></pre>
	</details>

	<p data-pm="message"></p>

	<script>
	// Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
	(function () {
		var root = document.getElementById('prometheus-manage');
		var api = '/apps/prometheus/api.php';
		var csrf = <?php echo json_encode(manage_csrf_token('prometheus')); ?>;
		var loaded = false;

		function part(name) { return root.querySelector('[data-pm="' + name + '"]'); }
		function button(name) { return root.querySelector('[data-pm-action="' + name + '"]'); }

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

		function size(bytes) {
			return bytes >= 1073741824 ? (bytes / 1073741824).toFixed(1) + ' GB' : (bytes / 1048576).toFixed(1) + ' MB';
		}

		// Targets: names and errors come from Prometheus, so they are only ever set as text
		function fillTargets(targets, answering) {
			var table = part('targets');
			table.textContent = '';
			if (!targets.length) {
				table.insertRow().insertCell().textContent = answering ? 'No targets' : '-';
				return;
			}
			var head = table.insertRow();
			['Job', 'Instance', 'Address', 'State'].forEach(function (text) {
				var cell = head.insertCell();
				cell.textContent = text;
				cell.style.fontWeight = 'bold';
			});
			targets.forEach(function (target) {
				var row = table.insertRow();
				row.insertCell().textContent = target.job;
				row.insertCell().textContent = target.instance;
				row.insertCell().textContent = target.url;
				var state = row.insertCell();
				state.textContent = target.health === 'up' ? 'up' : (target.health || 'unknown') + (target.error ? ': ' + target.error : '');
				state.className = target.health === 'up' ? 'mg-ok' : (target.health === 'unknown' ? 'mg-note' : 'mg-bad');
			});
		}

		function refresh() {
			return call('status').then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				var status = part('status');
				status.textContent = !d.running ? 'Stopped' : (d.answering ? 'Running' : 'Starting… (replaying its recent data)');
				status.className = d.running && d.answering ? 'mg-ok' : 'mg-bad';
				part('version').textContent = d.version || '-';
				var url = 'http://' + window.location.hostname + ':9090/';
				part('address').textContent = d.listen === 'all' ? url : '127.0.0.1:9090 (on the NAS itself only)';
				part('link').hidden = d.listen !== 'all';
				part('link').href = url;
				part('storage').textContent = size(d.storage) + ', keeping ' + d.retention_days + ' days';
				var config = part('config');
				config.textContent = d.config_ok === null ? '-' : (d.config_ok ? 'loaded' : 'the last reload failed - Prometheus is using the previous configuration (see the warnings below)');
				config.className = d.config_ok === false ? 'mg-bad' : '';
				part('scrape-path').textContent = d.data_path + '/scrape.d';
				part('rules-path').textContent = d.data_path + '/rules.d';
				part('own').textContent = d.own_files.length ? 'Your files: ' + d.own_files.join(', ') + '.' : '';

				// The settings are only filled in once, so a refresh doesn't undo changes being made
				if (!loaded) {
					part('retention').value = d.retention_days;
					part('all').checked = d.listen === 'all';
					loaded = true;
				}
				fillTargets(d.targets, d.answering);
				part('log').textContent = d.log.length ? d.log.join('\n') : 'Nothing logged';
			});
		}

		// Keep the page current, until the dashboard removes it
		var timer = setInterval(function () {
			if (!document.body.contains(root)) { clearInterval(timer); return; }
			refresh();
		}, 15000);

		function act(action, data, working, done) {
			say(working, true);
			return call(action, data).then(function (d) {
				if (!d.ok) { say(d.error, false); refresh(); return; }
				say(done, true);
				setTimeout(refresh, 1000);
			});
		}

		button('reload').addEventListener('click', function () {
			act('reload', { confirm: 1 }, 'Reloading…', 'Configuration reloaded.');
		});

		button('restart').addEventListener('click', function () {
			act('restart', { confirm: 1 }, 'Restarting Prometheus…', 'Prometheus restarted.');
		});

		button('settings').addEventListener('click', function () {
			act('settings', { retention_days: part('retention').value, listen: part('all').checked ? 'all' : 'local' },
				'Saving…', 'Saved - Prometheus restarted.');
		});

		refresh();
	})();
	</script>
</div>
