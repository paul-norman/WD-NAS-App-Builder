<?php
// The logs app's (Loki + Vector) management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('loki');
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="loki-manage">
	<?php manage_styles('loki-manage'); ?>

	<h2>Loki</h2>
	<table>
		<tr><td>Loki</td><td data-lk="loki">…</td></tr>
		<tr><td>Vector</td><td data-lk="vector">…</td></tr>
		<tr><td>Stored</td><td data-lk="storage">-</td></tr>
		<tr><td>Viewing</td><td data-lk="viewing">-</td></tr>
	</table>
	<p><button type="button" data-lk-action="restart">Restart Loki and Vector</button></p>

	<h3>Collected in the last 24 hours</h3>
	<table data-lk="logs"></table>

	<h3>Settings</h3>
	<p><label>Keep <input type="number" data-lk="retention" min="1" max="3650" style="width: 6em"> days of logs</label></p>
	<p><label><input type="checkbox" data-lk="system"> The NAS's own logs (/var/log: system, kernel, SSH, Samba, WD's services)</label><br>
		<label><input type="checkbox" data-lk="apps"> The apps' logs (Nas_Prog/_&lt;app&gt;/*.log, the Nginx app's, the app scripts')</label><br>
		<label><input type="checkbox" data-lk="docker"> Docker containers' output <span class="mg-note" data-lk="docker-note"></span></label></p>
	<p><button type="button" data-lk-action="settings">Save</button>
		<span class="mg-note">Loki and Vector restart. Older logs are deleted as they expire.</span></p>

	<details class="mg-section">
		<summary>Loki's and Vector's latest warnings</summary>
		<pre data-lk="log"></pre>
	</details>

	<p data-lk="message"></p>

	<script>
	// Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
	(function () {
		var root = document.getElementById('loki-manage');
		var api = '/apps/loki/api.php';
		var csrf = <?php echo json_encode(manage_csrf_token('loki')); ?>;
		var sources = { system: 'NAS', app: 'App', docker: 'Docker' };
		var loaded = false;

		function part(name) { return root.querySelector('[data-lk="' + name + '"]'); }
		function button(name) { return root.querySelector('[data-lk-action="' + name + '"]'); }

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

		// The logs collected: names come from Loki, so they are only ever set as text
		function fillLogs(logs, ready) {
			var table = part('logs');
			table.textContent = '';
			if (!logs.length) {
				table.insertRow().insertCell().textContent = ready ? 'Nothing yet (the first lines arrive within a minute)' : '-';
				return;
			}
			var head = table.insertRow();
			['Source', 'Log', 'Lines'].forEach(function (text) {
				var cell = head.insertCell();
				cell.textContent = text;
				cell.style.fontWeight = 'bold';
			});
			logs.forEach(function (log) {
				var row = table.insertRow();
				row.insertCell().textContent = sources[log.source] || log.source;
				row.insertCell().textContent = log.app;
				row.insertCell().textContent = log.lines.toLocaleString();
			});
		}

		function refresh() {
			return call('status').then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				var loki = part('loki');
				loki.textContent = (!d.loki_running ? 'Stopped' : (d.loki_ready ? 'Running' : 'Starting… ' + (d.loki_state || ''))) +
					(d.loki_version ? ' - ' + d.loki_version + ', on the NAS itself only (127.0.0.1:3100)' : '');
				loki.className = d.loki_running && d.loki_ready ? 'mg-ok' : 'mg-bad';
				var vector = part('vector');
				vector.textContent = (d.vector_running ? 'Running' : 'Stopped') + (d.vector_version ? ' - ' + d.vector_version + ', reading the logs and sending them to Loki' : '');
				vector.className = d.vector_running ? 'mg-ok' : 'mg-bad';
				part('storage').textContent = size(d.storage) + ', keeping ' + d.retention_days + ' days';
				part('viewing').textContent = d.grafana ? 'In Grafana: Dashboards → NAS → NAS logs, or Explore with the Loki data source' :
					'Install the Grafana app to search and view the logs';
				part('docker-note').textContent = d.docker_running ? '' : '(Docker isn\'t running - restart this app after starting it)';

				// The settings are only filled in once, so a refresh doesn't undo changes being made
				if (!loaded) {
					part('retention').value = d.retention_days;
					part('system').checked = d.system_logs;
					part('apps').checked = d.app_logs;
					part('docker').checked = d.docker_logs;
					loaded = true;
				}
				fillLogs(d.logs, d.loki_ready);
				var log = [].concat(d.loki_log.map(function (line) { return 'loki: ' + line; }), d.vector_log.map(function (line) { return 'vector: ' + line; }));
				part('log').textContent = log.length ? log.join('\n') : 'Nothing logged';
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
				if (!d.ok) { say(d.error, false); return; }
				say(done, true);
				setTimeout(refresh, 2000);
			});
		}

		button('restart').addEventListener('click', function () {
			act('restart', { confirm: 1 }, 'Restarting…', 'Loki and Vector restarted.');
		});

		button('settings').addEventListener('click', function () {
			act('settings', { retention_days: part('retention').value, system_logs: part('system').checked ? 1 : 0,
				app_logs: part('apps').checked ? 1 : 0, docker_logs: part('docker').checked ? 1 : 0 }, 'Saving…', 'Saved - Loki and Vector restarted.');
		});

		refresh();
	})();
	</script>
</div>
