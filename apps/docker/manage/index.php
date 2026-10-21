<?php
// Docker's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('docker');
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="docker-manage">
	<?php manage_styles('docker-manage'); ?>

	<h2>Docker</h2>
	<table>
		<tr><td>Status</td><td data-dk="status">…</td></tr>
		<tr><td>Version</td><td data-dk="version">-</td></tr>
		<tr><td>Storage driver</td><td data-dk="driver">-</td></tr>
		<tr><td>Kernel modules</td><td data-dk="modules">-</td></tr>
		<tr><td>Memory</td><td data-dk="memory">-</td></tr>
	</table>
	<p class="mg-note" data-dk="driver-note" hidden></p>
	<p><button type="button" data-dk-action="restart">Restart Docker</button>
		<button type="button" data-dk-action="retry" hidden>Retry loading the modules</button></p>
	<p><label>Memory for Docker <select data-dk="memory-percent"></select></label>
		<button type="button" data-dk-action="memory">Save</button></p>
	<p class="mg-note">Docker and all its containers share this part of the NAS's memory; the rest is left for the NAS itself
		and its other apps (e.g. Plex). Leave the NAS enough: when it runs short, it starts stopping processes. A container
		that needs more than Docker's share is stopped instead.</p>

	<h3>Portainer</h3>
	<p data-dk="portainer">-</p>
	<p><a class="mg-button" data-dk="portainer-link" href="#" target="_blank" rel="noopener">Open Portainer</a>
		<button type="button" data-dk-action="restart-portainer">Restart Portainer</button></p>
	<div data-dk="setup-box" hidden>
		<p>Portainer's admin account hasn't been created yet. Its setup page asks for a setup token, and must be completed
			within a few minutes of Portainer starting (restart Portainer if it has timed out).</p>
		<p>Setup token: <code data-dk="token">••••••••••••</code> <button type="button" data-dk-action="token">Show</button>
			<button type="button" data-dk-action="copy-token">Copy</button></p>
	</div>

	<h3>Containers</h3>
	<table data-dk="containers"></table>

	<h3>Disk space</h3>
	<table data-dk="disk"><tr><td class="mg-note">…</td></tr></table>
	<p><button type="button" data-dk-action="disk">Refresh</button>
		<span class="mg-note">Unused images, containers and volumes can be removed in Portainer.</span></p>

	<p data-dk="message"></p>

	<script>
	// Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
	(function () {
		var root = document.getElementById('docker-manage');
		var api = '/apps/docker/api.php';
		var csrf = <?php echo json_encode(manage_csrf_token('docker')); ?>;
		<?php manage_secret_script(); ?>
		var memoryLoaded = false;
		var moduleStates = { loaded: 'loaded', not_built: 'not built for this model', wrong_firmware: 'built for another firmware',
			crashed: 'not loaded: a previous attempt never finished (the NAS may have crashed)', not_loaded: 'not loaded (see /tmp/debug_apkg)' };

		function part(name) { return root.querySelector('[data-dk="' + name + '"]'); }
		function button(name) { return root.querySelector('[data-dk-action="' + name + '"]'); }

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

		// Fills a table with rows of text (container names etc. come from Docker, so they are only ever set as text)
		function fillTable(table, header, rows, empty) {
			table.textContent = '';
			if (!rows.length) {
				table.insertRow().insertCell().textContent = empty;
				return;
			}
			var head = table.insertRow();
			header.forEach(function (text) {
				var cell = head.insertCell();
				cell.textContent = text;
				cell.style.fontWeight = 'bold';
			});
			rows.forEach(function (values) {
				var row = table.insertRow();
				values.forEach(function (value) {
					var cell = row.insertCell();
					if (value && typeof value === 'object') {
						cell.textContent = value.text;
						cell.className = value.className;
					} else {
						cell.textContent = value;
					}
				});
			});
		}

		function gb(bytes) { return (bytes / 1073741824).toFixed(1) + ' GB'; }

		// Docker's memory: the limit in force, what its containers use, and the shares to choose from (filled in once, so
		// a refresh doesn't undo a choice being made)
		function showMemory(memory, choices) {
			part('memory').textContent = (memory.limit ? 'up to ' + gb(memory.limit) + ' of the NAS\'s ' + gb(memory.total) +
				' (' + Math.round(100 * memory.limit / memory.total) + '%)' : gb(memory.total) + ' in the NAS') +
				(memory.limit ? ' - containers use ' + gb(memory.usage) : '') + ', ' + gb(memory.available) + ' free in the NAS';
			if (memoryLoaded) { return; }
			var select = part('memory-percent');
			choices.forEach(function (percent) {
				var option = document.createElement('option');
				option.value = percent;
				option.textContent = percent + '% (' + gb(memory.total * percent / 100) + ')';
				option.selected = percent === memory.percent;
				select.appendChild(option);
			});
			memoryLoaded = true;
		}

		function showKernel(kernel) {
			var anyCrashed = false;
			part('modules').textContent = kernel.modules.map(function (module) {
				anyCrashed = anyCrashed || module.state === 'crashed';
				return module.name + ': ' + moduleStates[module.state];
			}).join(', ');

			var note = '';
			if (kernel.modules.some(function (module) { return module.state === 'wrong_firmware'; })) {
				note = 'The modules were built for firmware ' + kernel.built_for + ', but this NAS runs ' + kernel.firmware +
					': rebuild the app for it to use overlay2 again.';
			} else if (anyCrashed) {
				note = 'Loading a module never finished, so it is no longer tried. Retry only if the NAS crashed for another reason.';
			}
			part('driver-note').textContent = note;
			part('driver-note').hidden = !note;
			button('retry').hidden = !anyCrashed;
		}

		function refresh() {
			return call('status').then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				var status = part('status');
				status.textContent = d.restarting ? 'Restarting… (stopping every container can take a minute)' : (d.running ? 'Running' : 'Stopped');
				status.className = d.running && !d.restarting ? 'mg-ok' : 'mg-bad';
				button('restart').disabled = d.restarting;
				part('version').textContent = d.version || '-';

				var driver = part('driver');
				driver.textContent = d.driver ? d.driver + (d.driver === 'vfs' ? ' (every image layer is a full copy - uses much more disk space)' : '') : '-';
				driver.className = d.driver === 'vfs' ? 'mg-bad' : '';
				showKernel(d.kernel);
				showMemory(d.memory, d.memory_choices);
				if (d.unused_driver) {
					var note = part('driver-note');
					note.textContent = (note.textContent ? note.textContent + ' ' : '') + 'Images stored with ' + d.unused_driver +
						' are still on disk but unused: delete ' + d.docker_root + '/' + d.unused_driver + ' (over SSH) to free their space.';
					note.hidden = false;
				}

				var portainer = part('portainer');
				portainer.textContent = d.portainer === 'running' ? 'Running on port 9000 (HTTP) and 9443 (HTTPS)' :
					(d.portainer ? 'Not running (' + d.portainer + ')' : (d.running ? 'No Portainer container (disable and enable the app to recreate it)' : '-'));
				portainer.className = d.portainer === 'running' ? 'mg-ok' : 'mg-bad';
				part('setup-box').hidden = d.portainer_has_admin !== false;

				fillTable(part('containers'), ['Name', 'Image', 'State', 'Ports'], d.containers.map(function (c) {
					return [c.name, c.image, { text: c.status || c.state, className: c.state === 'running' ? 'mg-ok' : 'mg-note' }, c.ports];
				}), d.running ? 'No containers' : '-');
			});
		}

		function refreshDisk() {
			call('disk').then(function (d) {
				if (!d.ok) { fillTable(part('disk'), [], [], d.error); return; }
				fillTable(part('disk'), ['', 'Total', 'In use', 'Size', 'Unused'], d.disk.map(function (row) {
					return [row.type, row.count, row.active, row.size, row.reclaimable];
				}), 'No data');
			});
		}

		part('portainer-link').href = 'http://' + window.location.hostname + ':9000/';

		// Keep the page current (e.g. during a restart), until the dashboard removes it
		var timer = setInterval(function () {
			if (!document.body.contains(root)) { clearInterval(timer); return; }
			refresh();
		}, 5000);

		function restart(data, question) {
			if (!window.confirm(question)) { return; }
			call('restart', data).then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				say('Docker is restarting.', true);
				refresh();
			});
		}

		button('restart').addEventListener('click', function () {
			restart({ confirm: 1 }, 'Restart Docker? Every container stops, and only those set to restart automatically start again.');
		});

		button('retry').addEventListener('click', function () {
			restart({ retry_modules: 1 }, 'Retry loading the kernel modules? Docker restarts. If loading them crashes the NAS again, they will not be tried again.');
		});

		button('memory').addEventListener('click', function () {
			var percent = part('memory-percent').value;
			call('memory', { percent: percent }).then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				say(d.applied ? 'Docker can now use ' + percent + '% of the NAS\'s memory.' :
					'Saved - it takes effect when Docker next restarts (its containers use more than that right now, or Docker isn\'t set up yet).', d.applied);
				refresh();
			});
		});

		button('restart-portainer').addEventListener('click', function () {
			say('Restarting Portainer…', true);
			call('restart_portainer', { confirm: 1 }).then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				token.reset();
				say('Portainer restarted - it has a new setup token.', true);
				refresh();
			});
		});

		// Portainer's setup token: Show / Hide and Copy (fetched when first needed, again after Portainer restarts)
		var token = mgSecret(part('token'), button('token'), button('copy-token'), function () {
			return call('setup_token', { show: 1 }).then(function (d) {
				if (!d.ok) { say(d.error, false); return null; }
				return d.token;
			});
		});

		button('disk').addEventListener('click', refreshDisk);

		refresh();
		refreshDisk();
	})();
	</script>
</div>
