<?php
// Kopia's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('kopia');
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="kopia-manage">
	<?php manage_styles('kopia-manage'); ?>

	<h2>Kopia (backups)</h2>
	<table>
		<tr><td>Status</td><td data-kp="status">…</td></tr>
		<tr><td>Version</td><td data-kp="version">-</td></tr>
		<tr><td>Address</td><td data-kp="address">-</td></tr>
		<tr><td>Repository</td><td data-kp="repo">-</td></tr>
	</table>
	<p><a class="mg-button" data-kp="link" href="#" target="_blank" rel="noopener">Open Kopia</a>
		<button type="button" data-kp-action="restart">Restart Kopia</button></p>

	<h3>Logging in</h3>
	<p>Log in to Kopia as <code>admin</code> with: <code data-kp="password">••••••••••••</code>
		<button type="button" data-kp-action="show">Show</button> <button type="button" data-kp-action="copy">Copy</button>
		<button type="button" data-kp-action="new-password">New password</button></p>
	<p class="mg-note">This is only Kopia's web interface login. The repository's own password (which encrypts the backups,
		set when the repository is created) is separate: keep a copy away from the NAS - without it the backups can't be
		restored.</p>

	<h3>Backups</h3>
	<table data-kp="sources"></table>
	<p class="mg-note">Folders to back up, their schedules and how many snapshots to keep are set in Kopia (Snapshots → New
		Snapshot, and Policies). The NAS's shares are under /mnt/HD/HD_a2 (e.g. /mnt/HD/HD_a2/Public).</p>

	<h3>Access</h3>
	<p><label><input type="checkbox" data-kp="local"> Only through the Nginx app (HTTPS)</label>
		<button type="button" data-kp-action="listen">Save</button></p>
	<p class="mg-note">Otherwise Kopia is also reachable on port 51515 from the local network, over plain HTTP. It can read
		and restore any file on the NAS, so HTTPS through the Nginx app is safer. Kopia restarts (a snapshot in progress
		resumes later).</p>

	<details class="mg-section">
		<summary>Kopia's latest output</summary>
		<pre data-kp="log"></pre>
	</details>

	<p data-kp="message"></p>

	<script>
	// Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
	(function () {
		var root = document.getElementById('kopia-manage');
		var api = '/apps/kopia/api.php';
		var csrf = <?php echo json_encode(manage_csrf_token('kopia')); ?>;
		<?php manage_secret_script(); ?>
		var siteStates = { no_nginx: 'the Nginx app isn\'t set up', no_domain: 'set a domain in the Nginx app for HTTPS',
			off: 'switched off in the Nginx app' };
		var loaded = false;

		function part(name) { return root.querySelector('[data-kp="' + name + '"]'); }
		function button(name) { return root.querySelector('[data-kp-action="' + name + '"]'); }

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
			var units = ['B', 'KB', 'MB', 'GB', 'TB'];
			var i = 0;
			while (bytes >= 1000 && i < units.length - 1) { bytes /= 1000; i++; }
			return (i ? bytes.toFixed(1) : bytes) + ' ' + units[i];
		}

		function when(time) { return time ? new Date(time).toLocaleString() : '-'; }

		// The backup sources: paths come from Kopia, so they are only ever set as text
		function fillSources(sources, repo) {
			var table = part('sources');
			table.textContent = '';
			if (!sources.length) {
				table.insertRow().insertCell().textContent = repo && repo.connected ? 'No folders backed up yet - add them in Kopia (Snapshots → New Snapshot)' :
					'Connect Kopia to a repository first (open Kopia: where the backups are stored, e.g. Backblaze B2, S3, an SFTP server or a USB drive)';
				return;
			}
			var head = table.insertRow();
			['Folder', 'Last snapshot', 'Size', 'Next', 'State'].forEach(function (text) {
				var cell = head.insertCell();
				cell.textContent = text;
				cell.style.fontWeight = 'bold';
			});
			sources.forEach(function (source) {
				var row = table.insertRow();
				row.insertCell().textContent = source.path;
				row.insertCell().textContent = when(source.last);
				row.insertCell().textContent = source.size === null ? '-' : size(source.size);
				row.insertCell().textContent = when(source.next);
				var state = row.insertCell();
				state.textContent = source.status === 'UPLOADING' ? 'backing up now' : (source.errors ? source.errors + ' file error(s) last time' : (source.last ? 'ok' : 'not backed up yet'));
				state.className = source.errors || !source.last ? 'mg-bad' : 'mg-ok';
			});
		}

		function refresh() {
			return call('status').then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				var status = part('status');
				status.textContent = !d.running ? 'Stopped' : (d.answering ? 'Running' : 'Starting…');
				status.className = d.running && d.answering ? 'mg-ok' : 'mg-bad';
				part('version').textContent = d.version || '-';

				// Its addresses: the Nginx app's (HTTPS), and port 51515 on the local network unless only through the Nginx app
				var local = 'http://' + window.location.hostname + ':51515/';
				var addresses = [];
				if (d.site.url) { addresses.push(d.site.url); }
				if (d.listen === 'all') { addresses.push(local); }
				part('address').textContent = (addresses.join(' and ') || 'none - turn off "Only through the Nginx app", or set the Nginx app up') +
					(d.site.url ? '' : ' (HTTPS: ' + siteStates[d.site.state] + ')');
				part('address').className = addresses.length ? '' : 'mg-bad';
				part('link').hidden = !addresses.length;
				part('link').href = addresses[0] || '#';

				var repo = part('repo');
				repo.textContent = !d.repo ? '-' : (d.repo.connected ? 'connected' + (d.repo.description ? ': ' + d.repo.description : '') :
					'not set up yet - open Kopia to create or connect a repository (where the backups go)');
				repo.className = d.repo && !d.repo.connected ? 'mg-bad' : '';

				if (!loaded) {
					part('local').checked = d.listen === 'local';
					loaded = true;
				}
				fillSources(d.sources, d.repo);
				part('log').textContent = d.log.length ? d.log.join('\n') : 'Nothing logged';
			});
		}

		// Keep the page current (e.g. while a snapshot runs), until the dashboard removes it
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
			act('restart', { confirm: 1 }, 'Restarting Kopia…', 'Kopia restarted.');
		});

		button('listen').addEventListener('click', function () {
			var local = part('local').checked;
			act('listen', { listen: local ? 'local' : 'all' }, 'Saving…', local ? 'Kopia is now only reachable through the Nginx app.' :
				'Kopia is reachable on port 51515 too.');
		});

		// The web interface's password: Show / Hide and Copy (fetched when first needed)
		var secret = mgSecret(part('password'), button('show'), button('copy'), function () {
			return call('password', { show: 1 }).then(function (d) {
				if (!d.ok) { say(d.error, false); return null; }
				return d.password;
			});
		});

		button('new-password').addEventListener('click', function () {
			if (!window.confirm('Make a new password for Kopia\'s web interface? Kopia restarts.')) { return; }
			act('new_password', { confirm: 1 }, 'Making a new password…', 'New password in use.').then(function (d) {
				if (d) { secret.set(d.password); }
			});
		});

		refresh();
	})();
	</script>
</div>
