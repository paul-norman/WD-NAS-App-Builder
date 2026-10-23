<?php
// Grafana's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('grafana');
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="grafana-manage">
	<?php manage_styles('grafana-manage'); ?>

	<h2>Grafana</h2>
	<table>
		<tr><td>Status</td><td data-gf="status">…</td></tr>
		<tr><td>Version</td><td data-gf="version">-</td></tr>
		<tr><td>Address</td><td data-gf="address">-</td></tr>
		<tr><td>Data source</td><td data-gf="datasource">-</td></tr>
	</table>
	<p><a class="mg-button" data-gf="link" href="#" target="_blank" rel="noopener">Open Grafana</a>
		<button type="button" data-gf-action="restart">Restart Grafana</button></p>

	<h3>Admin account</h3>
	<p>Log in as <code>admin</code> with: <code data-gf="password">••••••••••••</code>
		<button type="button" data-gf-action="show">Show</button> <button type="button" data-gf-action="copy">Copy</button>
		<button type="button" data-gf-action="reset">Reset the password</button></p>
	<p class="mg-note">The first password is generated when Grafana's database is created. A password changed in Grafana
		itself isn't shown here; resetting sets a new random one.</p>

	<h3>Access</h3>
	<p><label><input type="checkbox" data-gf="local"> Only through the Nginx app (HTTPS)</label>
		<button type="button" data-gf-action="listen">Save</button></p>
	<p class="mg-note">Otherwise Grafana is also reachable on port 3000 from the local network (over plain HTTP). Grafana
		restarts.</p>

	<h3>Backups</h3>
	<p><label>Folder <input type="text" data-gf="backup-dir" size="40" spellcheck="false"></label>
		<label>Keep <input type="number" data-gf="backup-keep" min="1" max="365" style="width: 5em"> backups</label>
		<button type="button" data-gf-action="backup-settings">Save</button></p>
	<p><button type="button" data-gf-action="backup">Back up now</button>
		<span class="mg-note">Every day at 02:45: Grafana's database (copied safely while it runs), with its dashboards,
			users, data sources, alerts and settings, readable by root only.</span></p>
	<table data-gf="backups"></table>

	<details class="mg-section">
		<summary>Grafana's latest warnings</summary>
		<pre data-gf="log"></pre>
	</details>

	<p data-gf="message"></p>

	<script>
	// Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
	(function () {
		var root = document.getElementById('grafana-manage');
		var api = '/apps/grafana/api.php';
		var csrf = <?php echo json_encode(manage_csrf_token('grafana')); ?>;
		<?php manage_secret_script(); ?>
		var siteStates = { no_nginx: 'the Nginx app isn\'t set up', no_domain: 'set a domain in the Nginx app for HTTPS',
			off: 'switched off in the Nginx app' };
		var loaded = false;

		function part(name) { return root.querySelector('[data-gf="' + name + '"]'); }
		function button(name) { return root.querySelector('[data-gf-action="' + name + '"]'); }

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
			return bytes >= 1048576 ? (bytes / 1048576).toFixed(1) + ' MB' : Math.max(1, Math.round(bytes / 1024)) + ' KB';
		}

		function fillBackups(backups, hasDb) {
			var table = part('backups');
			table.textContent = '';
			if (!backups.length) {
				table.insertRow().insertCell().textContent = hasDb ? 'No backups yet' : 'No backups yet (there is nothing to back up until Grafana has started once)';
				return;
			}
			backups.forEach(function (backup) {
				var row = table.insertRow();
				row.insertCell().textContent = backup.name;
				row.insertCell().textContent = new Date(backup.time * 1000).toLocaleString();
				row.insertCell().textContent = size(backup.size);
			});
		}

		function refresh() {
			return call('status').then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				var status = part('status');
				status.textContent = !d.running ? 'Stopped' : (d.answering ? 'Running' : 'Starting… (the first start takes a minute or two)');
				status.className = d.running && d.answering ? 'mg-ok' : 'mg-bad';
				part('version').textContent = d.version || '-';

				// Its addresses: the Nginx app's (HTTPS), and port 3000 on the local network unless that's turned off
				var local = 'http://' + window.location.hostname + ':3000/';
				var addresses = [];
				if (d.site.url) { addresses.push(d.site.url); }
				if (d.listen === 'all') { addresses.push(local); }
				part('address').textContent = (addresses.join(' and ') || 'none') + (d.site.url ? '' : ' (HTTPS: ' + siteStates[d.site.state] + ')');
				part('address').className = addresses.length ? '' : 'mg-bad';
				part('link').hidden = !addresses.length;
				part('link').href = addresses[0] || '#';

				part('datasource').textContent = d.prometheus ? 'the Prometheus app (with the NAS dashboards in the "NAS" folder)' :
					'none set up - install the Prometheus app, then restart Grafana';
				part('datasource').className = d.prometheus ? '' : 'mg-bad';

				// The settings are only filled in once, so a refresh doesn't undo changes being made
				if (!loaded) {
					part('local').checked = d.listen === 'local';
					part('backup-dir').value = d.backup_dir;
					part('backup-dir').placeholder = d.backup_dir_default;
					part('backup-keep').value = d.backup_keep;
					loaded = true;
				}
				fillBackups(d.backups, d.has_db);
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
				if (!d.ok) { say(d.error, false); return null; }
				say(done || d.message, true);
				refresh();
				return d;
			});
		}

		button('restart').addEventListener('click', function () {
			act('restart', { confirm: 1 }, 'Restarting Grafana…', 'Grafana restarted.');
		});

		button('listen').addEventListener('click', function () {
			var local = part('local').checked;
			if (local && !window.confirm('Only allow access through the Nginx app? Port 3000 stops answering on the network.')) { return; }
			act('listen', { listen: local ? 'local' : 'all' }, 'Saving…', local ? 'Grafana is now only reachable through the Nginx app.' :
				'Grafana is reachable on port 3000 too.');
		});

		// The admin password: Show / Hide and Copy (fetched when first needed)
		var secret = mgSecret(part('password'), button('show'), button('copy'), function () {
			return call('password', { show: 1 }).then(function (d) {
				if (!d.ok) { say(d.error, false); return null; }
				return d.password || '(none saved)';
			});
		});

		button('reset').addEventListener('click', function () {
			if (!window.confirm('Reset the admin account\'s password to a new random one?')) { return; }
			act('reset_password', { confirm: 1 }, 'Resetting the password…', 'Password reset - log in with the new one.').then(function (d) {
				if (d) { secret.set(d.password); }
			});
		});

		button('backup-settings').addEventListener('click', function () {
			act('backup_settings', { dir: part('backup-dir').value, keep: part('backup-keep').value }, 'Saving…', 'Backup settings saved.');
		});

		button('backup').addEventListener('click', function () {
			act('backup_now', { confirm: 1 }, 'Backing up…');
		});

		refresh();
	})();
	</script>
</div>
