<?php
// The Store's page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('store');
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="store-manage">
	<?php manage_styles('store-manage'); ?>
	<style>
		/* (no padding above: the title sits where the dashboard's other pages have theirs) */
		#store-manage { max-width: 100%; padding-top: 0; }
		/* (the title as the dashboard's other pages have it: WD's header_1 and its rule - kept full width, and drawn
		   the same where WD's styles aren't loaded) */
		#store-manage .st-title { width: auto; height: 56px; margin: 14px 0 0; font-size: 28px; line-height: 56px; }
		#store-manage .hr_1 { border-top: 1px solid #c8c8c8; }
		#store-manage .st-titlebar { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; column-gap: 1rem; margin-top: 14px; }
		#store-manage .st-titlebar .st-title { margin-top: 0; }
		#store-manage .st-head { display: flex; flex-wrap: wrap; align-items: center; justify-content: flex-end; gap: 0.5rem 1rem; }
		#store-manage .st-tabs { display: flex; align-items: flex-end; gap: 0.25rem; margin: 1rem 0 0.75rem; border-bottom: 1px solid #c8c8c8; }
		#store-manage .st-tabs button { margin: 0; border: 0; border-top: 2px solid transparent; background: none; padding: 0.5rem 0.9rem; color: inherit; font: inherit; }
		/* (the open tab joins the page below it: its bottom edge is the page's background (WD's #fafafa) over the line, and
		   its top edge WD's blue) */
		#store-manage .st-tabs button.st-on { position: relative; z-index: 1; margin-bottom: -1px; outline: 0; border: 1px solid #c8c8c8; border-top: 2px solid #0099ff; border-bottom-color: #fafafa; background: #fafafa; font-weight: bold; }
		#store-manage .st-filters { display: flex; flex-wrap: wrap; gap: 0.5rem 1rem; align-items: center; margin-bottom: 0.75rem; }
		#store-manage .st-filters input[type=text] { width: 14rem; }
		#store-manage .st-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(17rem, 1fr)); gap: 0.6rem; }
		/* (cards are plain blocks: the dashboard gives buttons a fixed height and no wrapping) */
		#store-manage .st-card { display: flex; align-items: flex-start; gap: 0.75rem; box-sizing: border-box; min-width: 0; height: auto; text-align: left; margin: 0; padding: 0.75rem; border: 1px solid rgba(127, 127, 127, 0.3); border-radius: 8px; background: rgba(127, 127, 127, 0.05); color: inherit; font: inherit; line-height: 1.4; white-space: normal; cursor: pointer; }
		#store-manage .st-card:hover, #store-manage .st-card:focus { border-color: #2f6fdb; outline: none; }
		#store-manage .st-card-text { flex: 1; min-width: 0; overflow-wrap: anywhere; }
		#store-manage .st-tabs button { height: auto; line-height: 1.4; white-space: nowrap; }
		#store-manage .st-icon { width: 48px; height: 48px; flex: none; object-fit: contain; border-radius: 8px; }
		#store-manage .st-icon-none { display: flex; align-items: center; justify-content: center; background: rgba(127, 127, 127, 0.15); font-weight: bold; font-size: 1.3em; }
		#store-manage .st-card strong { display: block; }
		#store-manage .st-card .st-summary { display: block; font-size: 0.9em; opacity: 0.8; margin-top: 0.15rem; white-space: normal; }
		#store-manage .st-badges { margin-top: 0.15rem; white-space: normal; }
		#store-manage .st-badge { display: inline-block; white-space: nowrap; font-size: 0.75em; padding: 0.05rem 0.45rem; border-radius: 1rem; margin: 0.3rem 0.3rem 0 0; background: rgba(127, 127, 127, 0.18); }
		#store-manage .st-badge.st-installed { background: rgba(46, 125, 50, 0.18); }
		#store-manage .st-badge.st-update { background: rgba(47, 111, 219, 0.2); }
		#store-manage .st-badge.st-unsupported { background: rgba(198, 40, 40, 0.15); }
		#store-manage pre.st-log { max-height: 36rem; overflow: auto; font-size: 0.8em; background: rgba(127, 127, 127, 0.1); padding: 0.5rem; white-space: pre-wrap; word-break: break-all; }
		#store-manage .st-detail-head { display: flex; gap: 1rem; align-items: center; }
		#store-manage .st-detail-head .st-icon { width: 64px; height: 64px; }
		#store-manage .st-detail-title { flex: 1; min-width: 0; }
		#store-manage .st-detail-title h3 { margin: 0; padding: 0; border: 0; }
		#store-manage .st-back { flex: none; align-self: flex-start; }
		#store-manage .st-actions { display: flex; flex-wrap: wrap; align-items: center; gap: 0.5rem; margin: 0.75rem 0 0.5rem calc(64px + 1rem); }
		/* (the dashboard sets white-space: nowrap on every div and span, and a fixed height on buttons) */
		#store-manage div, #store-manage span { white-space: normal; }
		#store-manage .st-head button, #store-manage .st-actions button, #store-manage .st-form button, #store-manage .st-back, #store-manage [data-st="activity"] button { height: auto; line-height: 1.4; padding: 0.3rem 0.9rem; white-space: nowrap; }
		#store-manage .st-actions button { margin: 0; }
		/* (the gradient fills the whole button once: repeated from inside the border, as browsers do by default, Firefox
		   shows its dark lower edge through the thin top border at some zoom levels - a second line below the border) */
		#store-manage button { background-origin: border-box; background-repeat: no-repeat; }
		/* (WD's own blue button - its button.sel - with a valid gradient: WD's unprefixed one isn't) */
		#store-manage button.st-primary { border-top: 1px solid #15abff; border-bottom: 1px solid #0067a6; background-color: #018be3; background-image: linear-gradient(to bottom, #0099ff, #027dc8); color: #fafafa; outline: 1px solid #0067a6; }
		#store-manage button.st-primary:hover { background-image: linear-gradient(to bottom, #027dc8, #0099ff); }
		#store-manage button.st-primary:disabled { background-image: linear-gradient(to bottom, #0099ff, #027dc8); cursor: default; }
		#store-manage .st-actions button.st-on { outline: 2px solid #0099ff; }
		/* Text boxes and selects alike: WD's grey box with a border all round (its own has only a top border) */
		#store-manage input[type=text], #store-manage input[type=password], #store-manage input[type=number], #store-manage select { box-sizing: border-box; height: 32px; padding: 0 6px 0 10px; border: 1px solid #c8c8c8; outline: 0; border-radius: 0; background-color: #f0f0f0; color: #4b5a68; font: 14px Arial, "Helvetica Neue", Helvetica, sans-serif; vertical-align: middle; }
		#store-manage input[type=text]:focus, #store-manage input[type=password]:focus, #store-manage input[type=number]:focus, #store-manage select:focus { border-color: #0099ff; }
		#store-manage select { padding-left: 6px; cursor: pointer; }
		#store-manage .st-actions button:disabled { opacity: 0.5; }
		#store-manage .st-links { display: inline-flex; gap: 1rem; margin-left: 0.5rem; }
		#store-manage #AppsDiag_Manually_Install { display: inline-block; position: relative; overflow: hidden; padding: 0.3rem 0.9rem; border-top: 1px solid #15abff; border-bottom: 1px solid #0067a6; outline: 1px solid #0067a6; background-color: #018be3; background-image: linear-gradient(to bottom, #0099ff, #027dc8); color: #fafafa; cursor: pointer; }
		#store-manage #AppsDiag_Manually_Install:hover { background-image: linear-gradient(to bottom, #027dc8, #0099ff); }
		#store-manage #store-wd-manual table { position: static !important; border-spacing: 0 !important; }
		#store-manage #available_apps { display: grid; grid-template-columns: repeat(auto-fill, minmax(17rem, 1fr)); gap: 0.6rem; width: 100%; padding: 0; }
		#store-manage #available_apps .appList { display: grid; grid-template-columns: 48px minmax(0, 1fr); grid-template-rows: auto 1fr auto; column-gap: 0.75rem; float: none; box-sizing: border-box; width: auto; height: auto; margin: 0; padding: 0.75rem; border: 1px solid rgba(127, 127, 127, 0.3); border-radius: 8px; background: rgba(127, 127, 127, 0.05); line-height: 1.4; }
		#store-manage #available_apps .app_icon { grid-row: 1 / span 3; float: none; width: 48px; height: 48px; margin: 0; background-size: contain; background-repeat: no-repeat; background-position: center; border-radius: 8px; }
		#store-manage #available_apps .app_name { height: auto; margin: 0; line-height: 1.4; font-weight: bold; }
		#store-manage #available_apps .app_desc { height: auto; margin-top: 0.15rem; padding: 0; font-size: 0.9em; opacity: 0.8; overflow-wrap: anywhere; }
		#store-manage #available_apps .app_desc .edit_detail { color: #0099ff; cursor: pointer; }
		#store-manage #available_apps .app_install_button { justify-self: start; margin: 0.5rem 0 0; height: auto; line-height: 1.4; padding: 0.3rem 0.9rem; }
		#store-manage .st-switch { display: inline-flex; align-items: center; gap: 0.35rem; margin: 0 0.25rem; cursor: pointer; white-space: nowrap; }
		#store-manage .st-badge.st-off { background: rgba(178, 106, 0, 0.18); }
		#store-manage .st-status { margin: 0.5rem 0; padding: 0.5rem 0.75rem; border-radius: 6px; background: rgba(47, 111, 219, 0.1); }
		#store-manage .st-status.st-done { background: rgba(46, 125, 50, 0.12); }
		#store-manage .st-status.st-failed { background: rgba(198, 40, 40, 0.12); }
		@media (max-width: 40rem) { #store-manage .st-actions { margin-left: 0; } }
		#store-manage .st-problems li.st-error { color: #c62828; }
		#store-manage .st-problems li.st-warning { color: #b26a00; }
		#store-manage .st-notice { padding: 0.5rem 0.75rem; border-left: 3px solid #b26a00; background: rgba(178, 106, 0, 0.08); margin: 0.6rem 0; }
		#store-manage .st-description h4 { margin: 1rem 0 0.4rem; }
		#store-manage .st-field { margin: 0.75rem 0; }
		#store-manage .st-field > label { display: block; font-weight: bold; margin-bottom: 0.2rem; }
		#store-manage .st-field .mg-note { margin-top: 0.2rem; }
		#store-manage .st-field-error { color: #c62828; font-size: 0.9em; }
		#store-manage .st-mounted { font-family: monospace; margin: 0.15rem 0 0.4rem; }
		#store-manage .st-mounts td { padding: 0.15rem 0.5rem 0.15rem 0; border: 0; }
		#store-manage .st-mounts code { user-select: all; }
		#store-manage .st-field input[type=text], #store-manage .st-field input[type=password], #store-manage .st-field input[type=number], #store-manage .st-field select { width: 26rem; max-width: 100%; }
		#store-manage .st-repo { display: flex; align-items: flex-start; gap: 1rem; padding: 0.75rem 0; border-bottom: 1px solid rgba(127, 127, 127, 0.2); }
		#store-manage .st-repo-info { flex: 1; min-width: 0; overflow-wrap: anywhere; }
		#store-manage .st-repo-info > .st-badge { margin: 0 0 0 0.5rem; vertical-align: 0.1em; }
		#store-manage .st-repo-actions { flex: none; display: flex; flex-wrap: wrap; justify-content: flex-end; gap: 0.5rem; }
		#store-manage .st-repo-actions button { margin: 0; height: auto; line-height: 1.4; padding: 0.3rem 0.9rem; }
		#store-manage .st-form { margin: 1rem 0; padding: 0.75rem 1rem; border: 1px solid rgba(127, 127, 127, 0.3); border-radius: 8px; }
		#store-manage .st-form h4 { margin: 0 0 0.5rem; }
	</style>

	<div class="st-titlebar">
		<div class="header_1 st-title"><span>Store</span></div>
		<div class="st-head">
			<span class="mg-note" data-st="nas"></span>
			<button type="button" data-st-action="refresh">Refresh</button>
		</div>
	</div>
	<div class="hr_0"><div class="hr_1"></div></div>
	<p data-st="message"></p>

	<div class="st-tabs">
		<button type="button" data-st-tab="installed">Installed</button>
		<button type="button" data-st-tab="apps">Apps</button>
		<button type="button" data-st-tab="recipes">Recipes</button>
		<button type="button" data-st-tab="manual" hidden>Manual install</button>
		<button type="button" data-st-tab="wd" hidden>WD Store</button>
		<button type="button" data-st-tab="repos">Repositories</button>
		<button type="button" data-st-tab="activity">Activity</button>
	</div>

	<div data-st="list">
		<div class="st-filters">
			<input type="text" data-st="search" placeholder="Search" spellcheck="false" autocomplete="off">
			<select data-st="category"></select>
			<label data-st="installed-only-label"><input type="checkbox" data-st="installed-only"> Installed only</label>
		</div>
		<p class="mg-note" data-st="list-note"></p>
		<div class="st-grid" data-st="grid"></div>
	</div>

	<div data-st="detail" hidden></div>

	<div data-st="manual" hidden>
		<p>Install an app from its package file <em>(<code>.bin</code>)</em> on this computer - e.g. one built with this project
			or downloaded from its releases. The NAS's own installer checks and installs it, as the Apps page's manual install did.</p>
		<div data-st="manual-holder"></div>
	</div>

	<div data-st="wd" hidden>
		<p class="mg-note">Western Digital's own app store, as the NAS's Apps page offered it.</p>
		<div data-st="wd-holder"></div>
	</div>

	<div data-st="activity" hidden>
		<p class="mg-note" data-st="activity-none">Nothing has been installed, updated or removed yet.</p>
		<div data-st="job" hidden>
			<p><strong data-st="job-title"></strong> - <span data-st="job-state"></span></p>
			<p class="mg-note" data-st="job-times"></p>
			<p data-st="job-message"></p>
			<pre class="st-log" data-st="job-log"></pre>
			<button type="button" data-st-action="job-close" hidden>Clear</button>
		</div>
	</div>

	<div data-st="repos" hidden>
		<div data-st="repo-list"></div>
		<div class="st-form">
			<h4>Add a repository</h4>
			<p><input type="text" data-st="repo-url" placeholder="https://github.com/owner/repo or https://example.com/store.json" spellcheck="false" autocomplete="off"></p>
			<p class="st-notice">Apps and recipes run as root: a repository's maintainer gets full control of the NAS. Only add
				repositories you trust.</p>
			<p><label><input type="checkbox" data-st="repo-confirm"> I trust this repository</label></p>
			<p><button type="button" data-st-action="repo-add">Add</button></p>
			<p data-st="repo-message"></p>
		</div>
	</div>

	<script>
	// Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
	(function () {
		var root = document.getElementById('store-manage');
		var api = '/apps/store/api.php';
		var csrf = <?php echo json_encode(manage_csrf_token('store')); ?>;
		var state = { tab: 'installed', catalogue: null, detail: null, polling: false, job: null, status: null };
		// (on the dashboard's Apps page - the Store's copy of it - the page can open apps' own pages and WD's app store)
		var appsPage = window.storeApps || null;

		// Small things kept for this browser session: the tab, and what to reopen after an app's Configure page
		function remember(key, value) {
			try { if (value === null) { sessionStorage.removeItem('store-' + key); } else { sessionStorage.setItem('store-' + key, JSON.stringify(value)); } } catch (e) { /* (not kept) */ }
		}
		function recall(key) {
			try { return JSON.parse(sessionStorage.getItem('store-' + key)); } catch (e) { return null; }
		}

		function part(name) { return root.querySelector('[data-st="' + name + '"]'); }
		function button(name) { return root.querySelector('[data-st-action="' + name + '"]'); }
		function element(tag, props, children) {
			var el = document.createElement(tag);
			Object.keys(props || {}).forEach(function (key) { el[key] = props[key]; });
			(children || []).forEach(function (child) { if (child) { el.appendChild(typeof child === 'string' ? document.createTextNode(child) : child); } });
			return el;
		}

		function say(text, good, where) {
			var message = part(where || 'message');
			message.textContent = text || '';
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

		function mb(value) { return value >= 1024 ? (Math.round(value / 102.4) / 10) + 'GB' : value + 'MB'; }

		function icon(item, extra) {
			var letter = element('span', { className: 'st-icon st-icon-none' + (extra || ''), textContent: (item.name || '?').charAt(0).toUpperCase() });
			if (!item.icon) { return letter; }
			// (an installed app's icon is its own file, which may be missing: then the letter)
			var img = element('img', { className: 'st-icon' + (extra || ''), src: item.icon, alt: '' });
			img.addEventListener('error', function () { if (img.parentNode) { img.parentNode.replaceChild(letter, img); } });
			return img;
		}

		// ------------------------------------------------------------------------------------------------------------
		// The catalogue

		function load() {
			return call('catalogue').then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				state.catalogue = d;
				part('nas').textContent = [d.nas.model, d.nas.firmware ? 'firmware ' + d.nas.firmware : '', mb(d.nas.ram_mb) + ' memory', mb(d.nas.disk_mb) + ' free'].filter(Boolean).join(' · ');
				var select = part('category');
				var chosen = select.value;
				select.textContent = '';
				select.appendChild(element('option', { value: '', textContent: 'All categories' }));
				d.categories.forEach(function (c) { select.appendChild(element('option', { value: c, textContent: c.charAt(0).toUpperCase() + c.slice(1) })); });
				select.value = chosen;
				root.querySelector('[data-st-tab="installed"]').textContent = 'Installed (' + installedItems().length + ')';
				root.querySelector('[data-st-tab="apps"]').textContent = 'Apps (' + d.apps.length + ')';
				root.querySelector('[data-st-tab="recipes"]').textContent = 'Recipes (' + d.recipes.length + ')';
				showList();
				showRepos();
			});
		}

		function isList(tab) { return tab === 'installed' || tab === 'apps' || tab === 'recipes'; }

		function showTab(tab) {
			if ((tab === 'wd' || tab === 'manual') && !appsPage) { tab = 'installed'; }
			state.tab = tab;
			state.detail = null;
			remember('tab', tab);
			[].forEach.call(root.querySelectorAll('[data-st-tab]'), function (b) { b.classList.toggle('st-on', b.getAttribute('data-st-tab') === tab); });
			part('list').hidden = !isList(tab);
			part('installed-only-label').hidden = tab === 'installed';
			part('repos').hidden = tab !== 'repos';
			part('wd').hidden = tab !== 'wd';
			part('manual').hidden = tab !== 'manual';
			part('activity').hidden = tab !== 'activity';
			part('detail').hidden = true;
			if (isList(tab)) { showList(); }
			if (tab === 'wd') { appsPage.wdStore(part('wd-holder')); }
			if (tab === 'manual') { appsPage.wdManual(part('manual-holder')); }
		}

		// What the NAS has installed: every app (as its Apps page lists them, with the repository's entry when there is
		// one) and the recipes
		function installedApp(id) {
			return state.catalogue ? state.catalogue.installed_apps.filter(function (a) { return a.id === id; })[0] || null : null;
		}

		function catalogueApp(app) {
			var matches = state.catalogue.apps.filter(function (a) { return a.id === app.id && (app.repo ? a.repo === app.repo : a.from_here); });
			if (!app.repo) {
				// (installed by hand: every repository may offer it - the newest version, and this project's on a tie)
				var isDefault = function (a) { return state.catalogue.repos.some(function (r) { return r.url === a.repo && r.default; }); };
				matches.sort(function (a, b) { return versionCompare(b.version, a.version) || (isDefault(b) ? 1 : 0) - (isDefault(a) ? 1 : 0); });
			}
			return matches[0] || null;
		}

		// Versions compared as the Store's server does: the leading numbers, then the rest (e.g. 3.3.5-2 < 3.3.5-3)
		function versionCompare(a, b) {
			var pa = String(a).match(/^(\d+(?:\.\d+)*)?(.*)$/), pb = String(b).match(/^(\d+(?:\.\d+)*)?(.*)$/);
			var na = pa[1] ? pa[1].split('.').map(Number) : [], nb = pb[1] ? pb[1].split('.').map(Number) : [];
			for (var i = 0; i < Math.max(na.length, nb.length); i++) {
				var x = na[i] || 0, y = nb[i] || 0;
				if (x !== y) { return x < y ? -1 : 1; }
			}
			return pa[2] === pb[2] ? 0 : (pa[2].localeCompare(pb[2], undefined, { numeric: true }) < 0 ? -1 : 1);
		}

		function installedItems() {
			var d = state.catalogue;
			var items = d.installed_apps.map(function (app) {
				var entry = catalogueApp(app);
				return { kind: 'apps', id: app.id, name: entry ? entry.name : app.name, summary: entry ? entry.summary : app.description,
					icon: entry ? entry.icon : app.icon, version: app.version, installed: app.version, update: entry ? entry.update : false,
					enabled: app.enabled, categories: entry ? entry.categories : [], repo: entry ? entry.repo : '', repo_name: entry ? entry.repo_name : '', entry: entry, app: app };
			});
			d.recipes.filter(function (r) { return r.installed && r.from_here; }).forEach(function (r) {
				items.push({ kind: 'recipes', id: r.id, name: r.name, summary: r.summary, icon: r.icon, version: r.installed, installed: r.installed,
					update: r.update, enabled: true, categories: r.categories, repo: r.repo, repo_name: r.repo_name, entry: r, recipe: true });
			});
			d.orphan_recipes.forEach(function (r) {
				var entry = { repo: r.repo, id: r.id, name: r.name, version: r.version, installed: r.version, update: false, from_here: true, icon: '' };
				items.push({ kind: 'recipes', id: r.id, name: r.name, summary: 'Its repository is no longer in the Store: no updates', icon: '', version: r.version,
					installed: r.version, update: false, enabled: true, categories: [], repo: r.repo, repo_name: '', entry: entry, recipe: true });
			});
			return items.sort(function (a, b) { return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1; });
		}

		function openInstalled(item) {
			if (item.entry) { showDetail(item.kind, item.entry); } else { showInstalledDetail(item.app); }
		}

		function showList() {
			var d = state.catalogue;
			if (!d || !isList(state.tab)) { return; }
			var installedTab = state.tab === 'installed';
			var items = installedTab ? installedItems() : d[state.tab];
			var search = part('search').value.trim().toLowerCase();
			var category = part('category').value;
			var installedOnly = part('installed-only').checked;
			var several = d.repos.filter(function (r) { return r.name; }).length > 1;
			var grid = part('grid');
			grid.textContent = '';
			var shown = items.filter(function (item) {
				return (!search || (item.name + ' ' + item.summary + ' ' + item.id).toLowerCase().indexOf(search) !== -1)
					&& (!category || item.categories.indexOf(category) !== -1)
					&& (installedTab || !installedOnly || item.installed);
			});
			shown.forEach(function (item) {
				var badges = element('div', { className: 'st-badges' });
				if (installedTab) {
					badges.appendChild(element('span', { className: 'st-badge', textContent: item.version }));
					if (item.recipe) { badges.appendChild(element('span', { className: 'st-badge', textContent: 'Recipe' })); }
					if (!item.enabled) { badges.appendChild(element('span', { className: 'st-badge st-off', textContent: 'Off' })); }
					if (item.update) { badges.appendChild(element('span', { className: 'st-badge st-update', textContent: 'Update: ' + item.entry.version })); }
				} else if (item.installed) {
					badges.appendChild(element('span', { className: 'st-badge st-installed', textContent: 'Installed ' + item.installed + (item.from_here ? '' : ' from ' + item.source_name) }));
				}
				if (!installedTab && item.update) {
					badges.appendChild(element('span', { className: 'st-badge st-update', textContent: 'Update: ' + item.version }));
				} else if (!installedTab && !item.installed) {
					badges.appendChild(element('span', { className: 'st-badge', textContent: item.version }));
				}
				if (item.supported === false) {
					badges.appendChild(element('span', { className: 'st-badge st-unsupported', textContent: 'Not for this NAS' }));
				}
				if (several) {
					badges.appendChild(element('span', { className: 'st-badge', textContent: item.repo_name }));
				}
				var card = element('div', { className: 'st-card', tabIndex: 0 }, [
					icon(item),
					element('div', { className: 'st-card-text' }, [element('strong', { textContent: item.name }), element('div', { className: 'st-summary', textContent: item.summary }), badges])
				]);
				card.setAttribute('role', 'button');
				var open = function () { if (installedTab) { openInstalled(item); } else { showDetail(state.tab, item); } };
				card.addEventListener('click', open);
				card.addEventListener('keydown', function (e) { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); open(); } });
				grid.appendChild(card);
			});
			var note = '';
			if (!installedTab && !d.repos.some(function (r) { return r.name; })) {
				note = 'No repository could be read yet - see Repositories.';
			} else if (!shown.length) {
				note = 'Nothing matches.';
			}
			part('list-note').textContent = note;
		}

		// ------------------------------------------------------------------------------------------------------------
		// An app's or recipe's page

		function showDetail(kind, item) {
			state.detail = { kind: kind, item: item };
			state.status = null;
			part('list').hidden = true;
			var view = part('detail');
			view.hidden = false;
			view.textContent = '';
			view.appendChild(detailHead(item, null));
			view.appendChild(element('p', { textContent: 'Loading…' }));
			call('details', null, '&kind=' + kind + '&repo=' + encodeURIComponent(item.repo) + '&id=' + encodeURIComponent(item.id)).then(function (d) {
				if (!state.detail || state.detail.item !== item) { return; }
				view.textContent = '';
				if (!d.ok) {
					view.appendChild(detailHead(item, null));
					view.appendChild(element('p', { className: 'mg-bad', textContent: d.error }));
					return;
				}
				renderDetail(view, kind, item, d);
			});
		}

		function link(url, text) { return element('a', { href: url, textContent: text, target: '_blank', rel: 'noopener noreferrer' }); }

		// Its icon, name and version, with Back on the right
		function detailHead(item, d) {
			var meta = d ? [d.version, d.license, d.repo_name ? 'from ' + d.repo_name : ''].filter(Boolean).join(' · ') : item.version;
			var back = element('button', { type: 'button', className: 'st-back', textContent: '← Back' });
			back.addEventListener('click', function () { showTab(state.tab); });
			return element('div', { className: 'st-detail-head' }, [
				icon(item),
				element('div', { className: 'st-detail-title' }, [element('h3', { textContent: d ? d.name : item.name }), element('span', { className: 'mg-note', textContent: meta })]),
				back
			]);
		}

		// The page: its head; one row of actions (Open, install/update/settings/remove) and links; the result of its
		// latest job; the form an action opened (if any); notices; then its description
		function renderDetail(view, kind, item, d) {
			view.appendChild(detailHead(item, d));
			var page = {
				bar: element('div', { className: 'st-actions' }),
				status: element('div', { className: 'st-status' }),
				message: element('p'),
				panel: element('div'),
				notes: element('div'),
				blocked: d.problems.some(function (p) { return p.level === 'error'; })
			};
			page.status.hidden = true;
			var inst = kind === 'apps' && item.installed ? installedApp(item.id) : null;
			if (inst) { configureButton(page, inst); }
			if (d.url) { addButton(page, 'Open', function () { window.open(d.url, '_blank', 'noopener'); }, false, inst && inst.url ? '' : 'st-primary'); }
			if (kind === 'apps') { renderAppActions(page, item, d); } else { renderRecipeActions(page, item, d); }
			var links = element('span', { className: 'st-links' });
			[['homepage', 'Homepage'], ['release_notes', 'Release notes'], ['sources', 'Sources']].forEach(function (l) {
				if (d[l[0]]) { links.appendChild(link(d[l[0]], l[1])); }
			});
			if (links.childNodes.length) { page.bar.appendChild(links); }
			[page.bar, page.status, page.message, page.panel, page.notes].forEach(function (e) { view.appendChild(e); });
			showFlash(page);
			state.status = { el: page.status, kind: kind, id: item.id };
			showStatus();
			if (d.orphan) {
				view.appendChild(element('p', { className: 'st-notice', textContent: 'Installed from ' + d.orphan + ', which the Store no longer reads: its settings can still be changed and it can be removed, but it won\'t get updates until that repository is added again.' }));
			}
			if (d.third_party) {
				view.appendChild(element('p', { className: 'st-notice', textContent: 'From a third-party repository (' + d.repo_name + '): it runs as root on the NAS.' }));
			}
			if (d.problems.length) {
				var list = element('ul', { className: 'st-problems' });
				d.problems.forEach(function (p) { list.appendChild(element('li', { className: 'st-' + p.level, textContent: p.message })); });
				view.appendChild(list);
			}
			var description = element('div', { className: 'st-description' });
			// (made by the server from Markdown, with everything escaped and only https links)
			description.innerHTML = d.description;
			view.appendChild(description);
		}

		function addButton(page, text, onClick, disabled, className) {
			var b = element('button', { type: 'button', textContent: text, disabled: !!disabled, className: className || '' });
			b.addEventListener('click', onClick);
			page.bar.appendChild(b);
			return b;
		}

		// A form opened by one of the action buttons, under the row (the same button closes it again)
		function togglePanel(page, name, build) {
			var open = page.panel.dataset.open === name;
			page.panel.textContent = '';
			page.panel.dataset.open = open ? '' : name;
			[].forEach.call(page.bar.querySelectorAll('button'), function (b) { b.classList.toggle('st-on', !open && b.dataset.panel === name); });
			if (!open) {
				var form = element('div', { className: 'st-form' });
				build(form);
				page.panel.appendChild(form);
			}
		}

		function panelButton(page, text, name, build, disabled) {
			var b = addButton(page, text, function () { togglePanel(page, name, build); }, disabled);
			b.dataset.panel = name;
			return b;
		}

		function startJob(data, message, onFields) {
			message.textContent = 'Starting…';
			message.className = '';
			return call('start', data).then(function (d) {
				if (!d.ok) {
					if (d.fields && onFields) { onFields(d.fields); }
					message.textContent = d.error;
					message.className = 'mg-bad';
					return false;
				}
				message.textContent = '';
				showJob(d);
				poll();
				return true;
			});
		}

		function renderAppActions(page, item, d) {
			if (d.replaces.length) {
				page.notes.appendChild(element('p', { className: 'st-notice', textContent: 'It replaces the NAS\'s own ' + d.replaces.join(', ') + ' while it\'s installed and on.' }));
			}
			var facts = [];
			if (d.size) { facts.push('Download: ' + (d.size < 1048576 ? Math.ceil(d.size / 1024) + 'KB' : mb(Math.ceil(d.size / 1048576)))); }
			if (d.data_folder) { facts.push('Its data is kept in Nas_Prog/' + d.data_folder + (d.keeps_data ? ' (kept across updates and removal)' : '')); }
			if (item.update && !item.can_update) { facts.push(item.version + ' is available - this app can\'t be updated by the Store without losing its settings, so update it by hand'); }
			if (facts.length) { page.notes.appendChild(element('p', { className: 'mg-note', textContent: facts.join('. ') + '.' })); }
			if (!item.installed) {
				addButton(page, 'Install', function () { startJob({ job: 'app_install', repo: item.repo, id: item.id }, page.message); }, page.blocked || !item.supported, 'st-primary');
				return;
			}
			var inst = installedApp(item.id);
			if (inst) { runSwitch(page, inst); }
			if (!item.from_here) {
				// (installed from another repository - e.g. the original of a fork: it can be switched to this one's)
				page.notes.insertBefore(element('p', { className: 'st-notice', textContent: 'Installed from ' + item.source_name + '. Its updates come from there'
					+ (item.can_update ? ' - or switch it to this repository\'s ' + item.version + ' (its data is kept, and its updates come from here from then on).' : '.') }), page.notes.firstChild);
				if (item.can_update && item.supported) {
					addButton(page, 'Switch to this repository', function () {
						if (window.confirm('Replace ' + d.name + ' from ' + item.source_name + ' with ' + d.repo_name + '\'s ' + item.version + '?\n\nIts data in Nas_Prog/' + d.data_folder + ' is kept, and its updates come from ' + d.repo_name + ' from then on.')) {
							startJob({ job: 'app_update', repo: item.repo, id: item.id }, page.message);
						}
					}, page.blocked);
				}
				return;
			}
			if (item.update && item.can_update) {
				addButton(page, 'Update to ' + item.version, function () { startJob({ job: 'app_update', repo: item.repo, id: item.id }, page.message); }, page.blocked, 'st-primary');
			}
			if (item.source === null) {
				// (installed by hand: other repositories with a newer version - updating from one makes it its source)
				var others = state.catalogue.apps.filter(function (a) { return a.id === item.id && a.repo !== item.repo && a.update; });
				if (others.length) {
					var also = element('p', { className: 'mg-note' }, ['Installed by hand, so any repository can update it - the update sets where its updates come from. Also offered by: ']);
					others.forEach(function (a, i) {
						var open = element('a', { href: '#', textContent: a.repo_name + ' (' + a.version + ')' });
						open.addEventListener('click', function (e) { e.preventDefault(); showDetail('apps', a); });
						if (i) { also.appendChild(document.createTextNode(', ')); }
						also.appendChild(open);
					});
					page.notes.appendChild(also);
				}
			}
			if (item.id === 'store') {
				storeRemoveButton(page);
			} else {
				addButton(page, 'Remove', function () {
					if (window.confirm('Remove ' + d.name + '?' + (d.data_folder ? ' Its data in Nas_Prog/' + d.data_folder + ' is kept.' : ''))) {
						startJob({ job: 'app_uninstall', repo: item.repo, id: item.id }, page.message);
					}
				});
			}
		}

		// Configure: the app's own page - inside the dashboard (CenterType 1), or its web interface on its port
		function configureButton(page, inst) {
			if (!inst.url || inst.id === 'store') { return; }
			addButton(page, 'Configure', function () {
				if (inst.center_type === 1) {
					remember('return', { kind: state.detail.kind, id: inst.id, tab: state.tab });
					if (appsPage) { appsPage.configure(inst.id, inst.url, inst.name); } else if (window.go_sub_page) { window.go_sub_page('/apps/' + inst.id + '/' + inst.url, inst.id); }
					return;
				}
				var port = inst.url_port && inst.url_port !== '80' ? ':' + inst.url_port : '';
				window.open('http://' + (window.IP_ADDRESS || state.catalogue.nas.ip) + port + '/' + inst.id + '/' + inst.url, '_blank', 'noopener');
			}, !inst.enabled, 'st-primary');
		}

		// Running: the NAS's own on/off switch for an app (through its own handler, which checks what the app depends on)
		function runSwitch(page, inst) {
			var $ = window.jQuery;
			if (!$) { return; }
			var box = element('input', { type: 'checkbox', checked: inst.enabled });
			page.bar.appendChild(element('label', { className: 'st-switch' }, [box, 'Running']));
			var refusals = { 13: 'it needs an app that isn\'t installed or running', 19: 'it conflicts with an app that\'s running', 15: 'an app that\'s running needs it' };
			box.addEventListener('change', function () {
				var on = box.checked;
				if (!on && inst.id === 'store' && !window.confirm('Turn the Store off? The NAS\'s own Apps page comes back.')) { box.checked = true; return; }
				box.disabled = true;
				page.message.textContent = (on ? 'Starting ' : 'Stopping ') + inst.name + '…';
				page.message.className = '';
				$.ajax({ url: '/cgi-bin/apkg_mgr.cgi', type: 'POST', cache: false, dataType: 'xml',
					data: { cmd: 'cgi_apps_set', f_module_name: inst.id, f_enable: on ? 1 : 0 } }).done(function (xml) {
					var result = parseInt($(xml).find('result').text(), 10);
					if (refusals[result]) {
						box.checked = !on;
						page.message.textContent = inst.name + ' can\'t be ' + (on ? 'started' : 'stopped') + ': ' + refusals[result] + '.';
						page.message.className = 'mg-bad';
						return;
					}
					inst.enabled = on;
					// (the page is drawn again with the app's new state: the message goes with it)
					state.flash = inst.name + (on ? ' is running.' : ' is stopped.');
					load().then(function () { if (state.detail) { reopenDetail(); } });
				}).fail(function () {
					box.checked = !on;
					page.message.textContent = 'The NAS didn\'t answer - try again.';
					page.message.className = 'mg-bad';
				}).always(function () { box.disabled = false; });
			});
		}

		function showFlash(page) {
			if (state.flash) {
				page.message.textContent = state.flash;
				page.message.className = 'mg-ok';
				state.flash = null;
			}
		}

		// Removing the Store itself: the NAS's own Apps page comes back, and everything it installed stays
		function storeRemoveButton(page) {
			addButton(page, 'Remove', function () {
				if (window.confirm('Remove the Store?\n\nThe NAS\'s own Apps page comes back. Everything the Store installed stays installed, and its settings (e.g. your repositories) are kept in Nas_Prog/_store for if you install it again.')) {
					startJob({ job: 'app_uninstall', repo: '', id: 'store' }, page.message);
				}
			});
		}

		// Once the Store has removed itself, its page has nothing left to call: say so, with the way to the NAS's own page
		function storeGone() {
			root.textContent = '';
			var open = element('button', { type: 'button', className: 'st-primary', textContent: 'Open the NAS\'s Apps page' });
			open.addEventListener('click', function () {
				if (window.go_page) { window.go_page('/web/addons/app.php', 'nav_addons'); } else { window.location.reload(); }
			});
			root.appendChild(element('div', { className: 'header_1 st-title' }, [element('span', { textContent: 'Store' })]));
			root.appendChild(element('div', { className: 'hr_0' }, [element('div', { className: 'hr_1' })]));
			root.appendChild(element('p', { textContent: 'The Store has been removed. Everything it installed is still installed, and its settings are kept in Nas_Prog/_store.' }));
			root.appendChild(element('p', {}, [open]));
		}

		function removingStore() { return state.job && state.job.action === 'app_uninstall' && state.job.target === 'store'; }

		// The page of an installed app that no repository offers (e.g. one of WD's): what the NAS knows about it
		function showInstalledDetail(app) {
			state.detail = { kind: 'installed', item: app };
			state.status = null;
			part('list').hidden = true;
			var view = part('detail');
			view.hidden = false;
			view.textContent = '';
			view.appendChild(detailHead(app, { name: app.name, version: app.version, license: '', repo_name: '' }));
			var page = { bar: element('div', { className: 'st-actions' }), status: element('div', { className: 'st-status' }), message: element('p') };
			page.status.hidden = true;
			configureButton(page, app);
			runSwitch(page, app);
			if (app.id === 'store') {
				storeRemoveButton(page);
			} else {
				addButton(page, 'Remove', function () {
					if (window.confirm('Remove ' + app.name + '?')) { startJob({ job: 'app_uninstall', repo: '', id: app.id }, page.message); }
				});
			}
			[page.bar, page.status, page.message].forEach(function (e) { view.appendChild(e); });
			showFlash(page);
			state.status = { el: page.status, kind: 'apps', id: app.id };
			showStatus();
			var from = app.repo ? state.catalogue.repos.filter(function (r) { return r.url === app.repo; })[0] : null;
			var origin = app.repo && !from ? 'Installed by the Store from ' + app.repo + ', which it no longer reads: add that repository again for its updates.'
				: 'Not offered by any repository the Store reads.';
			view.appendChild(element('p', { className: 'mg-note', textContent: (app.installed ? 'Installed ' + app.installed + '. ' : '') + origin }));
			if (app.description) { view.appendChild(element('p', { textContent: app.description })); }
		}

		// The open page again, from the catalogue as it is now (after a job, or switching an app on or off)
		function reopenDetail() {
			var kind = state.detail.kind;
			var item = state.detail.item;
			if (kind === 'installed') {
				var app = installedApp(item.id);
				if (app) { showInstalledDetail(app); } else { showTab(state.tab); }
				return;
			}
			var current = state.catalogue[kind].filter(function (i) { return i.repo === item.repo && i.id === item.id; })[0]
				|| (installedItems().filter(function (i) { return i.kind === kind && i.repo === item.repo && i.id === item.id; })[0] || {}).entry;
			if (current) { showDetail(kind, current); } else { showTab(state.tab); }
		}

		// ------------------------------------------------------------------------------------------------------------
		// Recipes: the wizard, settings, update and removal

		function renderRecipeActions(page, item, d) {
			if (!d.installed) {
				if (!item.from_here) {
					page.notes.appendChild(element('p', { className: 'st-notice', textContent: 'Installed from ' + (item.source_name || 'another repository') + ': its settings, updates and removal are on its page there.' }));
					return;
				}
				var installButton = panelButton(page, 'Install', 'install', function (form) {
					form.appendChild(element('h4', { textContent: 'Install' }));
					if (d.existing) {
						form.appendChild(element('p', { className: 'st-notice', textContent: 'Settings from an earlier install were found in ' + d.existing + ': they\'re filled in below and reused (e.g. its database password).' }));
					}
					var fields = wizard(form, d.wizard);
					form.appendChild(element('p', { className: 'mg-note', textContent: 'Its settings and data go in ' + d.data_folder + (d.web ? '. With the Nginx app, it gets the site ' + d.web + '.<your domain>' : '') + '.' }));
					var install = element('button', { type: 'button', className: 'st-primary', textContent: 'Install', disabled: page.blocked });
					install.addEventListener('click', function () {
						startJob({ job: 'recipe_install', repo: item.repo, id: item.id, answers: JSON.stringify(fields.values()) }, page.message, fields.errors);
					});
					form.appendChild(element('p', {}, [install]));
				}, page.blocked);
				installButton.classList.add('st-primary');
				return;
			}
			page.notes.appendChild(element('p', { className: 'mg-note', textContent: 'Installed ' + d.installed.version + ' - its folder: ' + d.installed.data }));
			if (d.mounts && d.mounts.length) {
				// (what to type in the app's own settings, e.g. Immich's external libraries)
				var mounts = element('div', { className: 'st-notice' }, [element('strong', { textContent: 'Your folders, as ' + d.name + ' sees them' })]);
				var table = element('table', { className: 'st-mounts' });
				d.mounts.forEach(function (m) {
					table.appendChild(element('tr', {}, [element('td', { textContent: m[1] }), element('td', { textContent: '→' }), element('td', {}, [element('code', { textContent: m[2] })])]));
				});
				mounts.appendChild(table);
				page.notes.appendChild(mounts);
			}
			if (item.update) {
				var update = function (answers) {
					startJob({ job: 'recipe_update', repo: item.repo, id: item.id, answers: JSON.stringify(answers.values()) }, page.message, answers.errors);
				};
				if (d.update_fields.length) {
					// (an update with new options asks them first)
					panelButton(page, 'Update to ' + item.version, 'update', function (form) {
						form.appendChild(element('h4', { textContent: 'Update to ' + item.version }));
						var fields = wizard(form, d.update_fields);
						var go = element('button', { type: 'button', className: 'st-primary', textContent: 'Update', disabled: page.blocked });
						go.addEventListener('click', function () { update(fields); });
						form.appendChild(element('p', {}, [go]));
					}, page.blocked).classList.add('st-primary');
				} else {
					addButton(page, 'Update to ' + item.version, function () {
						if (window.confirm('Update ' + d.name + ' to ' + item.version + '?')) { update({ values: function () { return {}; } }); }
					}, page.blocked, 'st-primary');
				}
			}
			if (d.settings.length) {
				panelButton(page, 'Settings', 'settings', function (form) {
					form.appendChild(element('h4', { textContent: 'Settings' }));
					var settings = wizard(form, d.settings);
					var save = element('button', { type: 'button', className: 'st-primary', textContent: 'Save and apply' });
					save.addEventListener('click', function () {
						startJob({ job: 'recipe_change', repo: item.repo, id: item.id, answers: JSON.stringify(settings.values()) }, page.message, settings.errors);
					});
					form.appendChild(element('p', {}, [save]));
				});
			}
			panelButton(page, 'Remove', 'remove', function (form) {
				form.appendChild(element('h4', { textContent: 'Remove' }));
				var boxes = [];
				d.deletable.forEach(function (f) {
					var box = element('input', { type: 'checkbox' });
					box.dataset.key = f.key;
					boxes.push(box);
					form.appendChild(element('p', {}, [element('label', {}, [box, ' Also delete ' + f.label + ': ' + f.folder])]));
				});
				var dataBox = element('input', { type: 'checkbox' });
				form.appendChild(element('p', {}, [element('label', {}, [dataBox, ' Also delete its folder ' + d.installed.data + ' (its settings and data - otherwise installing it again reuses them)'])]));
				if (d.kept.length) { form.appendChild(element('p', { className: 'mg-note', textContent: 'Always kept: ' + d.kept.join(', ') })); }
				var remove = element('button', { type: 'button', textContent: 'Remove' });
				remove.addEventListener('click', function () {
					var deleting = boxes.filter(function (b) { return b.checked; }).map(function (b) { return b.dataset.key; });
					if (window.confirm('Remove ' + d.name + '?' + (deleting.length || dataBox.checked ? ' The folders ticked are deleted for good.' : ''))) {
						startJob({ job: 'recipe_uninstall', repo: item.repo, id: item.id, delete: JSON.stringify(deleting), delete_data: dataBox.checked ? '1' : '' }, page.message);
					}
				});
				form.appendChild(element('p', {}, [remove]));
			});
		}

		// Where a mounted folder appears in its container (as the server works it out)
		function mountedAs(target, folder) {
			var volume = state.catalogue.volume + '/';
			var relative = folder.indexOf(volume) === 0 ? folder.slice(volume.length) : folder.replace(/^\/mnt\//, '');
			return target.replace(/\/$/, '') + '/' + relative;
		}

		// Builds a recipe's form. Returns { values(), errors(map) }
		function wizard(container, fields) {
			var getters = {};
			var errorParts = {};
			var advanced = element('details', {}, [element('summary', { textContent: 'Advanced' })]);
			var zones = (window.Intl && Intl.supportedValuesOf) ? Intl.supportedValuesOf('timeZone') : [];
			fields.forEach(function (f) {
				var box = element('div', { className: 'st-field' });
				box.appendChild(element('label', { textContent: f.label + (f.required ? '' : ' (optional)') }));
				var input;
				if (f.type === 'boolean') {
					input = element('input', { type: 'checkbox', checked: !!f.value });
					box.firstChild.textContent = '';
					box.firstChild.appendChild(input);
					box.firstChild.appendChild(document.createTextNode(' ' + f.label));
					getters[f.key] = function () { return input.checked; };
				} else if (f.type === 'choice') {
					input = element('select');
					f.choices.forEach(function (c) { input.appendChild(element('option', { value: c.value, textContent: c.label })); });
					input.value = f.value;
					getters[f.key] = function () { return input.value; };
				} else if (f.type === 'folder' && f.multiple) {
					var list = element('div');
					var addRow = function (value) {
						var row = element('div');
						var text = element('input', { type: 'text', value: value || '', placeholder: state.catalogue.volume + '/…', spellcheck: false, autocomplete: 'off' });
						var shown = element('div', { className: 'mg-note st-mounted' });
						var update = function () { shown.textContent = text.value.trim() && f.mount ? 'In the app: ' + mountedAs(f.mount.target, text.value.trim().replace(/\/+$/, '')) : ''; };
						text.addEventListener('input', update);
						update();
						var remove = element('button', { type: 'button', textContent: 'Remove' });
						remove.addEventListener('click', function () { row.remove(); });
						row.appendChild(text);
						row.appendChild(remove);
						row.appendChild(shown);
						list.appendChild(row);
					};
					(f.value || []).forEach(addRow);
					var add = element('button', { type: 'button', textContent: 'Add a folder' });
					add.addEventListener('click', function () { addRow(''); });
					box.appendChild(list);
					box.appendChild(add);
					getters[f.key] = function () {
						return [].map.call(list.querySelectorAll('input'), function (i) { return i.value.trim(); }).filter(Boolean);
					};
				} else {
					var type = f.type === 'password' ? 'password' : (f.type === 'number' || f.type === 'port' ? 'number' : 'text');
					input = element('input', { type: type, value: f.value === undefined || f.value === null ? '' : f.value, spellcheck: false, autocomplete: f.type === 'password' ? 'new-password' : 'off' });
					if (f.saved) { input.placeholder = '(saved - leave empty to keep)'; }
					if (f.min !== undefined) { input.min = f.min; }
					if (f.max !== undefined) { input.max = f.max; }
					if (f.type === 'timezone' && zones.length) {
						var listId = 'st-zones-' + Math.random().toString(36).slice(2);
						var datalist = element('datalist', { id: listId });
						zones.forEach(function (z) { datalist.appendChild(element('option', { value: z })); });
						box.appendChild(datalist);
						input.setAttribute('list', listId);
					}
					if (f.type === 'folder' && !f.value) { input.placeholder = state.catalogue.volume + '/…'; }
					getters[f.key] = function () { return input.value.trim(); };
				}
				if (input && f.type !== 'boolean') { box.appendChild(input); }
				if (f.help) { box.appendChild(element('div', { className: 'mg-note', textContent: f.help })); }
				errorParts[f.key] = element('div', { className: 'st-field-error' });
				box.appendChild(errorParts[f.key]);
				(f.advanced ? advanced : container).appendChild(box);
			});
			if (advanced.children.length > 1) { container.appendChild(advanced); }
			return {
				values: function () {
					var values = {};
					Object.keys(getters).forEach(function (key) { values[key] = getters[key](); });
					Object.keys(errorParts).forEach(function (key) { errorParts[key].textContent = ''; });
					return values;
				},
				errors: function (map) {
					Object.keys(map).forEach(function (key) {
						if (errorParts[key]) {
							errorParts[key].textContent = map[key];
							if (errorParts[key].closest('details')) { errorParts[key].closest('details').open = true; }
						}
					});
				}
			};
		}

		// ------------------------------------------------------------------------------------------------------------
		// Repositories

		function showRepos() {
			var listEl = part('repo-list');
			listEl.textContent = '';
			state.catalogue.repos.forEach(function (r) {
				var entry = element('div', { className: 'st-repo' });
				var box = element('div', { className: 'st-repo-info' });
				entry.appendChild(box);
				box.appendChild(element('strong', { textContent: r.name || r.url }));
				if (r.default) { box.appendChild(element('span', { className: 'st-badge', textContent: 'Default' })); }
				box.appendChild(element('div', { className: 'mg-note', textContent: r.url }));
				if (r.summary) { box.appendChild(element('div', { textContent: r.summary })); }
				var facts = [];
				if (r.name) { facts.push(r.apps + ' apps, ' + r.recipes + ' recipes'); }
				if (r.maintainer) { facts.push('by ' + r.maintainer); }
				if (r.updated) { facts.push('updated ' + r.updated.slice(0, 10)); }
				facts.push(r.signed ? 'signed (key ' + r.fingerprint + ')' : 'not signed');
				box.appendChild(element('div', { className: 'mg-note', textContent: facts.join(' · ') }));
				if (r.homepage) { box.appendChild(element('div', {}, [link(r.homepage, r.homepage)])); }
				if (r.error) { box.appendChild(element('div', { className: 'mg-bad', textContent: r.error })); }
				var actions = element('div', { className: 'st-repo-actions' });
				if (r.key_changed) {
					box.appendChild(element('p', { className: 'st-notice', textContent: 'Its signing key has changed to ' + r.new_fingerprint + '. Only accept it if its maintainer announced the change - otherwise someone may be impersonating it.' }));
					var accept = element('button', { type: 'button', textContent: 'Accept the new key' });
					accept.addEventListener('click', function () {
						if (!window.confirm('Trust the new key ' + r.new_fingerprint + '?')) { return; }
						call('accept_key', { url: r.url, fingerprint: r.new_fingerprint }).then(function (d) {
							if (!d.ok) { say(d.error, false, 'repo-message'); return; }
							load();
						});
					});
					actions.appendChild(accept);
				}
				var remove = element('button', { type: 'button', textContent: 'Remove' });
				remove.addEventListener('click', function () {
					var from = installedItems().filter(function (i) { return i.recipe ? i.repo === r.url : i.app.repo === r.url; }).map(function (i) { return i.name; });
					if (!window.confirm('Remove the repository ' + (r.name || r.url) + '?' + (from.length
						? '\n\nInstalled from it: ' + from.join(', ') + '. They stay installed and keep working (their settings can still be changed), but get no updates until it\'s added again.'
						: ' Nothing installed came from it.'))) { return; }
					call('remove_repo', { url: r.url }).then(function (d) {
						if (!d.ok) { say(d.error, false, 'repo-message'); return; }
						load();
					});
				});
				actions.appendChild(remove);
				entry.appendChild(actions);
				listEl.appendChild(entry);
			});
			if (!state.catalogue.repos.length) { listEl.appendChild(element('p', { className: 'mg-note', textContent: 'No repositories.' })); }
		}

		// ------------------------------------------------------------------------------------------------------------
		// Jobs: the full log is on the Activity tab; an app's or recipe's page shows only how its latest job went

		function jobKind(job) { return job.action.indexOf('recipe_') === 0 ? 'recipes' : 'apps'; }

		function showJob(d) {
			var job = d.job;
			state.job = job;
			var tab = root.querySelector('[data-st-tab="activity"]');
			tab.textContent = job && job.state === 'running' ? 'Activity (working…)' : 'Activity';
			part('job').hidden = !job;
			part('activity-none').hidden = !!job;
			showStatus();
			if (!job) { return; }
			part('job-title').textContent = job.title;
			var stateText = { running: 'running…', done: 'done', failed: 'failed' }[job.state] || job.state;
			part('job-state').textContent = stateText;
			part('job-state').className = job.state === 'done' ? 'mg-ok' : (job.state === 'failed' ? 'mg-bad' : '');
			part('job-times').textContent = 'Started ' + (job.started || '').replace('T', ' ').slice(0, 19) + (job.finished ? ' - finished ' + job.finished.replace('T', ' ').slice(0, 19) : '');
			part('job-message').textContent = job.message || '';
			var log = part('job-log');
			var atEnd = log.scrollTop + log.clientHeight >= log.scrollHeight - 10;
			log.textContent = d.log;
			if (atEnd) { log.scrollTop = log.scrollHeight; }
			button('job-close').hidden = job.state === 'running';
		}

		// The latest job's state on the page of the app or recipe it was for
		function showStatus() {
			var s = state.status;
			var job = state.job;
			if (!s || !s.el.isConnected) { return; }
			s.el.textContent = '';
			s.el.hidden = !(job && job.target === s.id && jobKind(job) === s.kind);
			if (s.el.hidden) { return; }
			s.el.className = 'st-status st-' + job.state;
			var text = job.state === 'running' ? job.title + '…' : (job.state === 'done' ? '✓ ' : 'Failed: ') + (job.message || job.title);
			var logLink = element('a', { href: '#', textContent: job.state === 'running' ? 'Follow the log' : 'Show the log' });
			logLink.addEventListener('click', function (e) { e.preventDefault(); showTab('activity'); });
			s.el.appendChild(element('span', { textContent: text + ' ' }));
			s.el.appendChild(logLink);
		}

		function poll() {
			if (state.polling) { return; }
			state.polling = true;
			var tick = function () {
				call('job').then(function (d) {
					// (its page and API go as the Store removes itself)
					if (!d.ok) { state.polling = false; if (removingStore()) { storeGone(); } return; }
					showJob(d);
					if (removingStore() && d.job.state === 'done') { state.polling = false; storeGone(); return; }
					if (d.job && d.job.state === 'running') {
						setTimeout(tick, 1500);
						return;
					}
					state.polling = false;
					load().then(function () { if (state.detail) { reopenDetail(); } });
				});
			};
			tick();
		}

		// ------------------------------------------------------------------------------------------------------------

		[].forEach.call(root.querySelectorAll('[data-st-tab]'), function (b) {
			b.addEventListener('click', function () { showTab(b.getAttribute('data-st-tab')); });
		});
		part('search').addEventListener('input', showList);
		part('category').addEventListener('change', showList);
		part('installed-only').addEventListener('change', showList);

		function refresh(working) {
			say(working, true);
			button('refresh').disabled = true;
			call('refresh', {}).then(function (d) {
				button('refresh').disabled = false;
				if (!d.ok) { say(d.error, false); return; }
				say(d.errors.length ? d.errors.join(' · ') : 'Up to date.', !d.errors.length);
				load();
			});
		}
		button('refresh').addEventListener('click', function () { refresh('Refreshing the repositories…'); });

		button('repo-add').addEventListener('click', function () {
			var url = part('repo-url').value.trim();
			say('Adding…', true, 'repo-message');
			call('add_repo', { url: url, confirm: part('repo-confirm').checked ? '1' : '' }).then(function (d) {
				if (!d.ok) { say(d.error, false, 'repo-message'); return; }
				say('Added ' + d.name + (d.fingerprint ? ' - its signing key (' + d.fingerprint + ') is now required for its updates' : ' (not signed)') + '.', true, 'repo-message');
				part('repo-url').value = '';
				part('repo-confirm').checked = false;
				load();
			});
		});

		button('job-close').addEventListener('click', function () {
			call('clear_job', {}).then(function () { showJob({ job: null, log: '' }); });
		});

		if (appsPage) {
			root.querySelector('[data-st-tab="wd"]').hidden = false;
			root.querySelector('[data-st-tab="manual"]').hidden = !appsPage.wdManual;
		}
		var back = recall('return');
		remember('return', null);
		showTab(back ? back.tab : (recall('tab') || 'installed'));
		load().then(function () {
			if (back && state.catalogue) {
				var item = installedItems().filter(function (i) { return i.id === back.id && i.kind === 'apps'; })[0];
				if (item) { openInstalled(item); }
			}
			// (a repository not checked in the last hour - or never: new versions are looked for by themselves)
			if (state.catalogue && state.catalogue.stale) { refresh('Checking the repositories for new versions…'); }
			call('job').then(function (d) {
				if (d.ok && d.job) { showJob(d); if (d.job.state === 'running') { poll(); } }
			});
		});
	})();
	</script>
</div>
