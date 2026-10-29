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
		<button type="button" data-pma-action="show">Show</button> <button type="button" data-pma-action="copy">Copy</button></p>
	<p><input type="text" data-pma="new" placeholder="New password (leave empty to generate one)" autocomplete="off" spellcheck="false">
		<button type="button" data-pma-action="set">Change password</button></p>
	<p class="mg-note">The new password takes effect immediately, and is kept if the app is reinstalled. Passwords are 12-128 characters: letters, digits and . _ ~ -</p>
	<p class="mg-note">MariaDB's <code>root</code> account can't log in to phpMyAdmin: it has no password, as the NAS's own services rely on that, and MariaDB only accepts connections from the NAS itself.</p>
	<h3>Its HTTPS address</h3>
	<p>Through the Nginx app: <span data-pma="site">…</span></p>
	<p>It asks first for the user name <code>admin</code> and its own password (not the account's above):
		<code data-pma="site-password">••••••••••••</code>
		<button type="button" data-pma-action="site-show">Show</button> <button type="button" data-pma-action="site-copy">Copy</button></p>
	<p><input type="text" data-pma="site-new" placeholder="New password (leave empty to generate one)" autocomplete="off" spellcheck="false">
		<button type="button" data-pma-action="site-set">Change password</button></p>
	<p><label><input type="checkbox" data-pma="auth"> Ask for this password first (before phpMyAdmin's own login)</label>
		<button type="button" data-pma-action="auth">Save</button></p>
	<p class="mg-note">Without it, anyone who reaches its HTTPS address gets phpMyAdmin's login, and only the MariaDB
		accounts' passwords protect the data. Keep it on if the address can be reached from the internet. The NAS's own
		address (http://<span data-pma="host">nas</span>/phpMyAdmin/, on the local network) has only phpMyAdmin's login.</p>

	<p data-pma="message"></p>

	<script>
	// Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
	(function () {
		var root = document.getElementById('phpmyadmin-manage');
		var api = '/apps/phpMyAdmin/api.php';
		var csrf = <?php echo json_encode(manage_csrf_token('phpMyAdmin')); ?>;
		<?php manage_secret_script(); ?>

		var loaded = false;

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
				var states = { no_nginx: 'none - the Nginx app isn\'t set up', no_domain: 'none yet - set a domain in the Nginx app', off: 'switched off in the Nginx app' };
				part('site').textContent = d.site.url || states[d.site.state];
				part('host').textContent = window.location.hostname;
				if (!loaded) {
					part('auth').checked = d.auth;
					loaded = true;
				}
			});
		}

		// The password: Show / Hide and Copy (fetched when first needed)
		var secret = mgSecret(part('password'), root.querySelector('[data-pma-action="show"]'), root.querySelector('[data-pma-action="copy"]'), function () {
			return call('password', { show: 1 }).then(function (d) {
				if (!d.ok) { say(d.error, false); return null; }
				return d.password || '(none)';
			});
		});

		root.querySelector('[data-pma-action="set"]').addEventListener('click', function () {
			var input = part('new');
			if (!window.confirm('Change the phpMyAdmin admin password? You will need the new one to log in.')) { return; }
			call('set_password', { password: input.value }).then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				input.value = '';
				secret.set(d.password);
				say('Password changed - use it to log in to phpMyAdmin.', true);
			});
		});

		// Its HTTPS address's password: Show / Hide, Copy and Change - and whether it's asked for
		var siteSecret = mgSecret(part('site-password'), root.querySelector('[data-pma-action="site-show"]'), root.querySelector('[data-pma-action="site-copy"]'), function () {
			return call('site_password', { show: 1 }).then(function (d) {
				if (!d.ok) { say(d.error, false); return null; }
				return d.password || '(none)';
			});
		});

		root.querySelector('[data-pma-action="site-set"]').addEventListener('click', function () {
			var input = part('site-new');
			call('set_site_password', { password: input.value }).then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				input.value = '';
				siteSecret.set(d.password);
				say('New password for the HTTPS address in use.', true);
			});
		});

		root.querySelector('[data-pma-action="auth"]').addEventListener('click', function () {
			var auth = part('auth').checked;
			call('auth', { auth: auth ? 1 : '' }).then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				say(auth ? 'Its HTTPS address asks for the password first.' : 'Its HTTPS address no longer asks for the password first: only phpMyAdmin\'s login.', true);
			});
		});

		refresh();
	})();
	</script>
</div>
