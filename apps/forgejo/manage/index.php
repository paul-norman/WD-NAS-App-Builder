<?php
// Forgejo's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('forgejo');
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="forgejo-manage">
	<?php manage_styles('forgejo-manage'); ?>

	<h2>Forgejo (Git)</h2>
	<table>
		<tr><td>Status</td><td data-fg="status">…</td></tr>
		<tr><td>Version</td><td data-fg="version">-</td></tr>
		<tr><td>Address</td><td data-fg="address">-</td></tr>
		<tr><td>Git over SSH</td><td data-fg="ssh-address">-</td></tr>
		<tr><td>Repositories</td><td data-fg="repositories">-</td></tr>
	</table>
	<p class="mg-note" data-fg="restart-note" hidden>The Nginx app's address for Forgejo has changed: restart Forgejo so that
		it uses it (for its links and clone addresses).</p>
	<p><a class="mg-button" data-fg="link" href="#" target="_blank" rel="noopener">Open Forgejo</a>
		<button type="button" data-fg-action="restart">Restart Forgejo</button></p>

	<h3>Admin user</h3>
	<p>User name <code>nas-admin</code>, password <code data-fg="password">••••••••••••</code>
		<button type="button" data-fg-action="show">Show</button> <button type="button" data-fg-action="copy">Copy</button>
		<button type="button" data-fg-action="new-password">New password</button></p>
	<p class="mg-note">Nobody can see anything without logging in, and there are no sign-ups: create your own users in
		Forgejo (Site administration → User accounts), and add your SSH keys in each user's settings.</p>
	<pre data-fg="example"></pre>

	<h3>Backups</h3>
	<p>Forgejo's own dump of everything (repositories, database, settings, attachments, LFS files) to
		<code data-fg="backup-dir">-</code>, made while it runs.</p>
	<p><label>Back up <select data-fg="backup">
			<option value="daily">daily</option>
			<option value="weekly">weekly (Sundays)</option>
			<option value="off">never</option>
		</select></label>
		<label>Keep <input type="number" data-fg="backup-keep" min="1" max="30" style="width: 5em"> backups</label></p>
	<p><button type="button" data-fg-action="backup">Back up now</button> <span data-fg="backup-running" hidden>Backing
		up…</span></p>
	<table data-fg="backups"></table>

	<h3>Settings</h3>
	<p><label><input type="checkbox" data-fg="local"> Web only through the Nginx app (HTTPS)</label><br>
		<label><input type="checkbox" data-fg="ssh"> Git over SSH (port 2222)</label></p>
	<p><button type="button" data-fg-action="settings">Save</button></p>
	<p class="mg-note">Saves the backup settings too. Forgejo restarts.</p>

	<details class="mg-section">
		<summary>Forgejo's latest warnings</summary>
		<pre data-fg="log"></pre>
	</details>

	<p data-fg="message"></p>

	<script>
	// Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
	(function () {
		var root = document.getElementById('forgejo-manage');
		var api = '/apps/forgejo/api.php';
		var csrf = <?php echo json_encode(manage_csrf_token('forgejo')); ?>;
		<?php manage_secret_script(); ?>
		var loaded = false;

		function part(name) { return root.querySelector('[data-fg="' + name + '"]'); }
		function button(name) { return root.querySelector('[data-fg-action="' + name + '"]'); }

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
			return bytes >= 1073741824 ? (bytes / 1073741824).toFixed(1) + ' GB'
				: (bytes >= 1048576 ? (bytes / 1048576).toFixed(1) + ' MB' : Math.max(1, Math.round(bytes / 1024)) + ' KB');
		}

		function fillBackups(backups) {
			var table = part('backups');
			table.textContent = '';
			if (!backups.length) {
				table.insertRow().insertCell().textContent = 'No backups yet';
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
				status.textContent = !d.running ? 'Stopped' : (d.answering ? 'Running' : 'Starting…');
				status.className = d.running && d.answering ? 'mg-ok' : 'mg-bad';
				part('version').textContent = d.version || '-';
				var base = d.base_url || '-';
				part('address').textContent = base + (d.listen === 'local' ? ' (only through the Nginx app)' : '');
				part('ssh-address').textContent = d.ssh_url || 'Off';
				part('repositories').textContent = d.repositories;
				part('link').href = d.base_url || '#';
				part('restart-note').hidden = !d.restart_needed;
				part('example').textContent = 'git clone ' + base.replace(/\/?$/, '/') + '<user>/<repository>.git'
					+ (d.ssh_url ? '\ngit clone ' + d.ssh_url + '<user>/<repository>.git' : '');
				part('backup-dir').textContent = d.backup_dir;
				part('backup-running').hidden = !d.backup_running;
				button('backup').disabled = d.backup_running;
				fillBackups(d.backups);
				if (!loaded) {
					part('local').checked = d.listen === 'local';
					part('ssh').checked = d.ssh;
					part('backup').value = d.backup;
					part('backup-keep').value = d.backup_keep;
					loaded = true;
				}
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
				say(done, true);
				setTimeout(refresh, 2000);
				return d;
			});
		}

		button('restart').addEventListener('click', function () {
			act('restart', { confirm: 1 }, 'Restarting Forgejo…', 'Forgejo restarted.');
		});

		// The admin password: Show / Hide and Copy (fetched when first needed)
		var password = mgSecret(part('password'), button('show'), button('copy'), function () {
			return call('password', { show: 1 }).then(function (d) { if (!d.ok) { say(d.error, false); return null; } return d.password; });
		});

		button('new-password').addEventListener('click', function () {
			if (!window.confirm('Give nas-admin a new password? It\'s logged out of Forgejo, and needs the new one to log in again.')) { return; }
			act('new_password', { confirm: 1 }, 'Setting a new password…', 'New password in use.').then(function (d) { if (d) { password.set(d.password); } });
		});

		button('backup').addEventListener('click', function () {
			act('backup', { confirm: 1 }, 'Starting the backup…', 'Backing up - it shows in the list when done.');
		});

		button('settings').addEventListener('click', function () {
			act('settings', { listen: part('local').checked ? 'local' : 'all', ssh: part('ssh').checked ? 1 : 0,
				backup: part('backup').value, backup_keep: part('backup-keep').value }, 'Saving…', 'Saved - Forgejo restarted.');
		});

		refresh();
	})();
	</script>
</div>
