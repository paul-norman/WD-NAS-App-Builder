<?php
// Navidrome's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('navidrome');
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="navidrome-manage">
	<?php manage_styles('navidrome-manage'); ?>

	<h2>Navidrome (music)</h2>
	<table>
		<tr><td>Status</td><td data-nd="status">…</td></tr>
		<tr><td>Version</td><td data-nd="version">-</td></tr>
		<tr><td>Address</td><td data-nd="address">-</td></tr>
	</table>
	<p class="mg-note" data-nd="restart-note" hidden>The Nginx app's address for Navidrome has changed: restart Navidrome so
		that its share links use it.</p>
	<p><a class="mg-button" data-nd="link" href="#" target="_blank" rel="noopener">Open Navidrome</a>
		<button type="button" data-nd-action="restart">Restart Navidrome</button></p>

	<h3>Admin user</h3>
	<p>User name <code>admin</code>, password <code data-nd="password">••••••••••••</code>
		<button type="button" data-nd-action="show">Show</button> <button type="button" data-nd-action="copy">Copy</button>
		<button type="button" data-nd-action="new-password">New password</button></p>
	<p class="mg-note">Create a user for each person in Navidrome (Settings → Users). Phones use any Subsonic app (e.g.
		Symfonium, Tempo or Substreamer on Android, play:Sub or Amperfy on iPhone) with the address above and their own
		user name and password. This page logs in as admin with this password, so keep it as the app set it.</p>

	<h3>Music</h3>
	<table data-nd="libraries"></table>
	<p><button type="button" data-nd-action="scan">Scan for changes</button>
		<button type="button" data-nd-action="full-scan">Rescan everything</button></p>
	<p class="mg-note">New and changed files are picked up by themselves as they appear, and everything is checked once a
		day. More music folders can be added in Navidrome (Settings → Libraries).</p>

	<h3>Settings</h3>
	<p><label>Music folder <input type="text" data-nd="music-folder" spellcheck="false"
		placeholder="/mnt/HD/HD_a2/Public/Music"></label> <span data-nd="music-note"></span></p>
	<p><label><input type="checkbox" data-nd="local"> Only through the Nginx app (HTTPS)</label><br>
		<label><input type="checkbox" data-nd="external"> Artist images and biographies (from Deezer, Last.fm and
			ListenBrainz)</label></p>
	<p><button type="button" data-nd-action="settings">Save</button></p>
	<p class="mg-note">Navidrome only reads the music, as its own user: the folder must be readable by everyone (shares
		normally are). Navidrome restarts.</p>

	<details class="mg-section">
		<summary>Backups</summary>
		<p>Navidrome backs up its database (users, playlists, favourites, play counts) every night to
			<code data-nd="backup-dir">-</code>, keeping 7. The music itself isn't in them.</p>
		<table data-nd="backups"></table>
	</details>

	<details class="mg-section">
		<summary>Navidrome's latest warnings</summary>
		<pre data-nd="log"></pre>
	</details>

	<p data-nd="message"></p>

	<script>
	// Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
	(function () {
		var root = document.getElementById('navidrome-manage');
		var api = '/apps/navidrome/api.php';
		var csrf = <?php echo json_encode(manage_csrf_token('navidrome')); ?>;
		<?php manage_secret_script(); ?>
		var loaded = false;

		function part(name) { return root.querySelector('[data-nd="' + name + '"]'); }
		function button(name) { return root.querySelector('[data-nd-action="' + name + '"]'); }

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
			return bytes >= 1073741824 ? (bytes / 1073741824).toFixed(1) + ' GB'
				: (bytes >= 1048576 ? (bytes / 1048576).toFixed(1) + ' MB' : Math.max(1, Math.round(bytes / 1024)) + ' KB');
		}

		function when(text) {
			var date = new Date(text);
			return !text || date.getFullYear() < 2000 ? 'never' : date.toLocaleString();
		}

		function fillLibraries(libraries, running) {
			var table = part('libraries');
			table.textContent = '';
			if (!libraries) {
				table.insertRow().insertCell().textContent = running
					? 'Can\'t log in to Navidrome as admin with the password above (make a new one to fix it)' : 'Navidrome isn\'t running';
				return;
			}
			libraries.forEach(function (library) {
				var row = table.insertRow();
				row.insertCell().textContent = library.name;
				row.insertCell().textContent = library.path;
				row = table.insertRow();
				row.insertCell();
				row.insertCell().textContent = library.songs + ' songs, ' + library.albums + ' albums, ' + library.artists
					+ ' artists (' + size(library.size) + ') - ' + (library.scanning ? 'scanning…' : 'last scan: ' + when(library.last_scan));
			});
		}

		function fillBackups(backups) {
			var table = part('backups');
			table.textContent = '';
			if (!backups.length) {
				table.insertRow().insertCell().textContent = 'No backups yet (the first is made tonight)';
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
				part('version').textContent = d.version || '-';
				var addresses = [];
				if (d.site.url) { addresses.push(d.site.url); }
				if (d.listen !== 'local' && d.local_url) { addresses.push(d.local_url); }
				part('address').textContent = addresses.join(' or ') || '-';
				part('link').href = d.site.url || d.local_url || '#';
				part('restart-note').hidden = !d.restart_needed;
				fillLibraries(d.libraries, d.running && d.answering);
				var note = part('music-note');
				note.textContent = d.music_readable ? '' : 'Navidrome can\'t read this folder';
				note.className = 'mg-bad';
				part('backup-dir').textContent = d.backup_dir;
				fillBackups(d.backups);
				if (!loaded) {
					part('music-folder').value = d.music_folder;
					part('local').checked = d.listen === 'local';
					part('external').checked = d.external;
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
			act('restart', { confirm: 1 }, 'Restarting Navidrome…', 'Navidrome restarted.');
		});

		button('scan').addEventListener('click', function () {
			act('scan', { full: 0 }, 'Starting a scan…', 'Scanning for changes.');
		});

		button('full-scan').addEventListener('click', function () {
			act('scan', { full: 1 }, 'Starting a full scan…', 'Rescanning everything - it can take a while for a large collection.');
		});

		// The admin password: Show / Hide and Copy (fetched when first needed)
		var password = mgSecret(part('password'), button('show'), button('copy'), function () {
			return call('password', { show: 1 }).then(function (d) { if (!d.ok) { say(d.error, false); return null; } return d.password; });
		});

		button('new-password').addEventListener('click', function () {
			if (!window.confirm('Give admin a new password? Apps logged in as admin need the new one.')) { return; }
			act('new_password', { confirm: 1 }, 'Setting a new password…', 'New password in use.').then(function (d) { if (d) { password.set(d.password); } });
		});

		button('settings').addEventListener('click', function () {
			act('settings', { music_folder: part('music-folder').value, listen: part('local').checked ? 'local' : 'all',
				external: part('external').checked ? 1 : 0 }, 'Saving…', 'Saved - Navidrome restarted.');
		});

		refresh();
	})();
	</script>
</div>
