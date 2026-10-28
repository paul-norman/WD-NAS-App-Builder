<?php
// Icecast's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('icecast');
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="icecast-manage">
	<?php manage_styles('icecast-manage'); ?>

	<h2>Icecast</h2>
	<table>
		<tr><td>Status</td><td data-ic="status">…</td></tr>
		<tr><td>Version</td><td data-ic="version">-</td></tr>
		<tr><td>Address</td><td data-ic="address">-</td></tr>
	</table>
	<p><a class="mg-button" data-ic="link" href="#" target="_blank" rel="noopener">Open Icecast</a>
		<button type="button" data-ic-action="restart">Restart Icecast</button></p>

	<h3>Passwords</h3>
	<table>
		<tr><td>Admin</td><td>user <code>admin</code>, password <code data-ic="admin-password">••••••••••••</code>
			<button type="button" data-ic-action="admin-show">Show</button> <button type="button" data-ic-action="admin-copy">Copy</button>
			<button type="button" data-ic-action="admin-new">New password</button></td></tr>
		<tr><td>Broadcasting</td><td>user <code>source</code>, password <code data-ic="source-password">••••••••••••</code>
			<button type="button" data-ic-action="source-show">Show</button> <button type="button" data-ic-action="source-copy">Copy</button>
			<button type="button" data-ic-action="source-new">New password</button></td></tr>
	</table>
	<p class="mg-note">Admin: Icecast's own admin pages (listeners, moving them between streams, kicking a stream off).
		Broadcasting: what software sending a stream to Icecast logs in with (see below). A new password restarts Icecast.</p>

	<h3>On air</h3>
	<table data-ic="mounts"></table>

	<h3>Station from a folder</h3>
	<p><label><input type="checkbox" data-ic="autodj"> Broadcast a folder of music from the NAS, around the clock</label></p>
	<p><label>Music folder <input type="text" data-ic="music-folder" spellcheck="false" placeholder="/mnt/HD/HD_a2/Public/Shared Music"></label>
		<span data-ic="music-note"></span></p>
	<p><label>Its address <code data-ic="mount-base">/</code><input type="text" data-ic="mount" spellcheck="false" placeholder="radio" style="width: 10rem"></label>
		<label>Quality <select data-ic="bitrate">
			<option value="64">64 kbps (MP3)</option><option value="96">96 kbps (MP3)</option><option value="128">128 kbps (MP3)</option>
			<option value="192">192 kbps (MP3)</option><option value="256">256 kbps (MP3)</option><option value="320">320 kbps (MP3)</option>
		</select></label>
		<label><input type="checkbox" data-ic="shuffle"> Shuffle</label></p>
	<p><label>Station name <input type="text" data-ic="station-name" maxlength="60"></label></p>
	<p><label>Description <input type="text" data-ic="station-description" maxlength="200" style="width: 34rem"></label></p>
	<p><button type="button" data-ic-action="save">Save</button>
		<button type="button" data-ic-action="skip">Next track</button>
		<button type="button" data-ic-action="rescan">Find new music</button></p>
	<p class="mg-note" data-ic="tracks"></p>
	<p class="mg-note">Every music file in the folder and its subfolders is played (MP3, FLAC, Ogg, Opus, AAC/M4A, WAV, WMA,
		APE, WavPack...), turned into one MP3 stream with each track's artist and title. New music is found every night, or
		straight away with "Find new music". The folder must be readable by everyone (shares normally are).</p>

	<h3>Broadcasting live</h3>
	<p>From a PC with broadcasting software (e.g. <a href="https://danielnoethen.de/butt/" target="_blank" rel="noopener">BUTT</a>,
		Mixxx or OBS): server <code data-ic="live-server">-</code>, port <code>8010</code>, mount point e.g.
		<code>/live</code> (any but the station's), user <code>source</code> and the broadcasting password above. Listeners
		tune in at the mount point's address while it's on air.</p>

	<h3>Settings</h3>
	<p><label><input type="checkbox" data-ic="local"> Only through the Nginx app (HTTPS) - live broadcasts from other
		computers then can't connect</label></p>
	<p><label>Listeners at once (each stream) <input type="number" data-ic="max-listeners" min="1" max="500" style="width: 7rem"></label></p>
	<p><button type="button" data-ic-action="save-settings">Save</button></p>
	<p class="mg-note">Each listener takes the stream's quality in upload bandwidth (e.g. 10 listeners at 128 kbps: about
		1.3 Mbit/s). Listeners on the internet need the Nginx app's address, or your router to pass port 8010 on to the NAS.
		Icecast restarts.</p>

	<details class="mg-section">
		<summary>Icecast's log</summary>
		<pre data-ic="log"></pre>
	</details>

	<p data-ic="message"></p>

	<script>
	// Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
	(function () {
		var root = document.getElementById('icecast-manage');
		var api = '/apps/icecast/api.php';
		var csrf = <?php echo json_encode(manage_csrf_token('icecast')); ?>;
		<?php manage_secret_script(); ?>
		var loaded = false;
		var base = '';

		function part(name) { return root.querySelector('[data-ic="' + name + '"]'); }
		function button(name) { return root.querySelector('[data-ic-action="' + name + '"]'); }

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

		function fillMounts(mounts, running) {
			var table = part('mounts');
			table.textContent = '';
			if (!mounts.length) {
				table.insertRow().insertCell().textContent = running ? 'Nothing on air' : 'Icecast isn\'t running';
				return;
			}
			mounts.forEach(function (mount) {
				var row = table.insertRow();
				var link = document.createElement('a');
				link.href = base + mount.mount;
				link.target = '_blank';
				link.rel = 'noopener';
				link.textContent = base + mount.mount;
				row.insertCell().appendChild(link);
				row.insertCell().textContent = (mount.name ? mount.name + ': ' : '') + (mount.title || '-');
				row.insertCell().textContent = mount.listeners + (mount.listeners === 1 ? ' listener' : ' listeners')
					+ ' (most: ' + mount.peak + ')';
			});
		}

		function refresh() {
			return call('status').then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				var s = d.settings;
				var status = part('status');
				status.textContent = !d.running ? 'Stopped' : 'Running' + (s.autodj ? (d.station_running ? ', the station is on air' : ', the station isn\'t playing') : '');
				status.className = d.running && (!s.autodj || d.station_running) ? 'mg-ok' : 'mg-bad';
				part('version').textContent = d.version || '-';
				var addresses = [];
				if (d.site.url) { addresses.push(d.site.url); }
				if (s.listen !== 'local' && d.local_url) { addresses.push(d.local_url); }
				part('address').textContent = addresses.join(' or ') || '-';
				base = (d.site.url || d.local_url || '').replace(/\/$/, '');
				part('link').href = base ? base + '/' : '#';
				part('mount-base').textContent = base + '/';
				part('live-server').textContent = s.listen === 'local' ? '(not reachable: only through the Nginx app)' : (d.host || 'the NAS\'s address');
				fillMounts(d.mounts, d.running);
				part('tracks').textContent = s.autodj ? d.tracks + ' tracks in the playlist' : '';
				var note = part('music-note');
				note.textContent = d.music_readable ? '' : 'Icecast can\'t read this folder';
				note.className = 'mg-bad';
				if (!loaded) {
					part('autodj').checked = s.autodj;
					part('music-folder').value = s.music_folder;
					part('mount').value = s.mount;
					part('bitrate').value = String(s.bitrate);
					part('shuffle').checked = s.shuffle;
					part('station-name').value = s.station_name;
					part('station-description').value = s.station_description;
					part('local').checked = s.listen === 'local';
					part('max-listeners').value = s.max_listeners;
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

		// The passwords: Show / Hide and Copy (fetched when first needed), and new ones
		['admin', 'source'].forEach(function (name) {
			var secret = mgSecret(part(name + '-password'), button(name + '-show'), button(name + '-copy'), function () {
				return call('password', { name: name }).then(function (d) { if (!d.ok) { say(d.error, false); return null; } return d.password; });
			});
			button(name + '-new').addEventListener('click', function () {
				var what = name === 'admin' ? 'Icecast\'s admin pages' : 'broadcasting (software sending live streams needs the new one)';
				if (!window.confirm('A new password for ' + what + '? Icecast restarts.')) { return; }
				act('new_password', { name: name }, 'Setting a new password…', 'New password in use - Icecast restarted.').then(function (d) {
					if (d) { secret.set(d.password); }
				});
			});
		});

		function save() {
			act('settings', { autodj: part('autodj').checked ? 1 : 0, music_folder: part('music-folder').value,
				mount: part('mount').value, bitrate: part('bitrate').value, shuffle: part('shuffle').checked ? 1 : 0,
				station_name: part('station-name').value, station_description: part('station-description').value,
				listen: part('local').checked ? 'local' : 'all', max_listeners: part('max-listeners').value },
				'Saving…', 'Saved - Icecast restarted.');
		}
		button('save').addEventListener('click', save);
		button('save-settings').addEventListener('click', save);

		button('skip').addEventListener('click', function () {
			act('skip', { confirm: 1 }, 'Skipping…', 'Playing the next track.');
		});
		button('rescan').addEventListener('click', function () {
			act('rescan', { confirm: 1 }, 'Looking for new music…', 'The playlist is up to date.');
		});
		button('restart').addEventListener('click', function () {
			act('restart', { confirm: 1 }, 'Restarting Icecast…', 'Icecast restarted.');
		});

		refresh();
	})();
	</script>
</div>
