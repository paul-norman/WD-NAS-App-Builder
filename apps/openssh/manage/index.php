<?php
// OpenSSH's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('openssh');
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="openssh-manage">
	<?php manage_styles('openssh-manage'); ?>
	<style>
		#openssh-manage textarea { width: 100%; max-width: 46rem; height: 5rem; font-family: monospace; font-size: 0.85em; }
		#openssh-manage pre { white-space: pre; font-size: 0.9em; background: #f6f6f6; padding: 0.5rem 0.75rem; max-width: 46rem; overflow-x: auto; }
		#openssh-manage [data-os="keys"] td:nth-child(3) { font-family: monospace; font-size: 0.85em; }
		#openssh-manage ol li { margin-bottom: 0.75rem; }
	</style>

	<h2>OpenSSH</h2>
	<table>
		<tr><td>Status</td><td data-os="status">…</td></tr>
		<tr><td>Version</td><td data-os="version">-</td></tr>
		<tr><td>Port</td><td data-os="port">-</td></tr>
		<tr><td>Password logins</td><td data-os="password-state">-</td></tr>
		<tr><td>The NAS's fingerprint</td><td data-os="host-keys">-</td></tr>
	</table>
	<p class="mg-bad" data-os="fallback" hidden></p>
	<p><button type="button" data-os-action="restart">Restart SSH</button></p>
	<p class="mg-note">SSH is still switched on and off in the dashboard (Settings → Network → SSH), and keeps WD's settings,
		host key and login: user <code>sshd</code> with the password set there. This app replaces the program behind it - and
		puts WD's back when it's switched off or removed. Open sessions stay connected when it restarts.</p>

	<h3>Keys</h3>
	<table data-os="keys"></table>
	<p><label>Public key<br><textarea data-os="new-key" spellcheck="false" autocomplete="off"
		placeholder="ssh-ed25519 AAAA… you@laptop"></textarea></label></p>
	<p><label>Name <input type="text" data-os="new-name" autocomplete="off" placeholder="e.g. Paul's laptop (optional)"></label>
		<button type="button" data-os-action="add-key">Add key</button></p>
	<p class="mg-note">Logging in with a key needs no password. Paste the <b>public</b> key (the <code>.pub</code> file - see
		"Connecting from your computer" below); the private key never leaves your computer. Keys added here are kept across
		reboots and reinstalls, and work straight away.</p>

	<h3>Password logins</h3>
	<p><label><input type="checkbox" data-os="passwords"> Allow logging in with the password</label>
		<button type="button" data-os-action="passwords">Save</button></p>
	<p class="mg-note">With password logins off, only the keys above can log in - nothing for anyone to guess. (It can only be
		turned off once there's a key.) SSH restarts.</p>
	<p class="mg-note"><b>From outside your home</b>, don't open SSH's port on your router: anyone on the internet can then
		try to log in (your NAS's log will show them trying). Use the WireGuard app to reach the NAS from anywhere instead.</p>

	<h3>Connecting from your computer</h3>
	<p><label>The NAS's address <input type="text" data-os="address" spellcheck="false"></label>
		<label>Name for it <input type="text" data-os="alias" spellcheck="false" value="nas" style="width: 8rem"></label></p>
	<ol>
		<li>Make a key for this computer (once - press Enter when it asks for a passphrase, or choose one):
			<pre data-os="keygen"></pre>
			<span class="mg-note">On Windows (PowerShell - OpenSSH is part of Windows 10 and 11):</span>
			<pre data-os="keygen-windows"></pre></li>
		<li>Show its public key, and paste it above (Add key):
			<pre data-os="show-key"></pre>
			<span class="mg-note">On Windows:</span>
			<pre data-os="show-key-windows"></pre></li>
		<li>Add this to your SSH configuration - <code>~/.ssh/config</code> (on Windows: <code>C:\Users\<i>you</i>\.ssh\config</code>,
			a file without an extension) - so that the NAS has a short name:
			<pre data-os="config"></pre>
			<button type="button" data-os-action="copy-config">Copy</button></li>
		<li>Then connect with its name - and files go back and forth over SFTP (also in apps such as FileZilla or WinSCP):
			<pre data-os="usage"></pre></li>
	</ol>
	<p class="mg-note">The first time, your computer asks whether to trust the NAS: check that the fingerprint it shows
		matches <span data-os="fingerprint-note">the NAS's, above</span>.</p>

	<details class="mg-section">
		<summary>SSH's log</summary>
		<pre data-os="log"></pre>
	</details>

	<p data-os="message"></p>

	<script>
	// Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
	(function () {
		var root = document.getElementById('openssh-manage');
		var api = '/apps/openssh/api.php';
		var csrf = <?php echo json_encode(manage_csrf_token('openssh')); ?>;
		var loaded = false;
		var port = 22;

		function part(name) { return root.querySelector('[data-os="' + name + '"]'); }
		function button(name) { return root.querySelector('[data-os-action="' + name + '"]'); }

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
				if (!d.ok) { say(d.error, false); refresh(); return null; }
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

		function keyRow(table, key, where, removable) {
			var row = table.insertRow();
			row.insertCell().textContent = key.comment || '(no name)';
			row.insertCell().textContent = key.type + (key.type === 'RSA' ? ' ' + key.bits : '');
			row.insertCell().textContent = key.fingerprint;
			row.insertCell().appendChild(el('span', where, 'mg-note'));
			var actions = row.insertCell();
			if (removable) {
				var remove = el('button', 'Remove');
				remove.type = 'button';
				remove.addEventListener('click', function () {
					if (!window.confirm('Remove the key "' + (key.comment || key.fingerprint) + '"? It can no longer log in.')) { return; }
					act('remove_key', { fingerprint: key.fingerprint }, 'Removing…', 'Key removed.');
				});
				actions.appendChild(remove);
			}
		}

		function fillKeys(d) {
			var table = part('keys');
			table.textContent = '';
			d.keys.forEach(function (key) { keyRow(table, key, 'added here', true); });
			d.home.keys.forEach(function (key) {
				keyRow(table, key, d.home.file + (d.home.kept ? '' : ' - lost when the NAS restarts'), false);
			});
			if (!d.keys.length && !d.home.keys.length) {
				table.insertRow().insertCell().textContent = 'No keys yet';
			}
		}

		// The commands and configuration for the address and name given
		function fillGuide() {
			var address = part('address').value.trim() || 'the-nas-address';
			var alias = part('alias').value.trim().replace(/[^A-Za-z0-9._-]/g, '') || 'nas';
			var key = alias + '_ed25519';
			part('keygen').textContent = 'ssh-keygen -t ed25519 -C "$(whoami)@$(hostname)" -f ~/.ssh/' + key;
			part('keygen-windows').textContent = 'ssh-keygen -t ed25519 -f $env:USERPROFILE\\.ssh\\' + key;
			part('show-key').textContent = 'cat ~/.ssh/' + key + '.pub';
			part('show-key-windows').textContent = 'type $env:USERPROFILE\\.ssh\\' + key + '.pub';
			part('config').textContent = 'Host ' + alias + '\n    HostName ' + address + (port !== 22 ? '\n    Port ' + port : '')
				+ '\n    User sshd\n    IdentityFile ~/.ssh/' + key + '\n    IdentitiesOnly yes\n';
			part('usage').textContent = 'ssh ' + alias + '\nsftp ' + alias + '\nscp photo.jpg ' + alias + ':/shares/Public/';
		}

		function refresh() {
			return call('status').then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				var status = part('status');
				if (d.listener === 'app') {
					status.textContent = 'Running OpenSSH ' + d.version + ' (sandbox: ' + (d.sandbox === 'seccomp' ? 'seccomp' : 'none - the NAS\'s kernel has no seccomp filters') + ')';
					status.className = 'mg-ok';
				} else if (d.listener === 'wd') {
					status.textContent = 'WD\'s own sshd is running, not this app\'s';
					status.className = 'mg-bad';
				} else {
					status.textContent = 'SSH is off - switch it on in the dashboard (Settings → Network → SSH)'
						+ (d.linked ? ': OpenSSH ' + d.version + ' starts then' : '');
					status.className = 'mg-bad';
				}
				part('version').textContent = 'OpenSSH ' + d.version + ' (the NAS\'s own: 8.4p1, from 2020)';
				port = d.port;
				part('port').textContent = d.port;
				part('password-state').textContent = d.passwords ? 'Allowed' : 'Off - keys only';
				part('host-keys').textContent = d.host_keys.length ? d.host_keys.map(function (k) { return k.fingerprint + ' (' + k.type + ')'; }).join(', ') : '-';
				part('fingerprint-note').textContent = d.host_keys.length ? d.host_keys[0].fingerprint : 'the NAS\'s, above';
				part('fallback').hidden = !d.fallback;
				part('fallback').textContent = d.fallback ? 'The app put WD\'s sshd back: ' + d.fallback + '. Restart SSH to try again.' : '';
				fillKeys(d);
				if (!loaded) {
					part('passwords').checked = d.passwords;
					part('address').value = window.location.hostname;
					loaded = true;
				}
				fillGuide();
				part('log').textContent = d.log.length ? d.log.join('\n') : 'Nothing logged';
			});
		}

		button('restart').addEventListener('click', function () {
			act('restart', { confirm: 1 }, 'Restarting SSH…', 'SSH restarted.');
		});

		button('add-key').addEventListener('click', function () {
			act('add_key', { key: part('new-key').value, name: part('new-name').value }, 'Adding the key…', '').then(function (d) {
				if (!d) { return; }
				say('Key added (' + d.type + ', ' + d.fingerprint + ') - it can log in now.', true);
				part('new-key').value = '';
				part('new-name').value = '';
			});
		});

		button('passwords').addEventListener('click', function () {
			var on = part('passwords').checked;
			if (!on && !window.confirm('Turn password logins off? Only the keys listed above can log in then.')) { return; }
			act('passwords', { on: on ? 1 : 0 }, 'Saving…', on ? 'Password logins are allowed - SSH restarted.' : 'Password logins are off: keys only - SSH restarted.');
		});

		button('copy-config').addEventListener('click', function () {
			var text = part('config').textContent;
			(navigator.clipboard ? navigator.clipboard.writeText(text) : Promise.reject()).then(function () {
				say('Copied.', true);
			}, function () {
				window.getSelection().selectAllChildren(part('config'));
				say('Selected - copy it with Ctrl+C.', true);
			});
		});

		['address', 'alias'].forEach(function (name) { part(name).addEventListener('input', fillGuide); });

		refresh();
	})();
	</script>
</div>
