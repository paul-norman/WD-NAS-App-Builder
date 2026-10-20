<?php
// Syncthing's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('syncthing');
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="syncthing-manage">
	<?php manage_styles('syncthing-manage'); ?>

	<h2>Syncthing</h2>
	<table>
		<tr><td>Status</td><td data-st="status">…</td></tr>
		<tr><td>Version</td><td data-st="version">-</td></tr>
		<tr><td>NAS device ID</td><td><code data-st="device-id">-</code></td></tr>
		<tr><td>Usage reporting</td><td><span data-st="usage">-</span> <button type="button" data-st-action="usage-off" hidden>Turn off</button></td></tr>
	</table>
	<p class="mg-note">Other devices add the NAS with its device ID.</p>
	<p><a class="mg-button" data-st="link" href="#" target="_blank" rel="noopener">Open Syncthing</a>
		<button type="button" data-st-action="restart">Restart Syncthing</button></p>

	<h3>Folders</h3>
	<table data-st="folders"></table>

	<h3>Devices</h3>
	<table data-st="devices"></table>

	<h3>Logging in</h3>
	<p>Log in to Syncthing as <code data-st="user">admin</code> with: <code data-st="password">••••••••••••</code>
		<button type="button" data-st-action="show">Show</button> <button type="button" data-st-action="copy">Copy</button></p>
	<p><input type="text" data-st="new" placeholder="New password (leave empty to generate one)" autocomplete="off" spellcheck="false">
		<button type="button" data-st-action="set">Change password</button></p>
	<p class="mg-note">The new password takes effect immediately. Passwords are 12-128 characters: letters, digits and . _ ~ -
		(a password changed in Syncthing's own settings isn't shown here).</p>

	<p data-st="message"></p>

	<script>
	// Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
	(function () {
		var root = document.getElementById('syncthing-manage');
		var api = '/apps/syncthing/api.php';
		var csrf = <?php echo json_encode(manage_csrf_token('syncthing')); ?>;
		<?php manage_secret_script(); ?>
		var states = { idle: 'up to date', scanning: 'scanning', 'scan-waiting': 'waiting to scan', syncing: 'syncing',
			'sync-waiting': 'waiting to sync', 'sync-preparing': 'preparing to sync', cleaning: 'cleaning up', error: 'error', paused: 'paused' };

		function part(name) { return root.querySelector('[data-st="' + name + '"]'); }
		function button(name) { return root.querySelector('[data-st-action="' + name + '"]'); }

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

		// Fills a table with rows of text (folder and device names come from Syncthing, so they are only ever set as text)
		function fillTable(table, rows, empty) {
			table.textContent = '';
			if (!rows.length) {
				table.insertRow().insertCell().textContent = empty;
				return;
			}
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

		function refresh() {
			return call('status').then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				var status = part('status');
				status.textContent = !d.running ? 'Stopped' : (d.answering ? 'Running' : 'Starting…');
				status.className = d.running && d.answering ? 'mg-ok' : 'mg-bad';
				if (!d.answering) { return; }
				part('version').textContent = d.version || '-';
				part('device-id').textContent = d.device_id;
				part('user').textContent = d.gui_user || 'admin';

				var usage = part('usage');
				usage.textContent = d.usage_reporting > 0 ? 'on (anonymous statistics are sent to the Syncthing project)' :
					(d.usage_reporting < 0 ? 'off' : 'not decided yet (Syncthing asks when its GUI is opened)');
				usage.className = d.usage_reporting > 0 ? 'mg-bad' : (d.usage_reporting < 0 ? 'mg-ok' : '');
				button('usage-off').hidden = d.usage_reporting < 0;

				fillTable(part('folders'), d.folders.map(function (f) {
					var state = states[f.state] || f.state;
					if (f.need > 0) { state += ' (' + f.need + ' files to go)'; }
					return [f.label, f.path, { text: state, className: f.state === 'idle' ? 'mg-ok' : (f.state === 'error' ? 'mg-bad' : 'mg-note') }];
				}), 'No folders yet - add them in Syncthing, using their full path on the NAS (e.g. /mnt/HD/HD_a2/<share>/<folder>)');
				fillTable(part('devices'), d.devices.map(function (dev) {
					return [dev.name, dev.paused ? { text: 'paused', className: 'mg-note' } :
						{ text: dev.connected ? 'connected' : 'not connected', className: dev.connected ? 'mg-ok' : 'mg-note' }];
				}), 'No other devices yet');
			});
		}

		part('link').href = 'http://' + window.location.hostname + ':8384/';

		// Keep the page current (e.g. while folders sync), until the dashboard removes it
		var timer = setInterval(function () {
			if (!document.body.contains(root)) { clearInterval(timer); return; }
			refresh();
		}, 10000);

		button('restart').addEventListener('click', function () {
			if (!window.confirm('Restart Syncthing? Syncing pauses until it is back.')) { return; }
			say('Restarting Syncthing…', true);
			call('restart', { confirm: 1 }).then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				say('Syncthing restarted.', true);
				setTimeout(refresh, 3000);
			});
		});

		button('usage-off').addEventListener('click', function () {
			call('usage_reporting_off', { confirm: 1 }).then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				say('Usage reporting is off.', true);
				refresh();
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
			if (!window.confirm('Change the Syncthing password? You will need the new one to log in.')) { return; }
			call('set_password', { password: input.value }).then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				input.value = '';
				secret.set(d.password);
				say('Password changed - use it to log in to Syncthing.', true);
			});
		});

		refresh();
	})();
	</script>
</div>
