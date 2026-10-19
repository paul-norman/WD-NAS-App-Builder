<?php
// Mailpit's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('mailpit');
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="mailpit-manage">
	<?php manage_styles('mailpit-manage'); ?>

	<h2>Mailpit</h2>
	<table>
		<tr><td>Status</td><td data-mp="status">…</td></tr>
		<tr><td>Version</td><td data-mp="version">-</td></tr>
		<tr><td>Messages</td><td data-mp="messages">-</td></tr>
	</table>
	<p><a class="mg-button" data-mp="link" href="#" target="_blank" rel="noopener">Open Mailpit</a>
		<button type="button" data-mp-action="restart">Restart Mailpit</button>
		<button type="button" data-mp-action="delete">Delete all messages</button></p>

	<h3>Sending mail to Mailpit</h3>
	<p>Point your apps' SMTP settings at the NAS, port <code>1026</code>. Any username and password are accepted, and
		nothing is delivered: every message only appears in Mailpit.</p>

	<p data-mp="message"></p>

	<script>
	// Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
	(function () {
		var root = document.getElementById('mailpit-manage');
		var api = '/apps/mailpit/api.php';
		var csrf = <?php echo json_encode(manage_csrf_token('mailpit')); ?>;

		function part(name) { return root.querySelector('[data-mp="' + name + '"]'); }
		function button(name) { return root.querySelector('[data-mp-action="' + name + '"]'); }

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
				part('messages').textContent = d.answering ? d.total + ' (' + d.unread + ' unread)' : '-';
				button('delete').disabled = !d.answering || d.total === 0;
			});
		}

		part('link').href = 'http://' + window.location.hostname + ':8025/';

		button('restart').addEventListener('click', function () {
			say('Restarting Mailpit…', true);
			call('restart', { confirm: 1 }).then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				say('Mailpit restarted.', true);
				setTimeout(refresh, 1000);
			});
		});

		button('delete').addEventListener('click', function () {
			if (!window.confirm('Delete all messages in Mailpit? This can\'t be undone.')) { return; }
			call('delete_all', { confirm: 1 }).then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				say('All messages deleted.', true);
				refresh();
			});
		});

		refresh();
	})();
	</script>
</div>
