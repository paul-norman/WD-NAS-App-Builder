<?php
// Calibre-Web's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('calibre-web');
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="calibre-web-manage">
	<?php manage_styles('calibre-web-manage'); ?>

	<h2>Calibre-Web</h2>
	<table>
		<tr><td>Status</td><td data-cw="status">…</td></tr>
		<tr><td>Versions</td><td data-cw="versions">-</td></tr>
		<tr><td>Address</td><td data-cw="address">-</td></tr>
		<tr><td>OPDS catalogue</td><td data-cw="opds">-</td></tr>
	</table>
	<p><a class="mg-button" data-cw="link" href="#" target="_blank" rel="noopener">Open Calibre-Web</a>
		<button type="button" data-cw-action="restart">Restart Calibre-Web</button></p>
	<p class="mg-note">E-reader apps (e.g. KOReader, Moon+ Reader, Marvin) can browse and download from the OPDS catalogue, with a
		Calibre-Web user name and password. Kobo e-readers can sync with Calibre-Web directly: turn on Kobo sync in Calibre-Web
		(Admin → Edit basic configuration → Feature configuration), then follow the instructions on your user's profile page.</p>

	<h3>Admin user</h3>
	<p>User name <code>admin</code>, password <code data-cw="password">••••••••••••</code>
		<button type="button" data-cw-action="show">Show</button> <button type="button" data-cw-action="copy">Copy</button>
		<button type="button" data-cw-action="new-password">New password</button></p>
	<p class="mg-note">Create a user for each person in Calibre-Web (Admin → Add new user), with what each may do (download,
		upload, edit, convert...). To send books to e-readers by email (e.g. a Kindle's address), set an email server in
		Calibre-Web (Admin → Edit email server settings).</p>

	<h3>Library</h3>
	<table>
		<tr><td>Folder</td><td data-cw="library">-</td></tr>
		<tr><td>Books</td><td data-cw="books">-</td></tr>
	</table>
	<p><label>Use the library in <input type="text" data-cw="library-folder" spellcheck="false"
		placeholder="/mnt/HD/HD_a2/Public/Books/Calibre Library"></label> <button type="button" data-cw-action="library">Use</button></p>
	<p class="mg-note">An existing Calibre library (a folder with <code>metadata.db</code>, e.g. copied from Calibre on a computer),
		or an empty or new folder - a new library is made in it. Calibre-Web becomes its owner: change it only through
		Calibre-Web (or the ingest folder below), not with Calibre on a computer at the same time. Calibre-Web restarts.</p>

	<h3>Ingest folder</h3>
	<p><label><input type="checkbox" data-cw="ingest"> Add the books copied into</label>
		<input type="text" data-cw="ingest-folder" spellcheck="false" placeholder="/mnt/HD/HD_a2/Public/Books/Add to library"></p>
	<p><label><input type="checkbox" data-cw="ingest-convert"> Also make an EPUB of books in other formats</label></p>
	<p><button type="button" data-cw-action="ingest-save">Save</button></p>
	<p class="mg-note">Copy books into this folder (e.g. over the network) and they're added to the library within a couple of
		minutes, then moved into its <code>Added</code> folder - or <code>Not added</code>, with a note saying why (e.g. already in
		the library). <span data-cw="waiting"></span></p>
	<details>
		<summary>Latest results</summary>
		<pre data-cw="ingest-log"></pre>
	</details>

	<h3>Settings</h3>
	<p><label><input type="checkbox" data-cw="local"> Only through the Nginx app (HTTPS)</label></p>
	<p><button type="button" data-cw-action="settings">Save</button></p>

	<details class="mg-section">
		<summary>Backups</summary>
		<p>Every night, Calibre-Web's settings and users (<code>app.db</code>) and the library's database (<code>metadata.db</code>
			- the books' details, not the book files) are backed up to <code data-cw="backup-dir">-</code>, keeping 7 days.</p>
		<table data-cw="backups"></table>
	</details>

	<details class="mg-section">
		<summary>Calibre-Web's latest warnings</summary>
		<pre data-cw="log"></pre>
	</details>

	<p data-cw="message"></p>

	<script>
	// Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
	(function () {
		var root = document.getElementById('calibre-web-manage');
		var api = '/apps/calibre-web/api.php';
		var csrf = <?php echo json_encode(manage_csrf_token('calibre-web')); ?>;
		<?php manage_secret_script(); ?>
		var loaded = false;

		function part(name) { return root.querySelector('[data-cw="' + name + '"]'); }
		function button(name) { return root.querySelector('[data-cw-action="' + name + '"]'); }

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
				row.insertCell().textContent = size(backup.size);
			});
		}

		function refresh() {
			return call('status').then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				var status = part('status');
				status.textContent = !d.running ? 'Stopped' : (d.answering ? 'Running' : 'Starting…');
				status.className = d.running && d.answering ? 'mg-ok' : 'mg-bad';
				var v = d.versions;
				part('versions').textContent = v.calibre_web ? 'Calibre-Web ' + v.calibre_web + ', Calibre ' + (v.calibre || '?') + ' (converter), kepubify ' + (v.kepubify || '?') : '-';
				var addresses = [];
				if (d.site.url) { addresses.push(d.site.url); }
				if (d.listen !== 'local' && d.local_url) { addresses.push(d.local_url); }
				part('address').textContent = addresses.join(' or ') || '-';
				part('opds').textContent = d.opds || '-';
				part('link').href = d.site.url || d.local_url || '#';
				part('library').textContent = d.library + (d.library_ok ? '' : ' (not created yet - Calibre-Web creates it when it starts)');
				part('books').textContent = d.books === null ? '-' : d.books;
				part('waiting').textContent = d.ingest && d.ingest_waiting ? d.ingest_waiting + ' file(s) waiting.' : '';
				part('ingest-log').textContent = d.ingest_log.length ? d.ingest_log.join('\n') : 'Nothing yet';
				part('backup-dir').textContent = d.backup_dir;
				fillBackups(d.backups);
				if (!loaded) {
					part('library-folder').value = d.library;
					part('ingest').checked = d.ingest;
					part('ingest-folder').value = d.ingest_folder;
					part('ingest-convert').checked = d.ingest_convert === 'epub';
					part('local').checked = d.listen === 'local';
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
			act('restart', { confirm: 1 }, 'Restarting Calibre-Web…', 'Calibre-Web restarted.');
		});

		button('library').addEventListener('click', function () {
			var folder = part('library-folder').value.trim();
			if (!window.confirm('Use the library in ' + folder + '?\n\nCalibre-Web restarts, and becomes the owner of that folder.')) { return; }
			act('library', { library: folder }, 'Setting up the library…', 'Calibre-Web now uses ' + folder + '.');
		});

		// The admin password: Show / Hide and Copy (fetched when first needed)
		var password = mgSecret(part('password'), button('show'), button('copy'), function () {
			return call('password', { show: 1 }).then(function (d) { if (!d.ok) { say(d.error, false); return null; } return d.password; });
		});

		button('new-password').addEventListener('click', function () {
			if (!window.confirm('Give admin a new password? Apps logged in as admin need the new one.')) { return; }
			act('new_password', { confirm: 1 }, 'Setting a new password…', 'New password in use.').then(function (d) { if (d) { password.set(d.password); } });
		});

		function saveSettings() {
			act('settings', { listen: part('local').checked ? 'local' : 'all', ingest: part('ingest').checked ? 1 : 0,
				ingest_folder: part('ingest-folder').value, ingest_convert: part('ingest-convert').checked ? 'epub' : 'none' },
				'Saving…', 'Saved.').then(function (d) { if (d && d.restarted) { say('Saved - Calibre-Web restarted.', true); } });
		}
		button('settings').addEventListener('click', saveSettings);
		button('ingest-save').addEventListener('click', saveSettings);

		refresh();
	})();
	</script>
</div>
