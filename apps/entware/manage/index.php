<?php
// Entware's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('entware');
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="entware-manage">
	<?php manage_styles('entware-manage'); ?>
	<style>
		#entware-manage pre { background: rgba(127, 127, 127, 0.15); border-radius: 4px; padding: 0.5rem; max-height: 16rem; overflow: auto; white-space: pre-wrap; font-size: 0.85em; }
		#entware-manage details { margin: 0.5rem 0; }
		#entware-manage summary { cursor: pointer; }
	</style>

	<h2>Entware</h2>
	<table>
		<tr><td>Status</td><td data-ew="status">…</td></tr>
		<tr><td>Architecture</td><td data-ew="arch">-</td></tr>
		<tr><td>Downloads</td><td><span data-ew="https">-</span> <button type="button" data-ew-action="use-https" hidden>Switch to HTTPS</button></td></tr>
		<tr><td>Installed packages</td><td data-ew="count">-</td></tr>
	</table>

	<h3>Updates</h3>
	<p data-ew="updates-summary">-</p>
	<table data-ew="updates"></table>
	<p><button type="button" data-ew-action="check">Check for updates</button>
		<button type="button" data-ew-action="upgrade" hidden>Update all</button></p>

	<h3>Services</h3>
	<table data-ew="services"></table>

	<h3>Packages</h3>
	<p><input type="text" data-ew="term" placeholder="Search, e.g. htop" autocomplete="off" spellcheck="false">
		<button type="button" data-ew-action="search">Search</button></p>
	<table data-ew="results"></table>
	<details>
		<summary>Installed packages</summary>
		<table data-ew="installed"></table>
	</details>

	<div data-ew="job-box" hidden>
		<h3>Progress</h3>
		<pre data-ew="job-log"></pre>
	</div>

	<p data-ew="message"></p>

	<details class="mg-section">
		<summary>Using Entware over SSH</summary>
		<pre>opkg update               # refresh the package list
