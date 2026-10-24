<?php
// Audiobookshelf's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('audiobookshelf');
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="audiobookshelf-manage">
	<?php manage_styles('audiobookshelf-manage'); ?>

	<h2>Audiobookshelf</h2>
	<table>
		<tr><td>Status</td><td data-ab="status">…</td></tr>
		<tr><td>Version</td><td data-ab="version">-</td></tr>
		<tr><td>Address</td><td data-ab="address">-</td></tr>
	</table>
	<p><a class="mg-button" data-ab="link" href="#" target="_blank" rel="noopener">Open Audiobookshelf</a>
		<button type="button" data-ab-action="restart">Restart Audiobookshelf</button></p>

	<h3>Root user</h3>
	<p>User name <code>root</code>, password <code data-ab="password">••••••••••••</code>
		<button type="button" data-ab-action="show">Show</button> <button type="button" data-ab-action="copy">Copy</button>
		<button type="button" data-ab-action="new-password">New password</button></p>
	<p class="mg-note">The app created this administrator when Audiobookshelf first started, so that no one else could.
		Create a user for each person in Audiobookshelf (Settings → Users), and log in to its phone apps with those. This
		page logs in as root with this password, so keep it as the app set it.</p>

	<h3>Libraries</h3>
	<table data-ab="libraries"></table>
	<p class="mg-note">Libraries are added in Audiobookshelf (Settings → Libraries): a folder of audiobooks (one folder per
		book, e.g. <code>Audiobooks/Author/Title</code>) or of podcasts. Audiobookshelf runs as its own user in the NAS's
		share group: it can read any share, and what it writes there (podcast episodes, merged M4B files) can be changed over
		SMB too. New files are picked up as they appear.</p>

	<h3>Settings</h3>
	<p><label><input type="checkbox" data-ab="local"> Only through the Nginx app (HTTPS)</label></p>
	<p><label>Podcast feeds on your own network <input type="text" data-ab="local-feeds" spellcheck="false"
		placeholder="e.g. 192.168.1.20, podcasts.home"></label></p>
	<p><button type="button" data-ab-action="settings">Save</button></p>
	<p class="mg-note">The Audiobookshelf apps for Android and iPhone connect to the address above. Podcast feeds on the
		internet always work; Audiobookshelf only fetches from addresses on your own network when they're listed here (it
		refuses them otherwise, so that a feed can't reach the NAS's own services). Audiobookshelf restarts.</p>

	<details class="mg-section">
		<summary>Audiobookshelf's latest warnings</summary>
		<pre data-ab="log"></pre>
	</details>

	<p data-ab="message"></p>

	<script>
	// Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
	(function () {
		var root = document.getElementById('audiobookshelf-manage');
		var api = '/apps/audiobookshelf/api.php';
		var csrf = <?php echo json_encode(manage_csrf_token('audiobookshelf')); ?>;
		<?php manage_secret_script(); ?>
		var loaded = false;

		function part(name) { return root.querySelector('[data-ab="' + name + '"]'); }
		function button(name) { return root.querySelector('[data-ab-action="' + name + '"]'); }

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

		function act(action, data, working, done) {
			say(working, true);
			return call(action, data).then(function (d) {
				if (!d.ok) { say(d.error, false); return null; }
				say(done, true);
				setTimeout(refresh, 2000);
				return d;
			});
		}

		function fillLibraries(libraries, answering, known) {
			var table = part('libraries');
			table.textContent = '';
			if (!libraries) {
				table.insertRow().insertCell().textContent = !answering ? 'Audiobookshelf isn\'t running'
					: (known ? 'Can\'t log in to Audiobookshelf as root with the password above (make a new one to fix it)'
						: 'The root user was made elsewhere: its password isn\'t known to this page');
				return;
			}
			if (!libraries.length) {
				table.insertRow().insertCell().textContent = 'No libraries yet - add one in Audiobookshelf (Settings → Libraries)';
				return;
			}
			libraries.forEach(function (library) {
				var row = table.insertRow();
				row.insertCell().textContent = library.name;
				row.insertCell().textContent = (library.type === 'podcast' ? 'Podcasts' : 'Books')
					+ (library.items === null ? '' : ' - ' + library.items + (library.items === 1 ? ' item' : ' items'));
				var cell = row.insertCell();
				library.folders.forEach(function (folder) {
					var line = document.createElement('div');
					line.textContent = folder.path + (folder.can === 'none' ? ' - Audiobookshelf can\'t open this folder'
						: (folder.can === 'read' && library.type === 'podcast' ? ' - Audiobookshelf can\'t write here: new episodes will fail' : ''));
					if (folder.can === 'none' || (folder.can === 'read' && library.type === 'podcast')) { line.className = 'mg-bad'; }
					cell.appendChild(line);
				});
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
				fillLibraries(d.libraries, d.answering, d.password_known);
				if (!loaded) {
					part('local').checked = d.listen === 'local';
					part('local-feeds').value = d.local_feeds;
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

		button('restart').addEventListener('click', function () {
			act('restart', { confirm: 1 }, 'Restarting Audiobookshelf…', 'Audiobookshelf restarted.');
		});

		// The root password: Show / Hide and Copy (fetched when first needed)
		var password = mgSecret(part('password'), button('show'), button('copy'), function () {
			return call('password', { show: 1 }).then(function (d) {
				if (!d.ok) { say(d.error, false); return null; }
				return d.password || 'not known (made elsewhere)';
			});
		});

		button('new-password').addEventListener('click', function () {
			if (!window.confirm('Give root a new password? Apps logged in as root need the new one.')) { return; }
			act('new_password', { confirm: 1 }, 'Setting a new password…', 'New password in use.').then(function (d) { if (d) { password.set(d.password); } });
		});

		button('settings').addEventListener('click', function () {
			act('settings', { listen: part('local').checked ? 'local' : 'all', local_feeds: part('local-feeds').value }, 'Saving…', 'Saved - Audiobookshelf restarted.');
		});

		refresh();
	})();
	</script>
</div>
