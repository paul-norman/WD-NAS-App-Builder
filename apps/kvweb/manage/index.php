<?php
// kvweb's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('kvweb');
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="kvweb-manage">
	<?php manage_styles('kvweb-manage'); ?>

	<h2>kvweb</h2>
	<table>
		<tr><td>Status</td><td data-pw="status">…</td></tr>
		<tr><td>Version</td><td data-pw="version">-</td></tr>
		<tr><td>Address</td><td data-pw="address">-</td></tr>
		<tr><td>Valkey</td><td data-pw="valkey">-</td></tr>
	</table>
	<p><a class="mg-button" data-pw="link" href="#" target="_blank" rel="noopener">Open kvweb</a>
		<button type="button" data-pw-action="restart">Restart kvweb</button></p>

	<h3>Logging in</h3>
	<p>Its address asks for the user name <code>admin</code> and the password: <code data-pw="password">••••••••••••</code>
		<button type="button" data-pw-action="show">Show</button> <button type="button" data-pw-action="copy">Copy</button></p>
	<p><input type="text" data-pw="new" placeholder="New password (leave empty to generate one)" autocomplete="off" spellcheck="false">
		<button type="button" data-pw-action="set">Change password</button></p>
	<p class="mg-note">The new password takes effect immediately. Passwords are 12-128 characters: letters, digits and . _ ~ -</p>
	<p class="mg-note">kvweb then shows the Valkey app's keys: it logs in to Valkey by itself, with the password on the Valkey
		app's page (changing it there restarts kvweb with the new one).</p>

	<h3>Settings</h3>
	<p><label><input type="checkbox" data-pw="readonly"> Read only (keys can be seen, not changed or deleted)</label>
		<button type="button" data-pw-action="readonly">Save</button></p>
	<p class="mg-note">kvweb restarts. Emptying a whole database (FLUSHDB / FLUSHALL) is always blocked.</p>

	<details class="mg-section">
		<summary>kvweb's latest warnings</summary>
		<pre data-pw="log"></pre>
	</details>

	<p data-pw="message"></p>

	<script>
	// Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
	(function () {
		var root = document.getElementById('kvweb-manage');
		var api = '/apps/kvweb/api.php';
		var csrf = <?php echo json_encode(manage_csrf_token('kvweb')); ?>;
		<?php manage_secret_script(); ?>
		var siteStates = { no_nginx: 'install the Nginx app - kvweb is only reached through it (HTTPS)',
			no_domain: 'set a domain in the Nginx app', off: 'switched off in the Nginx app' };
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
				status.textContent = !d.running ? 'Stopped (or waiting for Valkey)' : (d.answering ? 'Running' + (d.readonly ? ' (read only)' : '') : 'Starting…');
				status.className = d.running && d.answering ? 'mg-ok' : 'mg-bad';
				part('version').textContent = d.version || '-';
				part('address').textContent = d.site.url || 'none yet - ' + siteStates[d.site.state];
				part('address').className = d.site.url ? '' : 'mg-bad';
				part('link').hidden = !d.site.url;
				part('link').href = d.site.url || '#';
				var valkey = part('valkey');
				valkey.textContent = !d.valkey ? 'not installed - kvweb needs the Valkey app' : (!d.answering ? '-' :
					(d.connected ? 'connected' : 'not answering (kvweb reconnects by itself once it does)'));
				valkey.className = d.valkey && (!d.answering || d.connected) ? '' : 'mg-bad';
				if (!loaded) {
					part('readonly').checked = d.readonly;
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
			act('restart', { confirm: 1 }, 'Restarting kvweb…', 'kvweb restarted.');
		});

		button('readonly').addEventListener('click', function () {
			var readonly = part('readonly').checked;
			act('readonly', { readonly: readonly ? 1 : '' }, 'Saving…', readonly ? 'kvweb is now read only.' : 'kvweb can change keys again.');
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
