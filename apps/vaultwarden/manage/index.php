<?php
// Vaultwarden's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('vaultwarden');
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="vaultwarden-manage">
	<?php manage_styles('vaultwarden-manage'); ?>

	<h2>Vaultwarden</h2>
	<table>
		<tr><td>Status</td><td data-vw="status">…</td></tr>
		<tr><td>Version</td><td data-vw="version">-</td></tr>
		<tr><td>Address</td><td data-vw="address">-</td></tr>
	</table>
	<p class="mg-note" data-vw="restart-note" hidden>The Nginx app's address for Vaultwarden has changed: restart Vaultwarden
		so that its links (e.g. in emails) use it.</p>
	<p><a class="mg-button" data-vw="link" href="#" target="_blank" rel="noopener" hidden>Open Vaultwarden</a>
		<a class="mg-button" data-vw="admin-link" href="#" target="_blank" rel="noopener" hidden>Admin panel</a>
		<button type="button" data-vw-action="restart">Restart Vaultwarden</button></p>

	<h3>Accounts</h3>
	<p><label><input type="checkbox" data-vw="signups"> Allow new accounts to sign up</label>
		<button type="button" data-vw-action="signups">Save</button></p>
	<p class="mg-note">Turn this off once your accounts exist; others can still be invited from the admin panel (which
		needs email set up, in its SMTP settings). Vaultwarden restarts.</p>

	<h3>Admin panel</h3>
	<p>Admin token: <code data-vw="token">••••••••••••</code>
		<button type="button" data-vw-action="show">Show</button> <button type="button" data-vw-action="copy">Copy</button>
		<button type="button" data-vw-action="new-token">New token</button></p>
	<p class="mg-note">The admin panel (at /admin) holds Vaultwarden's other settings: email (SMTP), two-step login,
		invitations, users and organisations. Only its hash is given to Vaultwarden; a new token restarts it.</p>

	<h3>Backups</h3>
	<p><label>Folder <input type="text" data-vw="backup-dir" size="40" spellcheck="false"></label>
		<label>Keep <input type="number" data-vw="backup-keep" min="1" max="365" style="width: 5em"> backups</label>
		<button type="button" data-vw-action="backup-settings">Save</button></p>
	<p><button type="button" data-vw-action="backup">Back up now</button>
		<span class="mg-note">Every day at 02:15: the database (copied safely while Vaultwarden runs), attachments, sends,
			its keys and admin panel settings, readable by root only.</span></p>
	<table data-vw="backups"></table>

	<details class="mg-section">
		<summary>Vaultwarden's latest warnings</summary>
		<pre data-vw="log"></pre>
	</details>

	<p data-vw="message"></p>

	<script>
	// Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
	(function () {
		var root = document.getElementById('vaultwarden-manage');
		var api = '/apps/vaultwarden/api.php';
		var csrf = <?php echo json_encode(manage_csrf_token('vaultwarden')); ?>;
		<?php manage_secret_script(); ?>
		var siteStates = { no_nginx: 'The Nginx app isn\'t set up - it serves Vaultwarden over HTTPS, which its web vault needs',
			no_domain: 'Set a domain in the Nginx app first: Vaultwarden is then at https://vaultwarden.<domain>',
			off: 'Switched off in the Nginx app (turn its Vaultwarden entry back on there)' };
		var loaded = false;

		function part(name) { return root.querySelector('[data-vw="' + name + '"]'); }
		function button(name) { return root.querySelector('[data-vw-action="' + name + '"]'); }

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
				table.insertRow().insertCell().textContent = hasDb ? 'No backups yet' : 'No backups yet (there is nothing to back up until an account is created)';
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
				part('version').textContent = d.version ? d.version + (d.web_vault ? ' (web vault ' + d.web_vault + ')' : '') : '-';

				var address = part('address');
				address.textContent = d.site.url || siteStates[d.site.state];
				address.className = d.site.url ? '' : 'mg-bad';
				part('link').hidden = part('admin-link').hidden = !d.site.url;
				part('link').href = d.site.url;
				part('admin-link').href = d.site.url + 'admin';
				part('restart-note').hidden = !d.restart_needed;

				// The settings are only filled in once, so a refresh doesn't undo changes being made
				if (!loaded) {
					part('signups').checked = d.signups;
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
			act('restart', { confirm: 1 }, 'Restarting Vaultwarden…', 'Vaultwarden restarted.');
		});

		button('signups').addEventListener('click', function () {
			var on = part('signups').checked;
			act('signups', { on: on ? 1 : 0 }, 'Saving…', on ? 'New accounts can sign up.' : 'Sign-ups are off.');
		});

		// The admin token: Show / Hide and Copy (fetched when first needed)
		var secret = mgSecret(part('token'), button('show'), button('copy'), function () {
			return call('token', { show: 1 }).then(function (d) {
				if (!d.ok) { say(d.error, false); return null; }
				return d.token;
			});
		});

		button('new-token').addEventListener('click', function () {
			if (!window.confirm('Make a new admin token? The current one stops working, and Vaultwarden restarts.')) { return; }
			act('new_token', { confirm: 1 }, 'Making a new token…', 'New admin token in use.').then(function (d) {
				if (d) { secret.set(d.token); }
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
