<?php
// Adminer's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('adminer');
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="adminer-manage">
	<?php manage_styles('adminer-manage'); ?>

	<h2>Adminer</h2>
	<table>
		<tr><td>Status</td><td data-pw="status">…</td></tr>
		<tr><td>Version</td><td data-pw="version">-</td></tr>
		<tr><td>Address</td><td data-pw="address">-</td></tr>
	</table>
	<p><a class="mg-button" data-pw="link" href="#" target="_blank" rel="noopener">Open Adminer</a>
		<button type="button" data-pw-action="restart">Restart Adminer</button></p>

	<h3>Logging in</h3>
	<p>Its HTTPS address (the Nginx app's) asks first for the user name <code>admin</code> and the password: <code data-pw="password">••••••••••••</code>
		<button type="button" data-pw-action="show">Show</button> <button type="button" data-pw-action="copy">Copy</button></p>
	<p><input type="text" data-pw="new" placeholder="New password (leave empty to generate one)" autocomplete="off" spellcheck="false">
		<button type="button" data-pw-action="set">Change password</button></p>
	<p class="mg-note">The new password takes effect immediately. Passwords are 12-128 characters: letters, digits and . _ ~ -</p>
	<p><label><input type="checkbox" data-pw="auth"> Ask for this password first (before Adminer's own login)</label>
		<button type="button" data-pw-action="auth">Save</button></p>
	<p class="mg-note">Without it, anyone who reaches its HTTPS address gets Adminer's login form - which can connect to any
		server, not only the NAS's databases (e.g. to probe the local network) - and only the databases' own logins protect
		the data. Keep it on if its address can be reached from the internet.</p>
	<p>Then Adminer asks for a database login:</p>
	<ul>
		<li><strong>MariaDB</strong> (System: MySQL / MariaDB): server <code>127.0.0.1</code>, and a MariaDB user - e.g. phpMyAdmin's
			<code>admin</code> <span data-pw="mariadb"></span></li>
		<li><strong>PostgreSQL</strong>: server <code>127.0.0.1</code>, and a database user - e.g. one made on the PostgreSQL app's
			page (Databases), or <code>postgres</code> <span data-pw="pg"></span></li>
		<li><strong>Valkey</strong> (System: Redis): server <code>127.0.0.1</code>, username <code>default</code>, and the password on
			the Valkey app's page <span data-pw="valkey"></span></li>
	</ul>
	<h3>Access</h3>
	<p><label><input type="checkbox" data-pw="local"> Only through the Nginx app (HTTPS)</label>
		<button type="button" data-pw-action="listen">Save</button></p>
	<p class="mg-note">Otherwise Adminer is also reachable on port 8084 from the local network, over plain HTTP, with only its
		own database login (which limits failed attempts) - the database logins then cross the network unencrypted. Adminer
		restarts.</p>

	<p class="mg-note">Adminer runs on <span data-pw="php">-</span>, as its own user. Imports of up to 512MB go through
		(Import, or SQL command).</p>

	<details class="mg-section">
		<summary>Adminer's latest output (PHP's server logs each request)</summary>
		<pre data-pw="log"></pre>
	</details>

	<p data-pw="message"></p>

	<script>
	// Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
	(function () {
		var root = document.getElementById('adminer-manage');
		var api = '/apps/adminer/api.php';
		var csrf = <?php echo json_encode(manage_csrf_token('adminer')); ?>;
		<?php manage_secret_script(); ?>
		var siteStates = { no_nginx: 'the Nginx app isn\'t set up', no_domain: 'set a domain in the Nginx app',
			off: 'switched off in the Nginx app' };
		var loaded = false;

		function part(name) { return root.querySelector('[data-pw="' + name + '"]'); }
		function button(name) { return root.querySelector('[data-pw-action="' + name + '"]'); }

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
				var status = part('status');
				status.textContent = !d.running ? 'Stopped' : (d.answering ? 'Running' : 'Starting…');
				status.className = d.running && d.answering ? 'mg-ok' : 'mg-bad';
				part('version').textContent = d.version || '-';
				// Its addresses: the Nginx app's (HTTPS), and port 8084 on the local network unless only through the Nginx app
				var addresses = [];
				if (d.site.url) { addresses.push(d.site.url); }
				if (d.listen === 'all') { addresses.push('http://' + window.location.hostname + ':8084/'); }
				part('address').textContent = (addresses.join(' and ') || 'none - turn off "Only through the Nginx app", or set the Nginx app up') +
					(d.site.url ? '' : ' (HTTPS: ' + siteStates[d.site.state] + ')');
				part('address').className = addresses.length ? '' : 'mg-bad';
				part('link').hidden = !addresses.length;
				part('link').href = addresses[0] || '#';
				if (!loaded) {
					part('local').checked = d.listen === 'local';
					part('auth').checked = d.auth;
					loaded = true;
				}
				part('mariadb').textContent = d.mariadb ? '' : '(the NAS\'s own MariaDB - the MariaDB app updates it)';
				part('pg').textContent = !d.postgresql ? '(the PostgreSQL app isn\'t installed)' :
					(d.php === 'nas' ? '(needs the PHP app: the NAS\'s own PHP has no PostgreSQL driver)' : '');
				part('pg').className = d.postgresql && d.php === 'nas' ? 'mg-bad' : '';
				part('valkey').textContent = d.valkey ? '' : '(the Valkey app isn\'t installed)';
				part('php').textContent = d.php === 'app' ? 'the PHP app\'s PHP 8.5 (MariaDB, PostgreSQL, SQLite)' :
					(d.php === 'nas' ? 'the NAS\'s own PHP 7.4 (MariaDB and SQLite - install the PHP app for PostgreSQL too, then restart Adminer)' : 'no PHP found');
				part('php').className = d.php ? '' : 'mg-bad';
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
			act('restart', { confirm: 1 }, 'Restarting Adminer…', 'Adminer restarted.');
		});

		button('auth').addEventListener('click', function () {
			var auth = part('auth').checked;
			act('auth', { auth: auth ? 1 : '' }, 'Saving…', auth ? 'Adminer\'s HTTPS address asks for the password first.' :
				'Adminer\'s HTTPS address no longer asks for the password first: only the databases\' own logins.');
		});

		button('listen').addEventListener('click', function () {
			var local = part('local').checked;
			act('listen', { listen: local ? 'local' : 'all' }, 'Saving…', local ? 'Adminer is now only reachable through the Nginx app.' :
				'Adminer is reachable on port 8084 too.');
		});

		// The site's password: Show / Hide and Copy (fetched when first needed)
		var secret = mgSecret(part('password'), button('show'), button('copy'), function () {
			return call('password', { show: 1 }).then(function (d) {
				if (!d.ok) { say(d.error, false); return null; }
				return d.password;
			});
		});

		button('set').addEventListener('click', function () {
			act('set_password', { password: part('new').value.trim() }, 'Saving the password…', 'New password in use.').then(function (d) {
				if (d) { secret.set(d.password); part('new').value = ''; }
			});
		});

		refresh();
	})();
	</script>
</div>
