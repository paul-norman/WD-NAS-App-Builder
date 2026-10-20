<?php
// PostgreSQL's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('postgresql');
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="postgresql-manage">
	<?php manage_styles('postgresql-manage'); ?>

	<h2>PostgreSQL</h2>
	<table>
		<tr><td>Status</td><td data-pg="status">…</td></tr>
		<tr><td>Connections</td><td data-pg="network">…</td></tr>
	</table>
	<p><label><input type="checkbox" data-pg="network-on"> Accept connections from the local network (with passwords)</label>
		<button type="button" data-pg-action="network">Save</button>
		<span class="mg-note">PostgreSQL restarts, disconnecting its clients.</span></p>
	<p data-pg="network-message"></p>

	<h3>Extensions</h3>
	<p>Included (add one to a database with <code>CREATE EXTENSION name;</code>): <strong>postgis</strong> (geometry and
		geography - no rasters) and postgis_topology, <strong>vector</strong> (pgvector), <strong>pg_cron</strong>,
		<strong>pg_partman</strong>, <strong>pgaudit</strong>, and PostgreSQL's own (pgcrypto, uuid-ossp, pg_trgm, hstore,
		citext, postgres_fdw, pg_stat_statements…).</p>
	<p>Loaded at start-up (needed before <code>CREATE EXTENSION</code>):
		<label><input type="checkbox" data-pg="pre-pg_cron"> pg_cron</label>
		<label><input type="checkbox" data-pg="pre-pgaudit"> pgaudit</label>
		<button type="button" data-pg-action="preload">Save</button>
		<span class="mg-note">PostgreSQL restarts. pg_cron's jobs live in the postgres database.</span></p>
	<p data-pg="preload-message"></p>

	<h3>Databases</h3>
	<table data-pg="databases"></table>
	<p><input type="text" data-pg="db-name" placeholder="New database" autocomplete="off" spellcheck="false">
		<input type="text" data-pg="db-user" placeholder="Its user (default: the same name)" autocomplete="off" spellcheck="false">
		<button type="button" data-pg-action="create">Create</button></p>
	<p data-pg="create-message"></p>
	<p class="mg-note">Each database gets a user of its own, with a generated password - shown once, so note it down.
		Names are lower case letters, digits and _.</p>

	<h3>The <code>postgres</code> superuser</h3>
	<p>Password: <code data-pg="password">••••••••••••</code> <button type="button" data-pg-action="show">Show</button></p>
	<p><input type="text" data-pg="new" placeholder="New password (leave empty to generate one)" autocomplete="off" spellcheck="false">
		<button type="button" data-pg-action="set">Change password</button></p>
	<p data-pg="password-message"></p>
	<p class="mg-note">Connect on port 5432 (the NAS's address, or localhost / the socket in /var/run/postgresql on the NAS).
		Over SSH: <code>PGPASSWORD=… psql -h /var/run/postgresql -U postgres</code>.</p>

	<script>
	// Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
	(function () {
		var root = document.getElementById('postgresql-manage');
		var api = '/apps/postgresql/api.php';
		var csrf = <?php echo json_encode(manage_csrf_token('postgresql')); ?>;

		function part(name) { return root.querySelector('[data-pg="' + name + '"]'); }
		function button(name) { return root.querySelector('[data-pg-action="' + name + '"]'); }

		function say(where, text, good) {
			var message = part(where);
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
				if (!d.ok) { say('network-message', d.error, false); return; }
				var status = part('status');
				status.textContent = d.running ? 'Running (PostgreSQL ' + d.version + ')' : 'Not running' + (d.error ? ': ' + d.error : '');
				status.className = d.running ? 'mg-ok' : 'mg-bad';
				part('network').textContent = d.network ? 'from the local network and the NAS' : 'from the NAS only';
				part('network-on').checked = d.network;
				part('pre-pg_cron').checked = d.preload.indexOf('pg_cron') !== -1;
				part('pre-pgaudit').checked = d.preload.indexOf('pgaudit') !== -1;
				var table = part('databases');
				table.textContent = '';
				var head = table.insertRow();
				['Database', 'Owner', 'Size'].forEach(function (text) { var c = head.insertCell(); c.textContent = text; c.style.fontWeight = 'bold'; });
				d.databases.forEach(function (db) {
					var row = table.insertRow();
					[db.name, db.owner, db.size].forEach(function (text) { row.insertCell().textContent = text; });
				});
			});
		}

		button('network').addEventListener('click', function () {
			say('network-message', 'Restarting PostgreSQL…', true);
			call('network', { on: part('network-on').checked ? 1 : '' }).then(function (d) {
				if (!d.ok) { say('network-message', d.error, false); return; }
				say('network-message', d.network ? 'PostgreSQL now accepts connections from the local network.' : 'PostgreSQL now only accepts connections from the NAS.', true);
				refresh();
			});
		});

		button('preload').addEventListener('click', function () {
			var data = new URLSearchParams();
			['pg_cron', 'pgaudit'].forEach(function (name) { if (part('pre-' + name).checked) { data.append('extensions[]', name); } });
			say('preload-message', 'Restarting PostgreSQL…', true);
			call('preload', data).then(function (d) {
				if (!d.ok) { say('preload-message', d.error, false); return; }
				say('preload-message', d.preload.length ? 'Loaded at start-up: ' + d.preload.join(', ') : 'No extensions loaded at start-up.', true);
				refresh();
			});
		});

		button('create').addEventListener('click', function () {
			call('create_database', { name: part('db-name').value, user: part('db-user').value }).then(function (d) {
				if (!d.ok) { say('create-message', d.error, false); return; }
				part('db-name').value = part('db-user').value = '';
				say('create-message', 'Created database ' + d.name + ' - user ' + d.user + ', password ' + d.password + ' (note it down: it isn\'t shown again).', true);
				refresh();
			});
		});

		button('show').addEventListener('click', function () {
			call('password', { show: 1 }).then(function (d) {
				if (d.ok) { part('password').textContent = d.password; } else { say('password-message', d.error, false); }
			});
		});

		button('set').addEventListener('click', function () {
			if (!window.confirm('Change the postgres password? Clients using it will need the new one.')) { return; }
			call('set_password', { password: part('new').value }).then(function (d) {
				if (!d.ok) { say('password-message', d.error, false); return; }
				part('new').value = '';
				part('password').textContent = d.password;
				say('password-message', 'Password changed.', true);
			});
		});

		refresh();
	})();
	</script>
</div>
