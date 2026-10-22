<?php
// The Python app's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('python');
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="python-manage">
	<?php manage_styles('python-manage'); ?>

	<h2>Python</h2>
	<table>
		<tr><td>python3</td><td data-py="active">…</td></tr>
		<tr><td>The app's Python</td><td data-py="app">-</td></tr>
		<tr><td>WD's Python</td><td data-py="wd">-</td></tr>
		<tr><td>pip / uv</td><td data-py="tools">-</td></tr>
		<tr><td>Commands</td><td data-py="links">-</td></tr>
	</table>
	<p><button type="button" data-py-action="use-app">Use the app's Python</button>
		<button type="button" data-py-action="use-wd">Use WD's Python 3.9</button></p>
	<p class="mg-note">WD's boot scripts and its Windows network discovery (wsdd<span data-py="wsdd"></span>) start before
		the apps, so they always run on WD's own Python. The choice is kept across reboots and reinstalls.</p>

	<h3>Packages</h3>
	<p>Packages go in a virtual environment (packages installed into the app's Python itself would be lost with its next
		update), kept wherever you like - e.g. under <code>/home/root</code> (persistent with the Entware app) or on a
		share:</p>
	<pre>python3 -m venv /home/root/venvs/myproject
/home/root/venvs/myproject/bin/pip install requests
/home/root/venvs/myproject/bin/python myscript.py</pre>
	<p>Or with uv, which also runs tools and single scripts with their own packages:</p>
	<pre>uv venv /home/root/venvs/myproject
uvx ruff check myscript.py
uv run --with requests myscript.py</pre>
	<p class="mg-note">Virtual environments use the app's Python, so they keep working across the app's updates within
		3.14 (a new 3.x line needs them made again). The NAS has no compiler: packages are installed from ready-built
		wheels, which almost all popular packages have.</p>

	<p data-py="message"></p>

	<script>
	// Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
	(function () {
		var root = document.getElementById('python-manage');
		var api = '/apps/python/api.php';
		var csrf = <?php echo json_encode(manage_csrf_token('python')); ?>;

		function part(name) { return root.querySelector('[data-py="' + name + '"]'); }
		function button(name) { return root.querySelector('[data-py-action="' + name + '"]'); }

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

		function refresh() {
			return call('status').then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				var active = part('active');
				active.textContent = (d.active || '-') + (d.app_active ? ' (the app\'s)' : ' (WD\'s)');
				active.className = d.app_active ? 'mg-ok' : '';
				part('app').textContent = d.app_version || 'not found';
				part('wd').textContent = d.wd_version || 'not found';
				part('tools').textContent = [d.pip, d.uv].filter(Boolean).join(', ') || '-';
				part('links').textContent = d.links.length ? d.links.join(', ') : 'none (WD\'s python3 only)';
				part('wsdd').textContent = d.wsdd ? ', now running on ' + d.wsdd : '';
				button('use-app').disabled = d.app_active;
				button('use-wd').disabled = !d.app_active;
			});
		}

		function use(which, done) {
			call('use', { python: which }).then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				say(done, true);
				refresh();
			});
		}

		button('use-app').addEventListener('click', function () {
			use('app', 'python3 is now the app\'s Python.');
		});

		button('use-wd').addEventListener('click', function () {
			use('wd', 'python3 is now WD\'s Python 3.9 (pip3, uv and uvx are removed until you switch back).');
		});

		refresh();
	})();
	</script>
</div>
