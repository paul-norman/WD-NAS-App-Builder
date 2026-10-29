<?php
// pgweb's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('pgweb');
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="pgweb-manage">
	<?php manage_styles('pgweb-manage'); ?>

	<h2>pgweb</h2>
	<table>
		<tr><td>Status</td><td data-pw="status">…</td></tr>
		<tr><td>Version</td><td data-pw="version">-</td></tr>
		<tr><td>Address</td><td data-pw="address">-</td></tr>
	</table>
	<p><a class="mg-button" data-pw="link" href="#" target="_blank" rel="noopener">Open pgweb</a>
		<button type="button" data-pw-action="restart">Restart pgweb</button></p>

	<h3>Logging in</h3>
	<p>Its addresses ask first for the user name <code>admin</code> and the password (unless switched off below): <code data-pw="password">••••••••••••</code>
		<button type="button" data-pw-action="show">Show</button> <button type="button" data-pw-action="copy">Copy</button></p>
	<p><input type="text" data-pw="new" placeholder="New password (leave empty to generate one)" autocomplete="off" spellcheck="false">
		<button type="button" data-pw-action="set">Change password</button></p>
	<p class="mg-note">The new password takes effect immediately. Passwords are 12-128 characters: letters, digits and . _ ~ -</p>
	<p><label><input type="checkbox" data-pw="auth"> Ask for this password first (before pgweb's own form)</label>
		<button type="button" data-pw-action="auth">Save</button></p>
	<p class="mg-note">Without it, anyone who reaches pgweb's address gets its form - which can connect to any server, not
		only the NAS's PostgreSQL (e.g. to probe the local network) - and only PostgreSQL's own login protects the data.
		Keep it on if its address can be reached from the internet.</p>
	<p>Then pgweb asks which database to open: host <code>127.0.0.1</code>, port <code>5432</code>, and a database user with
		its password - e.g. one made on the <span data-pw="pg">PostgreSQL app's</span> page (Databases), or <code>postgres</code>
		for everything. SSL mode: disable (the connection doesn't leave the NAS).</p>

	<h3>Settings</h3>
	<p><label><input type="checkbox" data-pw="readonly"> Read only (queries can't change anything)</label>
		<button type="button" data-pw-action="readonly">Save</button></p>
	<p class="mg-note">pgweb restarts, and everyone using it logs in to their database again.</p>

	<h3>Access</h3>
	<p><label><input type="checkbox" data-pw="local"> Only through the Nginx app (HTTPS)</label>
		<button type="button" data-pw-action="listen">Save</button></p>
	<p class="mg-note">Otherwise pgweb is also reachable on port 8081 from the local network, over plain HTTP, with its own
		login (the same user name and password - the password and your database logins then cross the network unencrypted,
		and the password is on pgweb's command line, which other programs on the NAS can read). pgweb restarts.</p>

	<details class="mg-section">
		<summary>pgweb's latest warnings</summary>
		<pre data-pw="log"></pre>
	</details>

	<p data-pw="message"></p>

	<script>
	// Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
	(function () {
		var root = document.getElementById('pgweb-manage');
		var api = '/apps/pgweb/api.php';
		var csrf = <?php echo json_encode(manage_csrf_token('pgweb')); ?>;
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
				status.textContent = !d.running ? 'Stopped' : (d.answering ? 'Running' + (d.readonly ? ' (read only)' : '') : 'Starting…');
				status.className = d.running && d.answering ? 'mg-ok' : 'mg-bad';
				part('version').textContent = d.version || '-';
				// Its addresses: the Nginx app's (HTTPS), and port 8081 on the local network unless only through the Nginx app
				var addresses = [];
				if (d.site.url) { addresses.push(d.site.url); }
				if (d.listen === 'all') { addresses.push('http://' + window.location.hostname + ':8081/'); }
				part('address').textContent = (addresses.join(' and ') || 'none - turn off "Only through the Nginx app", or set the Nginx app up') +
					(d.site.url ? '' : ' (HTTPS: ' + siteStates[d.site.state] + ')');
				part('address').className = addresses.length ? '' : 'mg-bad';
				part('link').hidden = !addresses.length;
				part('link').href = addresses[0] || '#';
				part('pg').textContent = d.postgresql ? 'PostgreSQL app\'s' : 'PostgreSQL app\'s (not installed)';
				if (!loaded) {
					part('readonly').checked = d.readonly;
					part('local').checked = d.listen === 'local';
					part('auth').checked = d.auth;
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
			act('restart', { confirm: 1 }, 'Restarting pgweb…', 'pgweb restarted.');
		});

		button('auth').addEventListener('click', function () {
			var auth = part('auth').checked;
			act('auth', { auth: auth ? 1 : '' }, 'Saving…', auth ? 'pgweb asks for the password first.' :
				'pgweb no longer asks for the password first: only PostgreSQL\'s own login.');
		});

		button('listen').addEventListener('click', function () {
			var local = part('local').checked;
			act('listen', { listen: local ? 'local' : 'all' }, 'Saving…', local ? 'pgweb is now only reachable through the Nginx app.' :
				'pgweb is reachable on port 8081 too, with its own login.');
		});

		button('readonly').addEventListener('click', function () {
			var readonly = part('readonly').checked;
			act('readonly', { readonly: readonly ? 1 : '' }, 'Saving…', readonly ? 'pgweb is now read only.' : 'pgweb can change databases again.');
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
