<?php
// copyparty's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('copyparty');
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="copyparty-manage">
	<?php manage_styles('copyparty-manage'); ?>
	<style>
		#copyparty-manage select { min-width: 12rem; }
		#copyparty-manage [data-cp="editor"] { border: 1px solid #ddd; padding: 0.5rem 1rem; margin: 0.5rem 0; }
	</style>

	<h2>copyparty</h2>
	<table>
		<tr><td>Status</td><td data-cp="status">…</td></tr>
		<tr><td>Version</td><td data-cp="version">-</td></tr>
		<tr><td>Address</td><td data-cp="address">-</td></tr>
	</table>
	<p><a class="mg-button" data-cp="link" href="#" target="_blank" rel="noopener">Open copyparty</a>
		<button type="button" data-cp-action="restart">Restart copyparty</button></p>

	<h3>Users</h3>
	<table data-cp="users"></table>
	<p><label>New user <input type="text" data-cp="new-user" spellcheck="false" autocomplete="off" placeholder="e.g. alice"></label>
		<button type="button" data-cp-action="add-user">Add user</button></p>
	<p class="mg-note">Everyone logs in with their user name and password (each gets a generated one). Who may see and
		change what is set for each folder below.</p>

	<h3>Shared folders</h3>
	<table data-cp="folders"></table>
	<p><button type="button" data-cp-action="add-folder">Share a folder</button></p>
	<div data-cp="editor" hidden>
		<p><label>Folder <input type="text" data-cp="path" spellcheck="false" size="40"
			placeholder="/mnt/HD/HD_a2/Public/Photos"></label></p>
		<p><label>Its address <code data-cp="address-base">/</code><input type="text" data-cp="name" spellcheck="false"
			placeholder="photos"></label></p>
		<table data-cp="access"></table>
		<p><button type="button" data-cp-action="save-folder">Save</button>
			<button type="button" data-cp-action="cancel-folder">Cancel</button></p>
		<p class="mg-note"><b>View</b>: browse and download. <b>Upload only</b>: a drop box - add files without seeing
			what's there. <b>View and upload</b>: both, without changing what's there. <b>Full</b>: also move, rename and
			delete. <b>Admin</b>: everything, plus who uploaded what and rescans. Everyone without a login can only be
			given View or Upload only.</p>
	</div>
	<p class="mg-note">copyparty runs as its own user, in the NAS's share group: it can use any share (they're open to
		that group), and what it adds can be changed over SMB too. Its database and thumbnails are kept with the app, not in
		the shares.</p>

	<h3>Settings</h3>
	<p><label><input type="checkbox" data-cp="local"> Only through the Nginx app (HTTPS)</label><br>
		<label><input type="checkbox" data-cp="sftp"> SFTP server <span data-cp="sftp-address"></span></label><br>
		<label><input type="checkbox" data-cp="tags"> Music tags (artist, album, title - searchable, and shown in its
			player; read from every music file once)</label></p>
	<p><button type="button" data-cp-action="settings">Save</button></p>
	<p class="mg-note">WebDAV is always on, at the same address (e.g. Windows' "Map network drive", macOS's "Connect to
		Server", or a phone's file manager). SFTP logs in with the same user names and passwords. copyparty restarts.</p>

	<details class="mg-section">
		<summary>copyparty's log</summary>
		<pre data-cp="log"></pre>
	</details>

	<p data-cp="message"></p>

	<script>
	// Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
	(function () {
		var root = document.getElementById('copyparty-manage');
		var api = '/apps/copyparty/api.php';
		var csrf = <?php echo json_encode(manage_csrf_token('copyparty')); ?>;
		<?php manage_secret_script(); ?>
		var LEVELS = [['none', 'No access'], ['read', 'View'], ['upload', 'Upload only'], ['write', 'View and upload'],
			['full', 'Full'], ['admin', 'Admin']];
		var state = { users: [], folders: [], editing: null };
		var loaded = false;

		function part(name) { return root.querySelector('[data-cp="' + name + '"]'); }
		function button(name) { return root.querySelector('[data-cp-action="' + name + '"]'); }

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
				refresh();
				return d;
			});
		}

		function el(tag, text, className) {
			var node = document.createElement(tag);
			if (text) { node.textContent = text; }
			if (className) { node.className = className; }
			return node;
		}

		function levelName(level) {
			for (var i = 0; i < LEVELS.length; i++) { if (LEVELS[i][0] === level) { return LEVELS[i][1]; } }
			return level;
		}

		function fillUsers(users) {
			var table = part('users');
			table.textContent = '';
			users.forEach(function (name) {
				var row = table.insertRow();
				row.insertCell().textContent = name;
				var cell = row.insertCell();
				var code = el('code', '••••••••••••');
				var show = el('button', 'Show');
				var copy = el('button', 'Copy');
				var fresh = el('button', 'New password');
				var remove = el('button', 'Remove');
				[show, copy, fresh, remove].forEach(function (b) { b.type = 'button'; });
				cell.appendChild(code);
				[show, copy, fresh, remove].forEach(function (b) { cell.appendChild(document.createTextNode(' ')); cell.appendChild(b); });
				var secret = mgSecret(code, show, copy, function () {
					return call('password', { name: name }).then(function (d) { if (!d.ok) { say(d.error, false); return null; } return d.password; });
				});
				fresh.addEventListener('click', function () {
					if (!window.confirm('Give ' + name + ' a new password? Their old one stops working.')) { return; }
					act('new_password', { name: name }, 'Setting a new password…', name + ' has a new password.').then(function (d) {
						if (d) { secret.set(d.password); }
					});
				});
				remove.addEventListener('click', function () {
					if (!window.confirm('Remove ' + name + '? Their files stay where they are.')) { return; }
					act('remove_user', { name: name }, 'Removing ' + name + '…', name + ' removed.');
				});
			});
		}

		function accessText(access) {
			var parts = [];
			Object.keys(access).forEach(function (who) {
				parts.push((who === '*' ? 'Everyone (no login)' : who) + ': ' + levelName(access[who]));
			});
			return parts.length ? parts.join(', ') : 'No one (not shared)';
		}

		function fillFolders(folders) {
			var table = part('folders');
			table.textContent = '';
			if (!folders.length) {
				table.insertRow().insertCell().textContent = 'No folders shared yet';
				return;
			}
			folders.forEach(function (folder) {
				var row = table.insertRow();
				row.insertCell().appendChild(el('code', '/' + folder.name + '/'));
				var cell = row.insertCell();
				cell.appendChild(el('div', folder.path));
				cell.appendChild(el('div', accessText(folder.access)));
				if (folder.can !== 'write') {
					cell.appendChild(el('div', folder.can === 'missing' ? 'This folder no longer exists'
						: (folder.can === 'read' ? 'copyparty can only read this folder: uploads to it will fail'
							: 'copyparty can\'t open this folder'), 'mg-bad'));
				}
				var actions = row.insertCell();
				var edit = el('button', 'Change');
				var remove = el('button', 'Stop sharing');
				edit.type = remove.type = 'button';
				actions.appendChild(edit);
				actions.appendChild(document.createTextNode(' '));
				actions.appendChild(remove);
				edit.addEventListener('click', function () { openEditor(folder); });
				remove.addEventListener('click', function () {
					if (!window.confirm('Stop sharing ' + folder.path + '? Its files stay where they are.')) { return; }
					act('remove_folder', { name: folder.name }, 'Updating…', folder.path + ' is no longer shared.');
				});
			});
		}

		// The folder editor: a new folder (null) or an existing one
		function openEditor(folder) {
			state.editing = folder ? folder.name : '';
			part('path').value = folder ? folder.path : '';
			part('name').value = folder ? folder.name : '';
			var access = folder ? folder.access : {};
			var table = part('access');
			table.textContent = '';
			state.users.concat(['*']).forEach(function (who) {
				var row = table.insertRow();
				row.insertCell().textContent = who === '*' ? 'Everyone (no login)' : who;
				var select = document.createElement('select');
				select.setAttribute('data-who', who);
				LEVELS.forEach(function (level) {
					if (who === '*' && ['none', 'read', 'upload'].indexOf(level[0]) < 0) { return; }
					var option = el('option', level[1]);
					option.value = level[0];
					select.appendChild(option);
				});
				// (a new folder: the admin user gets everything)
				select.value = access[who] || (!folder && who === 'admin' ? 'admin' : 'none');
				row.insertCell().appendChild(select);
			});
			part('editor').hidden = false;
			part('path').focus();
		}

		// A suggested address from the folder's own name (e.g. "Shared Pictures" -> shared-pictures)
		part('path').addEventListener('input', function () {
			if (state.editing) { return; }
			var last = part('path').value.replace(/\/+$/, '').split('/').pop() || '';
			part('name').value = last.toLowerCase().replace(/[^a-z0-9._-]+/g, '-').replace(/^[^a-z0-9]+|-+$/g, '').slice(0, 40);
		});

		button('add-folder').addEventListener('click', function () { openEditor(null); });
		button('cancel-folder').addEventListener('click', function () { part('editor').hidden = true; });

		button('save-folder').addEventListener('click', function () {
			var access = {};
			Array.prototype.forEach.call(part('access').querySelectorAll('select'), function (select) {
				access[select.getAttribute('data-who')] = select.value;
			});
			if (access['*'] && access['*'] !== 'none' && !window.confirm('Anyone who can reach copyparty will be able to '
				+ (access['*'] === 'read' ? 'see and download' : 'upload to') + ' this folder without logging in. Continue?')) { return; }
			act('save_folder', { old_name: state.editing || '', name: part('name').value, path: part('path').value,
				access: JSON.stringify(access) }, 'Saving…', 'Saved - copyparty restarted.').then(function (d) {
				if (d) { part('editor').hidden = true; }
			});
		});

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
				part('address-base').textContent = (d.site.url || d.local_url || '').replace(/\/$/, '') + '/';
				part('sftp-address').textContent = d.sftp && d.host ? '(sftp://' + (d.listen === 'local' ? '127.0.0.1' : d.host) + ':3922)' : '(port 3922)';
				// (the users' rows are only redrawn when users come or go, so that a shown password stays shown)
				if (d.users.join('\n') !== state.users.join('\n') || !part('users').rows.length) { fillUsers(d.users); }
				state.users = d.users;
				state.folders = d.folders;
				fillFolders(d.folders);
				if (!loaded) {
					part('local').checked = d.listen === 'local';
					part('sftp').checked = d.sftp;
					part('tags').checked = d.tags;
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
			act('restart', { confirm: 1 }, 'Restarting copyparty…', 'copyparty restarted.');
		});

		button('add-user').addEventListener('click', function () {
			var name = part('new-user').value.trim();
			act('add_user', { name: name }, 'Adding ' + name + '…', name + ' added - share folders with them below.').then(function (d) {
				if (d) { part('new-user').value = ''; }
			});
		});

		button('settings').addEventListener('click', function () {
			act('settings', { listen: part('local').checked ? 'local' : 'all', sftp: part('sftp').checked ? 1 : 0,
				tags: part('tags').checked ? 1 : 0 }, 'Saving…', 'Saved - copyparty restarted.');
		});

		refresh();
	})();
	</script>
</div>
