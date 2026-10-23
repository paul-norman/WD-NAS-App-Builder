<?php
// Node Exporter's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('node_exporter');
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="node_exporter-manage">
	<?php manage_styles('node_exporter-manage'); ?>

	<h2>Node Exporter</h2>
	<table>
		<tr><td>Status</td><td data-ne="status">…</td></tr>
		<tr><td>Version</td><td data-ne="version">-</td></tr>
		<tr><td>Metrics</td><td><code data-ne="url">-</code> <button type="button" data-ne-action="copy-url">Copy</button></td></tr>
		<tr><td>WD storage metrics</td><td data-ne="wd">…</td></tr>
		<tr><td>Storage health</td><td data-ne="health">-</td></tr>
	</table>
	<p><a class="mg-button" data-ne="link" href="#" target="_blank" rel="noopener">Open metrics</a>
		<button type="button" data-ne-action="restart">Restart Node Exporter</button></p>

	<h3>Settings</h3>
	<p><label>Port <input type="number" data-ne="port" min="1024" max="65535" style="width: 7em"></label>
		<label><input type="checkbox" data-ne="auth"> Require a password to read the metrics</label>
		<button type="button" data-ne-action="save">Save</button></p>
	<p data-ne="first-password" hidden><input type="text" data-ne="auth-password" placeholder="Password (leave empty to generate one)"
		autocomplete="off" spellcheck="false"> <span class="mg-note">for the user name <code>prometheus</code> - shown below once saved</span></p>
	<p class="mg-note">Node Exporter restarts. Without a password, anyone on the local network can read the metrics (they
		show the NAS's activity, not files or settings).</p>
	<div data-ne="auth-section" hidden>
		<p>User name: <code data-ne="user">prometheus</code>, password: <code data-ne="password">••••••••••••</code>
			<button type="button" data-ne-action="show">Show</button> <button type="button" data-ne-action="copy">Copy</button></p>
		<p><input type="text" data-ne="new" placeholder="New password (leave empty to generate one)" autocomplete="off" spellcheck="false">
			<button type="button" data-ne-action="set">Change password</button></p>
		<p class="mg-note">The new password takes effect immediately. Passwords are 12-128 characters: letters, digits and . _ ~ -</p>
	</div>

	<h3>Storage (as WD sees it)</h3>
	<table data-ne="disks" style="margin-bottom: 1rem"></table>
	<table data-ne="raids" style="margin-bottom: 1rem"></table>
	<table data-ne="volumes"></table>

	<h3>Prometheus and Grafana</h3>
	<p>Add the NAS to Prometheus's <code>prometheus.yml</code>
		<button type="button" data-ne-action="copy-config">Copy</button></p>
	<pre data-ne="config"></pre>
	<p class="mg-note">In Grafana, the "Node Exporter Full" dashboard (ID 1860) shows the system metrics; WD's storage
		metrics all start with <code>wd_</code> (e.g. <code>wd_health</code>, <code>wd_disk_temperature_celsius</code>,
		<code>wd_raid_disks</code>).</p>

	<details class="mg-section" data-ne="log-section" hidden>
		<summary>Node Exporter's latest warnings</summary>
		<pre data-ne="log"></pre>
	</details>

	<p data-ne="message"></p>

	<script>
	// Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
	(function () {
		var root = document.getElementById('node_exporter-manage');
		var api = '/apps/node_exporter/api.php';
		var csrf = <?php echo json_encode(manage_csrf_token('node_exporter')); ?>;
		<?php manage_secret_script(); ?>
		var healths = [['Healthy', 'mg-ok'], ['Degraded', 'mg-bad'], ['Critical', 'mg-bad']];
		var loaded = false;
		var savedAuth = false;

		function part(name) { return root.querySelector('[data-ne="' + name + '"]'); }
		function button(name) { return root.querySelector('[data-ne-action="' + name + '"]'); }

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

		function bytes(n) {
			var units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
			var i = 0;
			while (n >= 1000 && i < units.length - 1) { n /= 1000; i++; }
			return (i ? n.toFixed(1) : n) + ' ' + units[i];
		}

		// Fills a table with a header row and rows of text ({text, className} for a coloured cell)
		function fillTable(table, head, rows, empty) {
			table.textContent = '';
			if (!rows.length) {
				table.insertRow().insertCell().textContent = empty;
				return;
			}
			var header = table.insertRow();
			head.forEach(function (title) {
				var cell = header.insertCell();
				cell.textContent = title;
				cell.style.fontWeight = 'bold';
			});
			rows.forEach(function (values) {
				var row = table.insertRow();
				values.forEach(function (value) {
					var cell = row.insertCell();
					if (value && typeof value === 'object') {
						cell.textContent = value.text;
						cell.className = value.className;
					} else {
						cell.textContent = value;
					}
				});
			});
		}

		function config(d) {
			var lines = ['scrape_configs:', '  - job_name: wd-nas', '    static_configs:',
				'      - targets: [\'' + window.location.hostname + ':' + d.port + '\']'];
			if (d.auth) {
				lines.push('    basic_auth:', '      username: ' + d.user, '      password: \'<the password above>\'');
			}
			return lines.join('\n');
		}

		function refresh() {
			return call('status').then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				var status = part('status');
				status.textContent = !d.running ? 'Stopped' : (d.answering ? 'Running' : 'Starting… (or port ' + d.port + ' is in use)');
				status.className = d.running && d.answering ? 'mg-ok' : 'mg-bad';
				part('version').textContent = d.version || '-';
				var url = 'http://' + window.location.hostname + ':' + d.port + '/metrics';
				part('url').textContent = url;
				part('link').href = url;
				part('user').textContent = d.user;
				part('auth-section').hidden = !d.auth;
				savedAuth = d.auth;
				part('config').textContent = config(d);
				// The settings are only filled in once, so a refresh doesn't undo changes being made
				if (!loaded) {
					part('port').value = d.port;
					part('auth').checked = d.auth;
					loaded = true;
				}
				showFirstPassword();

				var wd = part('wd');
				wd.textContent = !d.wd_running ? 'Not running' : (!d.wd_collected ? 'WD\'s records could not be read' :
					'Updated ' + d.wd_age + ' seconds ago');
				wd.className = d.wd_running && d.wd_collected ? 'mg-ok' : 'mg-bad';
				var health = d.health === null ? ['-', ''] : healths[d.health];
				part('health').textContent = health[0];
				part('health').className = health[1];

				fillTable(part('disks'), ['Bay', 'Disk', 'Model', 'Temperature', 'State', 'SMART'], d.disks.map(function (disk) {
					var state = disk.failed ? { text: 'failed', className: 'mg-bad' } :
						(!disk.healthy || disk.over_temperature ? { text: disk.over_temperature ? 'too hot' : 'unhealthy', className: 'mg-bad' } :
						{ text: disk.sleeping ? 'healthy (asleep)' : 'healthy', className: 'mg-ok' });
					// The disk's own SMART assessment, and its problem sectors (reallocated, pending, uncorrectable)
					var smart = disk.smart_healthy === undefined ? { text: 'not read yet', className: 'mg-note' } :
						(!disk.smart_healthy ? { text: 'failed', className: 'mg-bad' } : (disk.bad_sectors ?
						{ text: 'passed, ' + disk.bad_sectors + ' problem sector' + (disk.bad_sectors === 1 ? '' : 's'), className: 'mg-bad' } :
						{ text: 'passed', className: 'mg-ok' }));
					return [disk.bay, disk.disk, disk.info || '', disk.temperature_celsius !== undefined ? disk.temperature_celsius + ' °C' : '-', state, smart];
				}), 'No disks found');
				fillTable(part('raids'), ['RAID', 'Level', 'Disks', 'State'], d.raids.filter(function (raid) { return !raid.system; }).map(function (raid) {
					var disks = raid.disks_working + ' of ' + raid.disks_total + ' working';
					if (raid.disks_failed) { disks += ', ' + raid.disks_failed + ' failed'; }
					if (raid.disks_rebuilding) { disks += ', ' + raid.disks_rebuilding + ' rebuilding'; }
					return [raid.raid, (raid.level || '').toUpperCase(), disks, { text: raid.state, className: raid.state === 'clean' ? 'mg-ok' : 'mg-bad' }];
				}), 'No RAID arrays (or JBOD)');
				fillTable(part('volumes'), ['Volume', 'Mounted at', 'Used', 'State'], d.volumes.map(function (volume) {
					var used = volume.size_bytes ? bytes(volume.used_bytes) + ' of ' + bytes(volume.size_bytes) +
						' (' + Math.round(100 * volume.used_bytes / volume.size_bytes) + '%)' : '-';
					return [volume.volume, volume.info || '', used, volume.mounted ? { text: 'mounted', className: 'mg-ok' } :
						{ text: volume.unlocked ? 'not mounted' : 'locked', className: 'mg-bad' }];
				}), 'No volumes found');

				part('log-section').hidden = !d.log.length;
				part('log').textContent = d.log.join('\n');
			});
		}

		// Keep the page current, until the dashboard removes it
		var timer = setInterval(function () {
			if (!document.body.contains(root)) { clearInterval(timer); return; }
			refresh();
		}, 15000);

		// Ticking "Require a password" (while it isn't on yet) asks for the password, or generates one when left empty
		function showFirstPassword() {
			part('first-password').hidden = !part('auth').checked || savedAuth;
		}
		part('auth').addEventListener('change', showFirstPassword);

		button('copy-url').addEventListener('click', function () { mgCopy(part('url').textContent); });
		button('copy-config').addEventListener('click', function () { mgCopy(part('config').textContent); });

		button('restart').addEventListener('click', function () {
			say('Restarting Node Exporter…', true);
			call('restart', { confirm: 1 }).then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				say('Node Exporter restarted.', true);
				setTimeout(refresh, 2000);
			});
		});

		button('save').addEventListener('click', function () {
			say('Saving…', true);
			var password = part('first-password').hidden ? '' : part('auth-password').value;
			call('settings', { port: part('port').value, auth: part('auth').checked ? 1 : 0, password: password }).then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				part('auth-password').value = '';
				secret.reset();
				say('Saved - Node Exporter restarted. The Prometheus app follows by itself; update any other Prometheus to match.', true);
				setTimeout(refresh, 2000);
			});
		});

		// The password: Show / Hide and Copy (fetched when first needed)
		var secret = mgSecret(part('password'), button('show'), button('copy'), function () {
			return call('password', { show: 1 }).then(function (d) {
				if (!d.ok) { say(d.error, false); return null; }
				return d.password || '(none saved)';
			});
		});

		button('set').addEventListener('click', function () {
			var input = part('new');
			if (!window.confirm('Change the password? Any Prometheus scraping the NAS needs the new one (the Prometheus app follows by itself).')) { return; }
			call('set_password', { password: input.value }).then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				input.value = '';
				secret.set(d.password);
				say('Password changed. The Prometheus app follows by itself; update any other Prometheus to match.', true);
			});
		});

		refresh();
	})();
	</script>
</div>
