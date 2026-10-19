<?php
// ValKey's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('valkey');
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="valkey-manage">
	<style>
		/* Everything is scoped to #valkey-manage: this page is injected into the dashboard's own window */
		#valkey-manage { font-family: inherit; color: inherit; max-width: 46rem; padding: 0.5rem 0; line-height: 1.5; }
		#valkey-manage h2 { font-size: 1.3em; margin: 0 0 0.75rem; }
		#valkey-manage h3 { font-size: 1.05em; margin: 1.25rem 0 0.5rem; }
		#valkey-manage table { border-collapse: collapse; }
		#valkey-manage td { padding: 0.15rem 1rem 0.15rem 0; vertical-align: top; }
		#valkey-manage code { background: rgba(127, 127, 127, 0.15); border-radius: 4px; padding: 0.1rem 0.35rem; word-break: break-all; }
		#valkey-manage input[type=text] { width: 22rem; max-width: 100%; padding: 0.3rem; }
		#valkey-manage button { margin: 0.2rem 0.4rem 0.2rem 0; padding: 0.3rem 0.8rem; cursor: pointer; }
		#valkey-manage .vk-ok { color: #2e7d32; }
		#valkey-manage .vk-bad { color: #c62828; }
		#valkey-manage .vk-note { opacity: 0.75; font-size: 0.9em; }
	</style>

	<h2>ValKey</h2>
	<table>
		<tr><td>Status</td><td data-vk="status">…</td></tr>
		<tr><td>Version</td><td data-vk="version">…</td></tr>
		<tr><td>Listening on</td><td data-vk="listen">…</td></tr>
	</table>

	<h3>Password</h3>
	<p>Clients connect with: <code data-vk="password">••••••••••••</code>
		<button type="button" data-vk-action="show">Show</button></p>
	<p class="vk-note">e.g. <code>REDISCLI_AUTH=&lt;password&gt; valkey-cli</code> over SSH, or the password setting of your app's Redis / ValKey client.</p>
	<p><input type="text" data-vk="new" placeholder="New password (leave empty to generate one)" autocomplete="off" spellcheck="false">
		<button type="button" data-vk-action="set">Change password</button></p>
	<p class="vk-note">The new password takes effect immediately, so update your clients too. Passwords are 12-128 characters: letters, digits and . _ ~ -</p>
	<p data-vk="message"></p>

	<script>
	// Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
	(function () {
		var root = document.getElementById('valkey-manage');
		var api = '/apps/valkey/api.php';
		var csrf = <?php echo json_encode(manage_csrf_token('valkey')); ?>;

		function part(name) { return root.querySelector('[data-vk="' + name + '"]'); }

		function say(text, good) {
			var message = part('message');
			message.textContent = text;
			message.className = good ? 'vk-ok' : 'vk-bad';
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
				status.textContent = d.running ? 'Running' : 'Stopped';
				status.className = d.running ? 'vk-ok' : 'vk-bad';
				part('version').textContent = d.version || 'unknown';
				part('listen').textContent = (d.bind || 'all interfaces') + ', port ' + d.port + (d.has_password ? ' (password required)' : ' (no password!)');
			});
		}

		root.querySelector('[data-vk-action="show"]').addEventListener('click', function () {
			call('password', { show: 1 }).then(function (d) {
				if (d.ok) { part('password').textContent = d.password || '(none)'; } else { say(d.error, false); }
			});
		});

		root.querySelector('[data-vk-action="set"]').addEventListener('click', function () {
			var input = part('new');
			if (!window.confirm('Change the ValKey password? Clients using the old one will stop working until they are updated.')) { return; }
			call('set_password', { password: input.value }).then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				input.value = '';
				part('password').textContent = d.password;
				say(d.applied ? 'Password changed - it is now in use.' : 'Password saved - it will be used when ValKey next starts.', true);
				refresh();
			});
		});

		refresh();
	})();
	</script>
</div>
