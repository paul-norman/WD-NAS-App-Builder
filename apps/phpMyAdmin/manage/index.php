<?php
// phpMyAdmin's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('phpMyAdmin');
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="phpmyadmin-manage">
	<?php manage_styles('phpmyadmin-manage'); ?>

	<h2>phpMyAdmin</h2>
	<table>
		<tr><td>MariaDB</td><td data-pma="status">…</td></tr>
		<tr><td>Listening on</td><td data-pma="listen">…</td></tr>
		<tr><td>phpMyAdmin</td><td data-pma="version">…</td></tr>
	</table>
	<p><a class="mg-button" href="/phpMyAdmin/" target="_blank" rel="noopener">Open phpMyAdmin</a></p>

	<h3>The <code>admin</code> account</h3>
	<p>Log in to phpMyAdmin as <code>admin</code> with: <code data-pma="password">••••••••••••</code>
		<button type="button" data-pma-action="show">Show</button></p>
	<p><input type="text" data-pma="new" placeholder="New password (leave empty to generate one)" autocomplete="off" spellcheck="false">
		<button type="button" data-pma-action="set">Change password</button></p>
	<p class="mg-note">The new password takes effect immediately, and is kept if the app is reinstalled. Passwords are 12-128 characters: letters, digits and . _ ~ -</p>
	<p class="mg-note">MariaDB's <code>root</code> account can't log in to phpMyAdmin: it has no password, as the NAS's own services rely on that, and MariaDB only accepts connections from the NAS itself.</p>
	<p data-pma="message"></p>

	<script>
	// Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
	(function () {
		var root = document.getElementById('phpmyadmin-manage');
		var api = '/apps/phpMyAdmin/api.php';
		var csrf = <?php echo json_encode(manage_csrf_token('phpMyAdmin')); ?>;

		function part(name) { return root.querySelector('[data-pma="' + name + '"]'); }

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
			call('status').then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				var status = part('status');
				status.textContent = d.running ? 'Running (' + d.mariadb_version + ')' : 'Not running';
				status.className = d.running ? 'mg-ok' : 'mg-bad';
				part('listen').textContent = d.running ? d.bind + ', port ' + d.port + (d.bind === '127.0.0.1' ? ' (the NAS only)' : '') : '-';
				part('version').textContent = d.phpmyadmin_version + (d.admin_exists ? '' : ' - the admin account is missing: reinstall the app to recreate it');
			});
		}

		root.querySelector('[data-pma-action="show"]').addEventListener('click', function () {
			call('password', { show: 1 }).then(function (d) {
				if (d.ok) { part('password').textContent = d.password || '(none)'; } else { say(d.error, false); }
			});
		});

		root.querySelector('[data-pma-action="set"]').addEventListener('click', function () {
			var input = part('new');
			if (!window.confirm('Change the phpMyAdmin admin password? You will need the new one to log in.')) { return; }
			call('set_password', { password: input.value }).then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				input.value = '';
				part('password').textContent = d.password;
				say('Password changed - use it to log in to phpMyAdmin.', true);
			});
		});

		refresh();
	})();
	</script>
</div>