opkg find '*name*'        # search for a package
opkg install &lt;package&gt;    # install a package
opkg list-installed       # show installed packages
opkg upgrade              # update installed packages</pre>
		<p class="mg-note">Packages are kept in <code>Nas_Prog/_entware/opt</code> (mounted on <code>/opt</code>) and root's home folder in
			<code>Nas_Prog/_entware/home</code>: both survive reinstalls. See the
			<a href="https://github.com/Entware/Entware/wiki" target="_blank" rel="noopener">Entware wiki</a> for more.</p>
	</details>

	<script>
	// Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
	(function () {
		var root = document.getElementById('entware-manage');
		var api = '/apps/entware/api.php';
		var csrf = <?php echo json_encode(manage_csrf_token('entware')); ?>;
		var installed = {};
		var jobWasRunning = false;

		function part(name) { return root.querySelector('[data-ew="' + name + '"]'); }
		function button(name) { return root.querySelector('[data-ew-action="' + name + '"]'); }

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

		// Fills a table with rows: text values (package names etc. are only ever set as text), or { text, className },
		// or { button, onClick } for a button
		function fillTable(table, header, rows, empty) {
			table.textContent = '';
			if (!rows.length) {
				if (empty) { table.insertRow().insertCell().textContent = empty; }
				return;
			}
			if (header) {
				var head = table.insertRow();
				header.forEach(function (text) {
					var cell = head.insertCell();
					cell.textContent = text;
					cell.style.fontWeight = 'bold';
				});
			}
			rows.forEach(function (values) {
				var row = table.insertRow();
				values.forEach(function (value) {
					var cell = row.insertCell();
					[].concat(value).forEach(function (item) {
						if (item && item.button) {
							var b = document.createElement('button');
							b.type = 'button';
							b.textContent = item.button;
							b.disabled = jobWasRunning;
							b.addEventListener('click', item.onClick);
							cell.appendChild(b);
						} else if (item && typeof item === 'object') {
							cell.textContent = item.text;
							cell.className = item.className;
						} else {
							cell.textContent = item;
						}
					});
				});
			});
		}

		function startJob(action, data, question) {
			if (question && !window.confirm(question)) { return; }
			call(action, data).then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				say('', true);
				refresh();
			});
		}

		function showServices(services) {
			fillTable(part('services'), null, services.map(function (s) {
				return [s.name, { text: s.running === null ? 'unknown' : (s.running ? 'running' : 'stopped'), className: s.running ? 'mg-ok' : 'mg-note' },
					['start', 'stop', 'restart'].map(function (command) {
						return { button: command.charAt(0).toUpperCase() + command.slice(1), onClick: function () {
							say(command.charAt(0).toUpperCase() + command.slice(1) + ': ' + s.name + '…', true);
							call('service', { service: s.name, command: command }).then(function (d) {
								if (!d.ok) { say(d.error, false); return; }
								say(d.output || 'Done.', true);
								refresh();
							});
						} };
					})];
			}), 'No services (they come with packages such as sshd or nginx)');
		}

		function refresh() {
			return call('status').then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				var status = part('status');
				status.textContent = !d.installed ? 'Not installed' + (d.mounted ? '' : ' (/opt is not mounted - enable the app)') :
					(d.job_running ? 'Busy (see Progress below)' : 'Ready');
				status.className = d.installed ? 'mg-ok' : 'mg-bad';
				part('arch').textContent = d.arch || '-';
				part('https').textContent = d.installed ? (d.https ? 'HTTPS' : 'HTTP (not encrypted)') : '-';
				part('https').className = d.installed && !d.https ? 'mg-bad' : '';
				button('use-https').hidden = !d.installed || d.https;
				part('count').textContent = d.packages.length;
				if (part('updates').rows.length === 0) {
					part('updates-summary').textContent = d.updates_last_check === '' ? 'Not checked yet.' :
						'Last check: ' + d.updates_last_check + ' update(s) available.';
				}

				installed = {};
				d.packages.forEach(function (p) { installed[p.name] = p.version; });
				fillTable(part('installed'), ['Package', 'Version', ''], d.packages.map(function (p) {
					return [p.name, p.version, p.core ? { text: 'part of Entware', className: 'mg-note' } : { button: 'Remove', onClick: function () {
						startJob('remove', { packages: p.name }, 'Remove ' + p.name + '? Packages that need it may stop working.');
					} }];
				}), 'None');
				showServices(d.services);

				// A package job's output, until it is dismissed by the next job
				part('job-box').hidden = d.job_log === '';
				part('job-log').textContent = d.job_log;
				part('job-log').scrollTop = part('job-log').scrollHeight;
				if (jobWasRunning && !d.job_running) {
					say('Finished - see Progress.', true);
					part('updates').textContent = '';
					button('upgrade').hidden = true;
				}
				jobWasRunning = d.job_running;
				root.querySelectorAll('button').forEach(function (b) { b.disabled = d.job_running && b.dataset.ewAction !== 'search'; });
			});
		}

		// Keep the page current (e.g. while a package job runs), until the dashboard removes it
		var timer = setInterval(function () {
			if (!document.body.contains(root)) { clearInterval(timer); return; }
			refresh();
		}, 4000);

		button('check').addEventListener('click', function () {
			say('Checking for updates…', true);
			call('check_updates', { check: 1 }).then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				say('', true);
				part('updates-summary').textContent = d.updates.length ? d.updates.length + ' update(s) available:' : 'Everything is up to date.';
				fillTable(part('updates'), ['Package', 'Installed', 'New'], d.updates.map(function (u) {
					return [u.name, u.version, u.new_version];
				}));
				button('upgrade').hidden = !d.updates.length;
			});
		});

		button('use-https').addEventListener('click', function () {
			startJob('use_https', { confirm: 1 }, 'Switch Entware to HTTPS downloads? This first updates all installed packages, then installs wget-ssl and ca-bundle.');
		});

		button('upgrade').addEventListener('click', function () {
			startJob('upgrade', { all: 1 }, 'Update all Entware packages? Services may restart.');
		});

		function search() {
			var term = part('term').value.trim();
			say('Searching…', true);
			call('search', { term: term }).then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				say(d.more ? 'Showing the first 200 matches - try a longer search.' : '', true);
				fillTable(part('results'), ['Package', 'Version', 'Description', ''], d.results.map(function (r) {
					return [r.name, r.version, r.description, installed[r.name] ? { text: 'installed', className: 'mg-ok' } :
						{ button: 'Install', onClick: function () { startJob('install', { packages: r.name }, 'Install ' + r.name + '?'); } }];
				}), 'Nothing found');
			});
		}
		button('search').addEventListener('click', search);
		part('term').addEventListener('keydown', function (e) { if (e.key === 'Enter') { e.preventDefault(); search(); } });

		refresh();
	})();
	</script>
</div>
