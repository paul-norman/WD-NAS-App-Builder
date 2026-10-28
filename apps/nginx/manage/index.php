<?php
// Nginx's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('nginx');
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="nginx-manage">
	<?php manage_styles('nginx-manage'); ?>
	<style>
		#nginx-manage pre { background: rgba(127, 127, 127, 0.15); border-radius: 4px; padding: 0.5rem; max-height: 16rem; overflow: auto; white-space: pre-wrap; font-size: 0.8em; }
		#nginx-manage details { margin: 0.5rem 0; }
		#nginx-manage summary { cursor: pointer; }
		#nginx-manage table.mg-edit input[type=text] { width: 100%; min-width: 7rem; box-sizing: border-box; }
		#nginx-manage .mg-field { margin: 0.4rem 0; }
		#nginx-manage .mg-field label { display: block; font-weight: bold; }
		#nginx-manage select { padding: 0.3rem; max-width: 100%; }
		#nginx-manage textarea { width: 100%; max-width: 40rem; height: 6rem; font-family: monospace; font-size: 0.8em; }
	</style>

	<h2>Nginx</h2>
	<table>
		<tr><td>Status</td><td data-ng="status">…</td></tr>
		<tr><td>Configuration</td><td data-ng="config">…</td></tr>
		<tr><td>Certificate</td><td data-ng="cert">…</td></tr>
	</table>
	<pre data-ng="config-test" hidden></pre>
	<p><a class="mg-button" data-ng="start-link" href="#" target="_blank" rel="noopener" hidden>Open the start page</a>
		<button type="button" data-ng-action="reload">Reload the configuration</button></p>
	<p data-ng="top-message"></p>

	<h3>Apps</h3>
	<p data-ng="apps-note"></p>
	<p><label>The domain itself (https://<span data-ng="home-domain">domain</span>/) shows: <select data-ng="home"></select></label></p>
	<table class="mg-edit" data-ng="apps"></table>
	<p><button type="button" data-ng-action="add">Add an app</button> <button type="button" data-ng-action="save-apps">Save</button></p>
	<p data-ng="apps-message"></p>
	<p class="mg-note">Each app is reached at https://<em>name</em>.<em>domain</em> (the one chosen above at the domain
		itself), and the start page listing them at https://apps.<em>domain</em>. Installed apps and the Store's recipes
		bring their own sites, with their settings greyed out (only On, Name and Label are yours); they go when their app
		does. For anything else, add an app: the target is where the app answers on
		the NAS (or anywhere on the network). Host is only needed for apps that check it (e.g. Syncthing: localhost), and
		Path for apps under a path (e.g. /phpMyAdmin/) - only it is passed on. Start is the page the site's root goes to,
		with every path still passed on (e.g. Pi-hole's /admin/). Uploads lifts the size limit on requests and allows long ones (e.g.
		photos, videos, git pushes); Streaming passes each response on as it comes and keeps connections open (e.g. music,
		notifications, live updates). Your own sites go in <code>Nas_Prog/_nginx/sites</code>.</p>

	<h3>Sites</h3>
	<p>PHP for the sites: <span data-ng="php">…</span> <button type="button" data-ng-action="restart-php" hidden>Restart PHP</button></p>
	<table class="mg-edit" data-ng="sites"></table>
	<p><button type="button" data-ng-action="add-site">Add a site</button> <button type="button" data-ng-action="save-sites">Save</button></p>
	<p data-ng="sites-message"></p>
	<p class="mg-note">Each site is reached at https://<em>name</em>.<em>domain</em> and serves a folder on the NAS (e.g.
		/mnt/HD/HD_a2/Web/blog). With PHP, its .php files run as the unprivileged nobody user (with PHP's settings in
		<code>Nas_Prog/_nginx/php</code>); without, they're refused rather than shown. "Unknown paths to index.php" is for
		apps with a front controller (e.g. Laravel - point the folder at its public folder - or WordPress).</p>

	<div data-ng="links-box" hidden>
		<h3>Quick links</h3>
		<table data-ng="links"></table>
	</div>

	<h3>Certificate</h3>
	<p><label><input type="radio" name="ng-mode" value="acme" checked> From Let's Encrypt (or another ACME CA), using your DNS provider</label><br>
		<label><input type="radio" name="ng-mode" value="own"> My own certificate</label></p>

	<div data-ng="acme-box">
		<div class="mg-field"><label>Domain</label>
			<input type="text" data-ng="domain" placeholder="e.g. example.com or nas.example.com" autocomplete="off" spellcheck="false">
			<div class="mg-note">The certificate covers it and every name under it (*.domain).</div></div>
		<div class="mg-field"><label>Email</label>
			<input type="text" data-ng="email" placeholder="you@example.com" autocomplete="off" spellcheck="false">
			<div class="mg-note">For the CA's account (e.g. expiry warnings).</div></div>
		<div class="mg-field"><label>Certificate authority</label>
			<select data-ng="server"></select>
			<input type="text" data-ng="server-url" placeholder="https://acme.example.com/directory" autocomplete="off" spellcheck="false" hidden></div>
		<details data-ng="eab-box"><summary>External account binding (only if the CA asks for it, e.g. ZeroSSL or Google)</summary>
			<div class="mg-field"><label>Key ID</label><input type="text" data-ng="eab-kid" autocomplete="off" spellcheck="false"></div>
			<div class="mg-field"><label>HMAC key</label><input type="text" data-ng="eab-hmac" autocomplete="off" spellcheck="false"></div>
		</details>
		<div class="mg-field"><label>DNS provider</label>
			<select data-ng="provider"><option value="">Loading…</option></select>
			<div class="mg-note">Where the domain's DNS is managed. A TXT record is briefly added through its API to prove the
				domain is yours - nothing on the NAS needs to be reachable from the internet. No domain? deSEC (free
				dedyn.io names) and Duck DNS work too. <a data-ng="provider-link" href="#" target="_blank" rel="noopener" hidden>This provider's documentation</a></div></div>
		<div data-ng="fields"></div>
		<details data-ng="additional-box"><summary>Additional settings (optional)</summary><div data-ng="additional"></div>
			<div class="mg-field"><label>Other variables</label>
				<textarea data-ng="other" spellcheck="false" placeholder="NAME=value (one per line)"></textarea>
				<div class="mg-note">For settings not listed above (see the provider's documentation). NAME= removes a saved one.
					Where a local DNS server answers for the domain itself, point lego's checks elsewhere with
					LEGO_DNS_RESOLVERS=1.1.1.1:53 (also: LEGO_DNS_TIMEOUT, LEGO_DNS_PROPAGATION_WAIT). If the log shows
					"Found CNAME entry" because of a wildcard CNAME, LEGO_DISABLE_CNAME_SUPPORT=true keeps the challenge record
					at _acme-challenge.<em>domain</em>.</div></div>
		</details>
		<p><button type="button" data-ng-action="issue">Save and get the certificate</button></p>
		<p data-ng="issue-message"></p>
		<p class="mg-note">Saved credentials aren't shown again: leave a field empty to keep it. It's tried on the CA's
			staging server first (where it has one), and renewed automatically, checked daily.</p>
		<div data-ng="job-box" hidden><pre data-ng="job-log"></pre>
			<p><button type="button" data-ng-action="clear-job-log">Clear the log</button></p></div>
	</div>

	<div data-ng="own-box" hidden>
		<div class="mg-field"><label>Certificate (PEM, with its chain)</label><textarea data-ng="own-cert" spellcheck="false"></textarea></div>
		<div class="mg-field"><label>Private key (PEM)</label><textarea data-ng="own-key" spellcheck="false"></textarea></div>
		<p><button type="button" data-ng-action="own">Use this certificate</button></p>
		<p data-ng="own-message"></p>
		<p class="mg-note">It isn't renewed by the app: replace it here before it expires.</p>
	</div>

	<h3>Local DNS</h3>
	<p>Your devices need to find the NAS under these names. Add them to your local DNS (e.g. Pi-hole's Local DNS, or your
		router), pointing at the NAS:</p>
	<pre data-ng="dns">…</pre>
	<p class="mg-note">With dnsmasq (e.g. Pi-hole), one line covers every name: <code data-ng="dnsmasq"></code>. Without
		local DNS, the same records can go in the domain's public DNS (only reachable inside your network, but some routers
		block such answers).</p>

	<details class="mg-section">
		<summary>Nginx's error log</summary>
		<pre data-ng="error-log">…</pre>
		<p><button type="button" data-ng-action="clear-error-log">Clear the log</button></p>
		<p data-ng="log-message"></p>
	</details>

	<p data-ng="message"></p>

	<script>
	// Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
	(function () {
		var root = document.getElementById('nginx-manage');
		var api = '/apps/nginx/api.php';
		var csrf = <?php echo json_encode(manage_csrf_token('nginx')); ?>;
		var state = null;
		var provider = null;
		var jobWasRunning = false;
		var formFilled = false;

		function part(name) { return root.querySelector('[data-ng="' + name + '"]'); }
		function button(name) { return root.querySelector('[data-ng-action="' + name + '"]'); }

		function say(text, good, where) {
			var message = part(where || 'message');
			message.textContent = text;
			message.className = good ? 'mg-ok' : 'mg-bad';
		}

		// API calls carry X-Requested-With (nasAdmin requires it) and this page's CSRF token
		function call(action, data, query) {
			var options = { method: data ? 'POST' : 'GET', credentials: 'same-origin',
				headers: { 'X-Requested-With': 'XMLHttpRequest', 'X-CSRF-Token': csrf } };
			if (data) {
				options.headers['Content-Type'] = 'application/x-www-form-urlencoded';
				options.body = new URLSearchParams(data).toString();
			}
			return fetch(api + '?action=' + action + (query || ''), options).then(function (response) {
				return response.json().catch(function () { return { ok: false, error: 'Unexpected response (' + response.status + ')' }; });
			});
		}

		function element(tag, props) {
			var el = document.createElement(tag);
			Object.keys(props || {}).forEach(function (key) { el[key] = props[key]; });
			return el;
		}

		// The apps table: everything set as text / values, never as HTML (labels and names are the user's)
		// (an installed app's own site: only whether it's on, its name and its label can be changed - the rest is its app's)
		function appRow(app) {
			var row = part('apps').insertRow();
			var own = !!app.app;
			row.dataset.app = app.app || '';
			row.insertCell().appendChild(element('input', { type: 'checkbox', checked: app.enabled, title: 'On' }));
			[['name', 'name'], ['label', 'label'], ['target', 'http://127.0.0.1:8080'], ['host', ''], ['path', ''], ['start', '']].forEach(function (field, i) {
				row.insertCell().appendChild(element('input', { type: 'text', value: app[field[0]] || '', placeholder: own ? '' : field[1], spellcheck: false, autocomplete: 'off', readOnly: own && i > 1, title: own && i > 1 ? 'Set by the app' : '' }));
			});
			row.insertCell().appendChild(element('input', { type: 'checkbox', checked: !!app.uploads, title: 'Uploads: no size limit, long time-outs', disabled: own }));
			row.insertCell().appendChild(element('input', { type: 'checkbox', checked: !!app.stream, title: 'Streaming: responses passed on as they come', disabled: own }));
			var cell = row.insertCell();
			if (!own) {
				var remove = element('button', { type: 'button', textContent: 'Remove' });
				remove.addEventListener('click', function () { row.remove(); });
				cell.appendChild(remove);
			}
		}

		function showApps() {
			var table = part('apps');
			table.textContent = '';
			var head = table.insertRow();
			['On', 'Name', 'Label', 'Target', 'Host', 'Path', 'Start', 'Uploads', 'Streaming', ''].forEach(function (text) {
				var cell = head.insertCell();
				cell.textContent = text;
				cell.style.fontWeight = 'bold';
			});
			sorted(state.apps).forEach(appRow);
			showHome();
		}

		// Apps or sites in alphabetical order of their labels, as the server sorts them (ignoring case, numbers in order)
		function sorted(list) {
			return list.slice().sort(function (a, b) {
				return (a.label || a.name).localeCompare(b.label || b.name, undefined, { numeric: true, sensitivity: 'base' }) || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
			});
		}

		// What the domain itself shows: one of the apps (as saved), or the start page
		function showHome() {
			var select = part('home');
			select.textContent = '';
			select.appendChild(element('option', { value: '', textContent: 'The start page (the list of apps)' }));
			sorted(state.apps).forEach(function (app) { select.appendChild(element('option', { value: app.name, textContent: app.label || app.name })); });
			select.value = state.home;
			if (select.value !== state.home) { select.value = ''; }
			part('home-domain').textContent = state.domain || 'domain';
		}

		// An app's or site's host name: the domain itself for the home app (switched on), otherwise name.domain
		function host(app) {
			return app.target !== undefined && app.name === state.home && app.enabled ? state.domain : app.name + '.' + state.domain;
		}

		// Whether the home app is switched on (the start page is at the domain itself otherwise)
		function homeShown() {
			return state.apps.some(function (app) { return app.name === state.home && app.enabled; });
		}

		// The sites table (folders and labels are the user's: only ever set as values / text)
		function siteRow(site) {
			var row = part('sites').insertRow();
			row.insertCell().appendChild(element('input', { type: 'checkbox', checked: site.enabled, title: 'On' }));
			[['name', 'blog'], ['label', 'label'], ['root', '/mnt/HD/HD_a2/Web/blog']].forEach(function (field) {
				row.insertCell().appendChild(element('input', { type: 'text', value: site[field[0]] || '', placeholder: field[1], spellcheck: false, autocomplete: 'off' }));
			});
			row.insertCell().appendChild(element('input', { type: 'checkbox', checked: site.php, title: 'PHP' }));
			row.insertCell().appendChild(element('input', { type: 'checkbox', checked: site.front, title: 'Unknown paths to index.php' }));
			var remove = element('button', { type: 'button', textContent: 'Remove' });
			remove.addEventListener('click', function () { row.remove(); });
			row.insertCell().appendChild(remove);
		}

		function showSites() {
			var table = part('sites');
			table.textContent = '';
			var head = table.insertRow();
			['On', 'Name', 'Label', 'Folder', 'PHP', 'Unknown paths to index.php', ''].forEach(function (text) {
				var cell = head.insertCell();
				cell.textContent = text;
				cell.style.fontWeight = 'bold';
			});
			sorted(state.sites).forEach(siteRow);
		}

		function collectSites() {
			return [].slice.call(part('sites').rows, 1).map(function (row) {
				var inputs = row.querySelectorAll('input');
				return { enabled: inputs[0].checked, name: inputs[1].value, label: inputs[2].value, root: inputs[3].value, php: inputs[4].checked, front: inputs[5].checked };
			});
		}

		function collectApps() {
			var apps = [];
			[].slice.call(part('apps').rows, 1).forEach(function (row) {
				var inputs = row.querySelectorAll('input');
				apps.push({ app: row.dataset.app, enabled: inputs[0].checked, name: inputs[1].value, label: inputs[2].value, target: inputs[3].value, host: inputs[4].value, path: inputs[5].value, start: inputs[6].value, uploads: inputs[7].checked, stream: inputs[8].checked });
			});
			return apps;
		}

		function showDns() {
			var domain = state.domain;
			var ip = state.nas_ip || '<the NAS\'s local IP address>';
			if (!domain) {
				part('dns').textContent = 'Set a domain under Certificate first.';
				part('dnsmasq').textContent = '';
				return;
			}
			var names = [domain, state.start_name + '.' + domain].concat(state.apps.concat(state.sites).filter(function (a) { return a.enabled && host(a) !== domain; }).map(host));
			part('dns').textContent = names.map(function (name) { return name + '  →  ' + ip; }).join('\n');
			part('dnsmasq').textContent = 'address=/' + domain + '/' + ip;
		}

		// The provider's fields, from lego's own description of it
		function showProvider(code) {
			part('fields').textContent = '';
			part('additional').textContent = '';
			part('provider-link').hidden = true;
			provider = null;
			if (!code) { return; }
			call('provider', null, '&code=' + encodeURIComponent(code)).then(function (d) {
				if (!d.ok) { say(d.error, false, 'issue-message'); return; }
				provider = d.provider;
				var saved = state.acme.provider === code ? state.acme.saved : [];
				provider.fields.forEach(function (field) {
					var box = element('div', { className: 'mg-field' });
					box.appendChild(element('label', { textContent: field.name }));
					var input = element('input', { type: 'text', spellcheck: false, autocomplete: 'off',
						placeholder: saved.indexOf(field.name) !== -1 ? '(saved - leave empty to keep)' : '' });
					input.dataset.name = field.name;
					box.appendChild(input);
					box.appendChild(element('div', { className: 'mg-note', textContent: field.description }));
					part(field.group === 'credentials' ? 'fields' : 'additional').appendChild(box);
				});
				// A provider lego describes no settings for: everything goes in "other variables"
				part('additional-box').open = !provider.fields.length;
				if (provider.url) {
					part('provider-link').href = provider.url;
					part('provider-link').hidden = false;
				}
			});
		}

		function fillForm() {
			var acme = state.acme;
			part('domain').value = acme.domain || state.domain;
			part('email').value = acme.email;
			var select = part('server');
			select.textContent = '';
			Object.keys(state.servers).forEach(function (code) { select.appendChild(element('option', { value: code, textContent: state.servers[code] })); });
			select.appendChild(element('option', { value: 'url', textContent: 'Another ACME server (by its address)' }));
			var custom = !state.servers[acme.server];
			select.value = custom ? 'url' : acme.server;
			part('server-url').value = custom ? acme.server : '';
			part('server-url').hidden = !custom;
			part('eab-kid').placeholder = acme.eab ? '(saved - leave empty to keep)' : '';
			call('providers').then(function (d) {
				if (!d.ok) { say(d.error, false, 'issue-message'); return; }
				var list = part('provider');
				list.textContent = '';
				list.appendChild(element('option', { value: '', textContent: 'Choose…' }));
				d.providers.forEach(function (code) { list.appendChild(element('option', { value: code, textContent: code })); });
				list.value = acme.provider;
				showProvider(acme.provider);
			});
		}

		// Links to every site, once browsers trust the certificate: the start page, the apps switched on, and the user's own
		// sites (names set as text and link targets only)
		function showLinks() {
			var cert = state.certificate;
			var ready = state.domain && cert && !cert.self_signed && !cert.staging;
			part('links-box').hidden = !ready;
			if (!ready) { return; }
			var rows = [['Start page', state.start_name + '.' + state.domain]];
			if (!homeShown()) { rows.push(['Start page', state.domain]); }
			sorted(state.apps.concat(state.sites)).forEach(function (app) {
				if (app.enabled) { rows.push([app.label || app.name, host(app)]); }
			});
			Object.keys(state.own_sites).sort().forEach(function (name) { rows.push([name + ' (' + state.own_sites[name] + ')', name]); });
			var table = part('links');
			table.textContent = '';
			var head = table.insertRow();
			['Site', 'Address'].forEach(function (text) {
				var cell = head.insertCell();
				cell.textContent = text;
				cell.style.fontWeight = 'bold';
			});
			rows.forEach(function (row) {
				var tr = table.insertRow();
				tr.insertCell().textContent = row[0];
				var url = 'https://' + row[1] + '/';
				tr.insertCell().appendChild(element('a', { href: url, textContent: url, target: '_blank', rel: 'noopener' }));
			});
		}

		function showCertificate(cert) {
			var el = part('cert');
			if (!cert) { el.textContent = 'none'; el.className = 'mg-bad'; return; }
			el.textContent = cert.names.join(', ') + ' - ' + (cert.self_signed ? 'temporary, self-signed (browsers will warn)' :
				'from ' + cert.issuer + (cert.staging ? ' (STAGING - not trusted by browsers)' : '')) + ', until ' + cert.expires + ' (' + cert.days_left + ' days)';
			el.className = cert.self_signed || cert.staging || cert.days_left < 14 ? 'mg-bad' : 'mg-ok';
		}

		function refresh() {
			return call('status').then(function (d) {
				if (!d.ok) { say(d.error, false, 'top-message'); return; }
				state = d;
				part('status').textContent = d.running ? 'Running (Nginx ' + d.version + ')' : 'Stopped';
				part('status').className = d.running ? 'mg-ok' : 'mg-bad';
				part('config').textContent = d.config_ok ? 'OK' : 'Error - Nginx carries on with the last working configuration:';
				part('config').className = d.config_ok ? 'mg-ok' : 'mg-bad';
				part('config-test').hidden = d.config_ok;
				part('config-test').textContent = d.config_test;
				showCertificate(d.certificate);
				part('start-link').hidden = !d.domain;
				part('start-link').href = 'https://' + d.start_name + '.' + d.domain + '/';
				part('error-log').textContent = d.error_log.length ? d.error_log.join('\n') : 'Empty.';

				part('job-box').hidden = d.job_log === '';
				part('job-log').textContent = d.job_log;
				part('job-log').scrollTop = part('job-log').scrollHeight;
				button('issue').disabled = d.job_running;
				if (jobWasRunning && !d.job_running) {
					var done = /exit code 0\)\s*$/.test(d.job_log);
					say(done ? 'Certificate installed - Nginx reloaded.' : 'Getting the certificate failed - see the log below for why.', done, 'issue-message');
				}
				jobWasRunning = d.job_running;

				var php = part('php');
				php.textContent = !d.php.available ? 'none - install the PHP app for it' : 'PHP ' + d.php.version + (d.php.running ? ', running' : ', not running');
				php.className = d.php.available && d.php.running ? 'mg-ok' : 'mg-bad';
				button('restart-php').hidden = !d.php.available;

				if (!formFilled) {
					formFilled = true;
					showApps();
					showSites();
					fillForm();
					part('apps-note').textContent = d.domain ? '' : 'Set a domain under Certificate first - the apps are reached as name.domain.';
				}
				showDns();
				showLinks();
				button('clear-job-log').disabled = d.job_running;
				button('clear-error-log').disabled = !d.error_log.length;
			});
		}

		// Keep the page current (e.g. while a certificate is requested), until the dashboard removes it
		var timer = setInterval(function () {
			if (!document.body.contains(root)) { clearInterval(timer); return; }
			if (jobWasRunning) { refresh(); }
		}, 3000);

		[].slice.call(root.querySelectorAll('input[name="ng-mode"]')).forEach(function (radio) {
			radio.addEventListener('change', function () {
				var mode = root.querySelector('input[name="ng-mode"]:checked').value;
				part('acme-box').hidden = mode !== 'acme';
				part('own-box').hidden = mode !== 'own';
			});
		});
		part('server').addEventListener('change', function () { part('server-url').hidden = part('server').value !== 'url'; });
		part('provider').addEventListener('change', function () { showProvider(part('provider').value); });

		button('add').addEventListener('click', function () { appRow({ enabled: true, name: '', label: '', target: '', host: '', path: '', start: '', uploads: false, stream: false }); });

		button('add-site').addEventListener('click', function () { siteRow({ enabled: true, name: '', label: '', root: '', php: true, front: false }); });

		button('save-sites').addEventListener('click', function () {
			say('Saving…', true, 'sites-message');
			call('save_sites', { sites: JSON.stringify(collectSites()) }).then(function (d) {
				if (!d.ok) { say(d.error, false, 'sites-message'); return; }
				say('Saved - Nginx reloaded.', true, 'sites-message');
				formFilled = false;
				refresh();
			});
		});

		button('restart-php').addEventListener('click', function () {
			say('Restarting PHP…', true, 'sites-message');
			call('restart_php', { confirm: 1 }).then(function (d) {
				if (!d.ok) { say(d.error, false, 'sites-message'); return; }
				say('PHP restarted.', true, 'sites-message');
				refresh();
			});
		});

		button('save-apps').addEventListener('click', function () {
			say('Saving…', true, 'apps-message');
			call('save_apps', { apps: JSON.stringify(collectApps()), home: part('home').value }).then(function (d) {
				if (!d.ok) { say(d.error, false, 'apps-message'); return; }
				say('Saved - Nginx reloaded.', true, 'apps-message');
				formFilled = false;
				refresh();
			});
		});

		button('issue').addEventListener('click', function () {
			if (!provider) { say('Choose your DNS provider first.', false, 'issue-message'); return; }
			var data = { domain: part('domain').value, email: part('email').value,
				server: part('server').value === 'url' ? part('server-url').value : part('server').value,
				provider: provider.code, eab_kid: part('eab-kid').value, eab_hmac: part('eab-hmac').value, other: part('other').value };
			[].slice.call(root.querySelectorAll('[data-ng="fields"] input, [data-ng="additional"] input')).forEach(function (input) {
				data['credentials[' + input.dataset.name + ']'] = input.value;
			});
			say('Requesting the certificate - this can take a few minutes (DNS changes have to spread). Progress is shown in the log below.', true, 'issue-message');
			call('issue', data).then(function (d) {
				if (!d.ok) { say(d.error, false, 'issue-message'); return; }
				part('other').value = '';
				jobWasRunning = true;
				formFilled = false;
				refresh().then(function () { part('issue-message').scrollIntoView({ block: 'nearest', behavior: 'smooth' }); });
			});
		});

		button('own').addEventListener('click', function () {
			call('own_certificate', { certificate: part('own-cert').value, key: part('own-key').value }).then(function (d) {
				if (!d.ok) { say(d.error, false, 'own-message'); return; }
				part('own-cert').value = part('own-key').value = '';
				say('Certificate installed - Nginx reloaded.', true, 'own-message');
				refresh();
			});
		});

		function clearLog(log, where) {
			call('clear_log', { log: log }).then(function (d) {
				if (!d.ok) { say(d.error, false, where); return; }
				say('Log cleared.', true, where);
				refresh();
			});
		}
		button('clear-job-log').addEventListener('click', function () { clearLog('certificate', 'issue-message'); });
		button('clear-error-log').addEventListener('click', function () { clearLog('error', 'log-message'); });

		button('reload').addEventListener('click', function () {
			call('reload', { confirm: 1 }).then(function (d) {
				if (!d.ok) { say(d.error, false, 'top-message'); return; }
				say('Nginx reloaded.', true, 'top-message');
				refresh();
			});
		});

		refresh();
	})();
	</script>
</div>
