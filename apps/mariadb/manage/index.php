<?php
// The MariaDB app's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('mariadb');
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="mariadb-manage">
	<?php manage_styles('mariadb-manage'); ?>
	<style>
		#mariadb-manage pre { background: rgba(127, 127, 127, 0.15); border-radius: 4px; padding: 0.5rem; max-height: 16rem; overflow: auto; white-space: pre-wrap; font-size: 0.8em; }
	</style>

	<h2>MariaDB</h2>
	<table>
		<tr><td>Running</td><td data-md="version">…</td></tr>
		<tr><td>Data</td><td data-md="data">…</td></tr>
		<tr><td>WD's own data</td><td data-md="wd">…</td></tr>
	</table>
	<p class="mg-note">MariaDB 11.8 runs on a copy of WD's data (made the first time), so WD's own stays untouched: disable
		the app to switch the NAS back to WD's MariaDB 10.5 with it (anything changed under 11.8 stays in the copy). It
		listens where WD's did (the NAS only, socket /var/lib/mysql/mysql.sock, port 3306), so phpMyAdmin works as before.</p>

	<h3>Warnings and errors (since it last started)</h3>
	<pre data-md="problems">…</pre>

	<p data-md="message"></p>

	<script>
	// Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
	(function () {
		var root = document.getElementById('mariadb-manage');
		function part(name) { return root.querySelector('[data-md="' + name + '"]'); }

		fetch('/apps/mariadb/api.php?action=status', { credentials: 'same-origin', headers: { 'X-Requested-With': 'XMLHttpRequest' } })
			.then(function (response) { return response.json(); })
			.then(function (d) {
				if (!d.ok) { part('message').textContent = d.error; part('message').className = 'mg-bad'; return; }
				var version = part('version');
				version.textContent = !d.running ? 'not running' : d.version + (d.app_server ? '' : ' (WD\'s own)');
				version.className = d.running && d.app_server ? 'mg-ok' : 'mg-bad';
				part('data').textContent = d.app_server ? d.copy + (d.copy_size ? ' (' + d.copy_size + ')' : '') : 'WD\'s own';
				part('wd').textContent = d.wd_datadir || '-';
				part('problems').textContent = d.problems.length ? d.problems.join('\n') : 'None.';
			});
	})();
	</script>
</div>
