<?php
// Music Assistant's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('music-assistant');
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="music-assistant-manage">
	<?php manage_styles('music-assistant-manage'); ?>

	<h2>Music Assistant</h2>
	<table>
		<tr><td>Status</td><td data-ma="status">…</td></tr>
		<tr><td>Version</td><td data-ma="version">-</td></tr>
		<tr><td>Address</td><td data-ma="address">-</td></tr>
	</table>
	<p><a class="mg-button" data-ma="link" href="#" target="_blank" rel="noopener">Open Music Assistant</a>
		<button type="button" data-ma-action="restart">Restart Music Assistant</button></p>

	<h3>Admin user</h3>
	<p>User name <code>admin</code>, password <code data-ma="password">••••••••••••</code>
		<button type="button" data-ma-action="show">Show</button> <button type="button" data-ma-action="copy">Copy</button>
		<button type="button" data-ma-action="new-password">New password</button></p>
	<p class="mg-note" data-ma="no-admin" hidden>The app couldn't create the admin user (one already existed): log in with
		your own.</p>
	<p class="mg-note">Create a user for each person in Music Assistant (Settings → Users). Add your music with the "Local
		disk" provider, e.g. a folder under <code>/mnt/HD/HD_a2</code> (Music Assistant only reads it - the folder must be
		readable by everyone, as shares normally are), and streaming services (e.g. Spotify, YouTube Music) with theirs.</p>

	<h3>Players</h3>
	<table data-ma="players"></table>
	<p class="mg-note">Sonos speakers (and Chromecast, DLNA / UPnP, Squeezebox and other players on the network) are found
		by themselves once their provider is added in Music Assistant (Settings → Providers).</p>

	<details class="mg-section">
		<summary>Backups</summary>
		<p>Music Assistant's settings, library and users are backed up every night to <code data-ma="backup-dir">-</code>,
			keeping 7. The music itself isn't in them. Music Assistant is stopped for the copy (it keeps its databases
			locked while it runs), so playback pauses for a minute.</p>
		<p><button type="button" data-ma-action="backup">Back up now</button></p>
		<table data-ma="backups"></table>
	</details>

	<details class="mg-section">
		<summary>Music Assistant's latest warnings</summary>
		<pre data-ma="log"></pre>
	</details>

	<p data-ma="message"></p>

	<script>
	// Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
	(function () {
		var root = document.getElementById('music-assistant-manage');
		var api = '/apps/music-assistant/api.php';
		var csrf = <?php echo json_encode(manage_csrf_token('music-assistant')); ?>;
		<?php manage_secret_script(); ?>

		function part(name) { return root.querySelector('[data-ma="' + name + '"]'); }
		function button(name) { return root.querySelector('[data-ma-action="' + name + '"]'); }

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

		function fillPlayers(players, answering) {
			var table = part('players');
			table.textContent = '';
			if (!players) {
				table.insertRow().insertCell().textContent = answering ? 'Not available yet' : 'Music Assistant isn\'t running';
				return;
			}
			if (!players.length) {
				table.insertRow().insertCell().textContent = 'No players yet';
				return;
			}
			players.forEach(function (player) {
				var row = table.insertRow();
				row.insertCell().textContent = player.name;
				row.insertCell().textContent = player.provider;
				var state = row.insertCell();
				state.textContent = player.available ? (player.state || 'available') : 'unavailable';
				state.className = player.available ? 'mg-ok' : 'mg-bad';
			});
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
				status.textContent = !d.running ? 'Stopped' : (d.answering ? 'Running' : 'Starting… (the first start takes a minute or two)');
				status.className = d.running && d.answering ? 'mg-ok' : 'mg-bad';
				part('version').textContent = d.version || '-';
				var addresses = [];
				if (d.site.url) { addresses.push(d.site.url); }
				if (d.local_url) { addresses.push(d.local_url); }
				part('address').textContent = addresses.join(' or ') || '-';
				part('link').href = d.site.url || d.local_url || '#';
				fillPlayers(d.players, d.answering);
				part('no-admin').hidden = d.has_admin || !d.answering;
				part('backup-dir').textContent = d.backup_dir;
				fillBackups(d.backups);
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
			act('restart', { confirm: 1 }, 'Restarting Music Assistant…', 'Music Assistant restarted.');
		});

		// The admin password: Show / Hide and Copy (fetched when first needed)
		var password = mgSecret(part('password'), button('show'), button('copy'), function () {
			return call('password', { show: 1 }).then(function (d) { if (!d.ok) { say(d.error, false); return null; } return d.password; });
		});

		button('new-password').addEventListener('click', function () {
			if (!window.confirm('Give admin a new password? Apps logged in as admin need the new one.')) { return; }
			act('new_password', { confirm: 1 }, 'Setting a new password…', 'New password in use.').then(function (d) { if (d) { password.set(d.password); } });
		});

		button('backup').addEventListener('click', function () {
			if (!window.confirm('Back up now? Music Assistant stops for the copy, so playback pauses for a minute.')) { return; }
			act('backup', { confirm: 1 }, 'Backing up…', 'Backed up - Music Assistant is starting again.');
		});

		refresh();
	})();
	</script>
</div>
