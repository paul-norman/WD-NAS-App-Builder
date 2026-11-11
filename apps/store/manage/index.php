<?php
// The Store's page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see manage_helpers.php
require __DIR__.'/manage_helpers.php';

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
        #store-manage .st-badge { display: inline-block; box-sizing: border-box; max-width: 100%; white-space: normal; overflow-wrap: anywhere; font-size: 0.75em; padding: 0.05rem 0.45rem; border-radius: 1rem; margin: 0.3rem 0.3rem 0 0; background: rgba(127, 127, 127, 0.18); }
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
        #store-manage details.st-form summary { cursor: pointer; }
        #store-manage details.st-form[open] summary { margin-bottom: 0.5rem; }
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
            or downloaded from its releases. The NAS's own installer checks and installs it, as the Apps page's manual installation did.</p>
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
        <details class="st-form" data-st="auto">
            <summary><strong>Automatic updates</strong> <span data-st="auto-summary"></span></summary>
            <p class="mg-note">Every night at 04:30 the Store updates the apps and recipes ticked <strong>Update
                automatically</strong> on their pages: one at a time, from the repository each came from - the Store
                itself last. Updates that need you (e.g. new settings) are left for you, and said so here.</p>
            <ul data-st="auto-list"></ul>
            <p class="mg-note" data-st="auto-last"></p>
            <p data-st="auto-ntfy" hidden>Tell the ntfy app's topic <input type="text" data-st="auto-topic" placeholder="e.g. nas" spellcheck="false" autocomplete="off">
                <button type="button" data-st-action="auto-topic">Save</button>
                <span class="mg-note">(updates, failures, and updates left for you - blank for none)</span></p>
            <p data-st="auto-message"></p>
        </details>
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
        <?php manage_core_script('store', 'st'); ?>

        // On the dashboard's Apps page - the Store's copy of it - it can open apps' own pages and WD's app store
        let appsPage = window.storeApps || null;
        let state    = {
            tab:       'installed',
            catalogue: null,
            detail:    null,
            polling:   false,
            job:       null,
            status:    null
        };

        /**
         * Keeps something for this browser session: the tab, and what to reopen after an app's Configure page.
         *
         * @param {string} key   What it is
         * @param {*}      value The value (null forgets it)
         *
         * @return {void}
         */
        function remember(key, value) {
            try {
                if (value === null) {
                    sessionStorage.removeItem('store-' + key);
                } else {
                    sessionStorage.setItem('store-' + key, JSON.stringify(value));
                }
            } catch (exception) { /* (not kept) */ }
        }

        /**
         * Something kept for this browser session (see remember()).
         *
         * @param {string} key What it is
         *
         * @return {*} The value, or null
         */
        function recall(key) {
            try {
                return JSON.parse(sessionStorage.getItem('store-' + key));
            } catch (exception) {
                return null;
            }
        }

        /**
         * Makes an element, with properties and children.
         *
         * @param {string} tag      Its tag
         * @param {Object} props    Its properties (e.g. className, textContent)
         * @param {Array}  children Its children: elements or text (empty ones are skipped)
         *
         * @return {HTMLElement} The element
         */
        function element(tag, props, children) {
            let el = document.createElement(tag);

            Object.keys(props || {}).forEach(function (key) {
                el[key] = props[key];
            });

            (children || []).forEach(function (child) {
                if (child) {
                    el.appendChild(typeof child === 'string' ? document.createTextNode(child) : child);
                }
            });

            return el;
        }

        /**
         * A size in megabytes, as the page shows it (e.g. 512MB, 3.9GB).
         *
         * @param {number} value The size
         *
         * @return {string} The size
         */
        function formatMegabytes(value) {
            return value >= 1024 ? (Math.round(value / 102.4) / 10) + 'GB' : value + 'MB';
        }

        /**
         * An app's or recipe's icon: its repository's, else an installed app's own (e.g. Plex's, which comes with its
         * package), else its first letter - also when the icon can't be loaded.
         *
         * @param {Object} item  The app or recipe
         * @param {string} extra More class names
         *
         * @return {HTMLElement} The icon
         */
        function itemIcon(item, extra) {
            let letter    = element('span', { className: 'st-icon st-icon-none' + (extra || ''), textContent: (item.name || '?').charAt(0).toUpperCase() });
            // Without one from its repository, an installed app's own icon - e.g. Plex's, from its package
            let installed = !item.icon && !item.recipe && item.id && state.catalogue ? installedApp(item.id) : null;
            let src       = item.icon || (item.app && item.app.icon) || (installed ? installed.icon : '');

            if (!src) {
                return letter;
            }

            // An installed app's icon is its own file, which may be missing: then the letter
            let img = element('img', { className: 'st-icon' + (extra || ''), src: src, alt: '' });

            img.addEventListener('error', function () {
                if (img.parentNode) {
                    img.parentNode.replaceChild(letter, img);
                }
            });

            return img;
        }

        // ------------------------------------------------------------------------------------------------------------
        // The catalogue

        /**
         * Loads the catalogue and the NAS's details, then shows the list and the repositories again.
         *
         * @return {Promise} Done once it's shown
         */
        function loadCatalogue() {
            return call('catalogue').then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return;
                }

                state.catalogue = response;

                part('nas').textContent = [response.nas.model, response.nas.firmware ? 'firmware ' + response.nas.firmware : '', formatMegabytes(response.nas.ram_mb) + ' memory', formatMegabytes(response.nas.disk_mb) + ' free'].filter(Boolean).join(' · ');

                let select = part('category');
                let chosen = select.value;

                select.textContent = '';
                select.appendChild(element('option', { value: '', textContent: 'All categories' }));

                response.categories.forEach(function (category) {
                    select.appendChild(element('option', { value: category, textContent: category.charAt(0).toUpperCase() + category.slice(1) }));
                });

                select.value = chosen;

                root.querySelector('[data-st-tab="installed"]').textContent = 'Installed (' + installedItems().length + ')';
                root.querySelector('[data-st-tab="apps"]').textContent      = 'Apps (' + response.apps.length + ')';
                root.querySelector('[data-st-tab="recipes"]').textContent   = 'Recipes (' + response.recipes.length + ')';

                showList();
                showRepos();
                showAuto();
            });
        }

        /**
         * Whether a tab shows a list of apps or recipes.
         *
         * @param {string} tab The tab
         *
         * @return {boolean} Whether it does
         */
        function isListTab(tab) {
            return tab === 'installed' || tab === 'apps' || tab === 'recipes';
        }

        /**
         * Shows one of the page's tabs (the Installed tab instead of WD's ones, outside the dashboard's Apps page).
         *
         * @param {string} tab The tab
         *
         * @return {void}
         */
        function showTab(tab) {
            if ((tab === 'wd' || tab === 'manual') && !appsPage) {
                tab = 'installed';
            }

            state.tab    = tab;
            state.detail = null;

            remember('tab', tab);

            [].forEach.call(root.querySelectorAll('[data-st-tab]'), function (tabButton) {
                tabButton.classList.toggle('st-on', tabButton.getAttribute('data-st-tab') === tab);
            });

            part('list').hidden                 = !isListTab(tab);
            part('installed-only-label').hidden = tab === 'installed';
            part('repos').hidden                = tab !== 'repos';
            part('wd').hidden                   = tab !== 'wd';
            part('manual').hidden               = tab !== 'manual';
            part('activity').hidden             = tab !== 'activity';
            part('detail').hidden               = true;

            if (isListTab(tab)) {
                showList();
            }

            if (tab === 'wd') {
                appsPage.wdStore(part('wd-holder'));
            }

            if (tab === 'manual') {
                appsPage.wdManual(part('manual-holder'));
            }
        }

        /**
         * An installed app, as the NAS's Apps page lists it.
         *
         * @param {string} id The app's id
         *
         * @return {Object|null} The app, or null if it isn't installed
         */
        function installedApp(id) {
            return state.catalogue ? state.catalogue.installed_apps.filter(function (app) {
                return app.id === id;
            })[0] || null : null;
        }

        /**
         * The repository's entry for an installed app: from the repository it was installed from - or, for one
         * installed by hand, the newest version any repository offers (this project's on a tie).
         *
         * @param {Object} app The installed app
         *
         * @return {Object|null} The entry, or null if no repository offers it
         */
        function catalogueApp(app) {
            let matches = state.catalogue.apps.filter(function (a) {
                return a.id === app.id && (app.repo ? a.repo === app.repo : a.from_here);
            });

            if (!app.repo) {
                // Installed by hand: every repository may offer it - the newest version, and this project's on a tie
                let isDefault = function (a) {
                    return state.catalogue.repos.some(function (repo) {
                        return repo.url === a.repo && repo.default;
                    });
                };

                matches.sort(function (a, b) {
                    return versionCompare(b.version, a.version) || (isDefault(b) ? 1 : 0) - (isDefault(a) ? 1 : 0);
                });
            }

            return matches[0] || null;
        }

        /**
         * Compares two versions as the Store's server does: the leading numbers, then the rest (e.g. 3.3.5-2 <
         * 3.3.5-3).
         *
         * @param {string} a A version
         * @param {string} b The version to compare it with
         *
         * @return {number} -1, 0 or 1 - as a is older than, the same as or newer than b
         */
        function versionCompare(a, b) {
            let partsA   = String(a).match(/^(\d+(?:\.\d+)*)?(.*)$/);
            let partsB   = String(b).match(/^(\d+(?:\.\d+)*)?(.*)$/);
            let numbersA = partsA[1] ? partsA[1].split('.').map(Number) : [];
            let numbersB = partsB[1] ? partsB[1].split('.').map(Number) : [];

            for (let i = 0; i < Math.max(numbersA.length, numbersB.length); i++) {
                let numberA = numbersA[i] || 0;
                let numberB = numbersB[i] || 0;

                if (numberA !== numberB) {
                    return numberA < numberB ? -1 : 1;
                }
            }

            return partsA[2] === partsB[2] ? 0 : (partsA[2].localeCompare(partsB[2], undefined, { numeric: true }) < 0 ? -1 : 1);
        }

        /**
         * What the NAS has installed, for the Installed tab: every app (as its Apps page lists them, with the
         * repository's entry when there is one) and the recipes, by name.
         *
         * @return {Array.<Object>} The items
         */
        function installedItems() {
            let catalogue = state.catalogue;
            let items     = catalogue.installed_apps.map(function (app) {
                let entry = catalogueApp(app);

                return {
                    kind:       'apps',
                    id:         app.id,
                    name:       entry ? entry.name : app.name,
                    summary:    entry ? entry.summary : app.description,
                    icon:       entry ? entry.icon : app.icon,
                    version:    app.version,
                    installed:  app.version,
                    update:     entry ? entry.update : false,
                    enabled:    app.enabled,
                    categories: entry ? entry.categories : [],
                    repo:       entry ? entry.repo : '',
                    repo_name:  entry ? entry.repo_name : '',
                    entry:      entry,
                    app:        app
                };
            });

            catalogue.recipes.filter(function (recipe) {
                return recipe.installed && recipe.from_here;
            }).forEach(function (recipe) {
                items.push({
                    kind:       'recipes',
                    id:         recipe.id,
                    name:       recipe.name,
                    summary:    recipe.summary,
                    icon:       recipe.icon,
                    version:    recipe.installed,
                    installed:  recipe.installed,
                    update:     recipe.update,
                    enabled:    true,
                    categories: recipe.categories,
                    repo:       recipe.repo,
                    repo_name:  recipe.repo_name,
                    entry:      recipe,
                    recipe:     true
                });
            });

            catalogue.orphan_recipes.forEach(function (recipe) {
                let entry = {
                    repo:      recipe.repo,
                    id:        recipe.id,
                    name:      recipe.name,
                    version:   recipe.version,
                    installed: recipe.version,
                    update:    false,
                    from_here: true,
                    icon:      ''
                };

                items.push({
                    kind:       'recipes',
                    id:         recipe.id,
                    name:       recipe.name,
                    summary:    'Its repository is no longer in the Store: no updates',
                    icon:       '',
                    version:    recipe.version,
                    installed:  recipe.version,
                    update:     false,
                    enabled:    true,
                    categories: [],
                    repo:       recipe.repo,
                    repo_name:  '',
                    entry:      entry,
                    recipe:     true
                });
            });

            return items.sort(function (a, b) {
                return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1;
            });
        }

        /**
         * Opens an installed app's or recipe's page: its repository's, else what the NAS knows about it.
         *
         * @param {Object} item The item, from installedItems()
         *
         * @return {void}
         */
        function openInstalled(item) {
            if (item.entry) {
                showDetail(item.kind, item.entry);
            } else {
                showInstalledDetail(item.app);
            }
        }

        /**
         * Shows the current tab's apps or recipes, as searched and filtered, with their badges.
         *
         * @return {void}
         */
        function showList() {
            let catalogue = state.catalogue;

            if (!catalogue || !isListTab(state.tab)) {
                return;
            }

            let installedTab  = state.tab === 'installed';
            let items         = installedTab ? installedItems() : catalogue[state.tab];
            let search        = part('search').value.trim().toLowerCase();
            let category      = part('category').value;
            let installedOnly = part('installed-only').checked;
            let several       = catalogue.repos.filter(function (repo) {
                                    return repo.name;
                                }).length > 1;
            let grid          = part('grid');

            grid.textContent = '';

            let shown = items.filter(function (item) {
                return (!search || (item.name + ' ' + item.summary + ' ' + item.id).toLowerCase().indexOf(search) !== -1)
                    && (!category || item.categories.indexOf(category) !== -1)
                    && (installedTab || !installedOnly || item.installed);
            });

            shown.forEach(function (item) {
                let badges = element('div', { className: 'st-badges' });

                if (installedTab) {
                    badges.appendChild(element('span', { className: 'st-badge', textContent: item.version }));

                    if (item.recipe) {
                        badges.appendChild(element('span', { className: 'st-badge', textContent: 'Recipe' }));
                    }

                    if (!item.enabled) {
                        badges.appendChild(element('span', { className: 'st-badge st-off', textContent: 'Off' }));
                    }

                    if (item.update) {
                        badges.appendChild(element('span', { className: 'st-badge st-update', textContent: 'Update: ' + item.entry.version }));
                    }
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

                if (item.publisher || (item.entry && item.entry.publisher)) {
                    badges.appendChild(element('span', { className: 'st-badge', textContent: 'By ' + (item.publisher || item.entry.publisher) }));
                }

                let card = element('div', { className: 'st-card', tabIndex: 0 }, [
                    itemIcon(item),
                    element('div', { className: 'st-card-text' }, [element('strong', { textContent: item.name }), element('div', { className: 'st-summary', textContent: item.summary }), badges])
                ]);

                card.setAttribute('role', 'button');

                let open = function () {
                    if (installedTab) {
                        openInstalled(item);
                    } else {
                        showDetail(state.tab, item);
                    }
                };

                card.addEventListener('click', open);
                card.addEventListener('keydown', function (event) {
                    if (event.key === 'Enter' || event.key === ' ') {
                        event.preventDefault();

                        open();
                    }
                });

                grid.appendChild(card);
            });

            let note = '';

            let anyRepoRead = catalogue.repos.some(function (repo) {
                return repo.name;
            });

            if (!installedTab && !anyRepoRead) {
                note = 'No repository could be read yet - see Repositories.';
            } else if (!shown.length) {
                note = 'Nothing matches.';
            }

            part('list-note').textContent = note;
        }

        // ------------------------------------------------------------------------------------------------------------
        // An app's or recipe's page

        /**
         * Opens an app's or recipe's page, loading its details.
         *
         * @param {string} kind apps or recipes
         * @param {Object} item The app or recipe in the catalogue
         *
         * @return {void}
         */
        function showDetail(kind, item) {
            state.detail = { kind: kind, item: item };
            state.status = null;

            part('list').hidden = true;

            let view = part('detail');

            view.hidden      = false;
            view.textContent = '';

            view.appendChild(detailHead(item, null));
            view.appendChild(element('p', { textContent: 'Loading…' }));

            call('details', null, '&kind=' + kind + '&repo=' + encodeURIComponent(item.repo) + '&id=' + encodeURIComponent(item.id)).then(function (response) {
                if (!state.detail || state.detail.item !== item) {
                    return;
                }

                view.textContent = '';

                if (!response.ok) {
                    view.appendChild(detailHead(item, null));
                    view.appendChild(element('p', { className: 'mg-bad', textContent: response.error }));

                    return;
                }

                renderDetail(view, kind, item, response);
            });
        }

        /**
         * A link that opens in a new tab.
         *
         * @param {string} url  The address
         * @param {string} text The link's text
         *
         * @return {HTMLElement} The link
         */
        function externalLink(url, text) {
            return element('a', { href: url, textContent: text, target: '_blank', rel: 'noopener noreferrer' });
        }

        /**
         * The head of an app's or recipe's page: its icon, name and version, with Back on the right.
         *
         * @param {Object}      item    The app or recipe
         * @param {Object|null} details Its details, once loaded
         *
         * @return {HTMLElement} The head
         */
        function detailHead(item, details) {
            let meta = details ? [details.version, details.license, details.repo_name ? 'from ' + details.repo_name : ''].filter(Boolean).join(' · ') : item.version;
            let back = element('button', { type: 'button', className: 'st-back', textContent: '← Back' });

            back.addEventListener('click', function () {
                showTab(state.tab);
            });

            return element('div', { className: 'st-detail-head' }, [
                itemIcon(item),
                element('div', { className: 'st-detail-title' }, [element('h3', { textContent: details ? details.name : item.name }), element('span', { className: 'mg-note', textContent: meta })]),
                back
            ]);
        }

        /**
         * Draws an app's or recipe's page: its head; one row of actions (Open, install / update / settings / remove)
         * and links; the result of its latest job; the form an action opened (if any); notices; then its description.
         *
         * @param {HTMLElement} view    Where the page goes
         * @param {string}      kind    apps or recipes
         * @param {Object}      item    The app or recipe in the catalogue
         * @param {Object}      details Its details
         *
         * @return {void}
         */
        function renderDetail(view, kind, item, details) {
            view.appendChild(detailHead(item, details));

            let page = {
                bar:     element('div', { className: 'st-actions' }),
                status:  element('div', { className: 'st-status' }),
                message: element('p'),
                panel:   element('div'),
                notes:   element('div'),
                blocked: details.problems.some(function (problem) {
                    return problem.level === 'error';
                })
            };

            page.status.hidden = true;

            let inst = kind === 'apps' && item.installed ? installedApp(item.id) : null;

            if (inst) {
                configureButton(page, inst, details.url);
            }

            if (details.url) {
                addButton(page, 'Open', function () {
                    window.open(details.url, '_blank', 'noopener');
                }, false, inst && inst.center_type === 1 && inst.url ? '' : 'st-primary');
            }

            if (kind === 'apps') {
                renderAppActions(page, item, details);
            } else {
                renderRecipeActions(page, item, details);
            }

            let links = element('span', { className: 'st-links' }, []);

            [['homepage', 'Homepage'], ['release_notes', 'Release notes'], ['sources', 'Sources']].forEach(function (linkItem) {
                if (details[linkItem[0]]) {
                    links.appendChild(externalLink(details[linkItem[0]], linkItem[1]));
                }
            });

            if (links.childNodes.length) {
                page.bar.appendChild(links);
            }

            [page.bar, page.status, page.message, page.panel, page.notes].forEach(function (e) {
                view.appendChild(e);
            });

            showFlash(page);

            state.status = { el: page.status, kind: kind, id: item.id };

            showStatus();

            if (details.publisher) {
                view.appendChild(element('p', { className: 'st-notice', textContent: 'Made by ' + details.publisher + ', not by ' + (details.repo_name || 'this repository') + ': its package comes from ' + details.publisher + ' itself, checked against the checksum ' + (details.repo_name || 'the repository') + ' lists.' }, []));
            }

            if (details.orphan) {
                view.appendChild(element('p', { className: 'st-notice', textContent: 'Installed from ' + details.orphan + ', which the Store no longer reads: its settings can still be changed and it can be removed, but it won\'t get updates until that repository is added again.' }, []));
            }

            if (details.third_party) {
                view.appendChild(element('p', { className: 'st-notice', textContent: 'From a third-party repository (' + details.repo_name + '): it runs as root on the NAS.' }, []));
            }

            if (details.problems.length) {
                let list = element('ul', { className: 'st-problems' }, []);

                details.problems.forEach(function (problem) {
                    list.appendChild(element('li', { className: 'st-' + problem.level, textContent: problem.message }, []));
                });

                view.appendChild(list);
            }

            let description = element('div', { className: 'st-description' }, []);

            // Made by the server from Markdown, with everything escaped and only https links
            description.innerHTML = details.description;

            view.appendChild(description);
        }

        /**
         * Adds a button to a page's row of actions.
         *
         * @param {Object}   page      The page's parts
         * @param {string}   text      The button's text
         * @param {Function} onClick   What it does
         * @param {boolean}  disabled  Whether it's disabled
         * @param {string}   className Its class names
         *
         * @return {HTMLElement} The button
         */
        function addButton(page, text, onClick, disabled, className) {
            let button = element('button', { type: 'button', textContent: text, disabled: !!disabled, className: className || '' }, []);

            button.addEventListener('click', onClick);

            page.bar.appendChild(button);

            return button;
        }

        /**
         * Opens a form under a page's row of actions, or closes it if it's open (the same button closes it again).
         *
         * @param {Object}   page  The page's parts
         * @param {string}   name  The form's name
         * @param {Function} build Fills in the form
         *
         * @return {void}
         */
        function togglePanel(page, name, build) {
            let open = page.panel.dataset.open === name;

            page.panel.textContent  = '';
            page.panel.dataset.open = open ? '' : name;

            [].forEach.call(page.bar.querySelectorAll('button'), function (button) {
                button.classList.toggle('st-on', !open && button.dataset.panel === name);
            });

            if (!open) {
                let form = element('div', { className: 'st-form' }, []);

                build(form);

                page.panel.appendChild(form);
            }
        }

        /**
         * Adds a button that opens and closes a form (see togglePanel()).
         *
         * @param {Object}   page     The page's parts
         * @param {string}   text     The button's text
         * @param {string}   name     The form's name
         * @param {Function} build    Fills in the form
         * @param {boolean}  disabled Whether it's disabled
         *
         * @return {HTMLElement} The button
         */
        function panelButton(page, text, name, build, disabled) {
            let button = addButton(page, text, function () {
                togglePanel(page, name, build);
            }, disabled);

            button.dataset.panel = name;

            return button;
        }

        /**
         * Starts a background job (an installation, update, change or removal) and follows it. On the dashboard reached
         * through the Nginx app, updating or removing Nginx asks first: the page loses its connection while it runs.
         *
         * @param {Object}      data     The job: job, repo, id and its other fields
         * @param {HTMLElement} message  Where to say how it went
         * @param {Function}    onFields Shows the settings refused, by key
         *
         * @return {Promise.<boolean>|undefined} Whether it started (undefined if it wasn't confirmed)
         */
        function startJob(data, message, onFields) {
            // The dashboard reached through the Nginx app - by a name, not the NAS's address: updating or removing
            // Nginx stops it for a while, and this page loses its connection. The job carries on by itself
            let ip = window.IP_ADDRESS || (state.catalogue && state.catalogue.nas.ip);

            if (data.id === 'nginx' && (data.job === 'app_update' || data.job === 'app_uninstall') && ip && window.location.hostname !== ip
                && !window.confirm('You\'re using the dashboard through Nginx, which this ' + (data.job === 'app_update' ? 'update stops for a minute or two' : 'removes')
                    + ' - so this page will lose its connection (the ' + (data.job === 'app_update' ? 'update' : 'removal') + ' carries on by itself).\n\nBetter: log out here, log in at http://' + ip
                    + '/ and start it from there (the NAS allows one login at a time).\n\nGo ahead here anyway?')) {
                return;
            }

            message.textContent = 'Starting…';
            message.className   = '';

            // An app should be running after it's installed, and after an update if it was before: some apps'
            // installers leave them switched off - e.g. Plex's. Kept for the session, in case the page reloads
            if (data.job === 'app_install' || data.job === 'app_update') {
                let before = installedApp(data.id);

                remember('running', { id: data.id, on: data.job === 'app_install' || !!(before && before.enabled) });
            }

            return call('start', data).then(function (response) {
                if (!response.ok) {
                    if (response.fields && onFields) {
                        onFields(response.fields);
                    }

                    message.textContent = response.error;
                    message.className   = 'mg-bad';

                    return false;
                }

                message.textContent = '';

                showJob(response);
                pollJob();

                return true;
            });
        }

        /**
         * Adds an app's actions to its page: Install; or its Running switch, Update (or Switch to this repository, for
         * one installed from another), and Remove - with what to know about it.
         *
         * @param {Object} page    The page's parts
         * @param {Object} item    The app in the catalogue
         * @param {Object} details Its details
         *
         * @return {void}
         */
        function renderAppActions(page, item, details) {
            if (details.replaces.length) {
                page.notes.appendChild(element('p', { className: 'st-notice', textContent: 'It replaces the NAS\'s own ' + details.replaces.join(', ') + ' while it\'s installed and on.' }, []));
            }

            let facts = [];

            if (details.size) {
                facts.push('Download: ' + (details.size < 1048576 ? Math.ceil(details.size / 1024) + 'KB' : formatMegabytes(Math.ceil(details.size / 1048576))));
            }

            if (details.data_folder) {
                facts.push('Its data is kept in Nas_Prog/' + details.data_folder + (details.keeps_data ? ' (kept across updates and removal)' : ''));
            }

            if (item.update && !item.can_update) {
                facts.push(item.version + ' is available - this app can\'t be updated by the Store without losing its settings, so update it by hand');
            }

            if (facts.length) {
                page.notes.appendChild(element('p', { className: 'mg-note', textContent: facts.join('. ') + '.' }, []));
            }

            if (!item.installed) {
                addButton(page, 'Install', function () {
                    startJob({ job: 'app_install', repo: item.repo, id: item.id }, page.message);
                }, page.blocked || !item.supported, 'st-primary');

                return;
            }

            let inst = installedApp(item.id);

            if (inst) {
                runSwitch(page, inst);
            }

            if (!item.from_here) {
                // Installed from another repository - e.g. the original of a fork: it can be switched to this one's
                page.notes.insertBefore(element('p', { className: 'st-notice', textContent: 'Installed from ' + item.source_name + '. Its updates come from there'
                    + (item.can_update ? ' - or switch it to this repository\'s ' + item.version + ' (its data is kept, and its updates come from here from then on).' : '.') }), page.notes.firstChild);

                if (item.can_update && item.supported) {
                    addButton(page, 'Switch to this repository', function () {
                        if (window.confirm('Replace ' + details.name + ' from ' + item.source_name + ' with ' + details.repo_name + '\'s ' + item.version + '?\n\nIts data in Nas_Prog/' + details.data_folder + ' is kept, and its updates come from ' + details.repo_name + ' from then on.')) {
                            startJob({ job: 'app_update', repo: item.repo, id: item.id }, page.message);
                        }
                    }, page.blocked);
                }

                return;
            }

            if (item.can_update && inst) {
                autoSwitch(page, 'apps', item.id, details.name);
            }

            if (item.update && item.can_update) {
                addButton(page, 'Update to ' + item.version, function () {
                    startJob({ job: 'app_update', repo: item.repo, id: item.id }, page.message);
                }, page.blocked, 'st-primary');
            }

            if (item.source !== null) {
                // Installed from here, but another repository has a newer version: its page there can switch to it
                let newer = state.catalogue.apps.filter(function (a) {
                    return a.id === item.id && a.repo !== item.repo && versionCompare(a.version, item.installed) > 0;
                });

                if (newer.length) {
                    let also = element('p', { className: 'mg-note' }, ['Also offered by: ']);

                    newer.forEach(function (a, i) {
                        let open = element('a', { href: '#', textContent: a.repo_name + ' (' + a.version + ')' });

                        open.addEventListener('click', function (event) {
                            event.preventDefault();

                            showDetail('apps', a);
                        });

                        if (i) {
                            also.appendChild(document.createTextNode(', '));
                        }

                        also.appendChild(open);
                    });

                    also.appendChild(document.createTextNode(' - its page there can switch ' + details.name + ' to it' + (item.can_update ? ' (its data is kept).' : '.')));
                    page.notes.appendChild(also);
                }
            }

            if (item.source === null) {
                // Installed by hand: other repositories with a newer version - updating from one makes it its source
                let others = state.catalogue.apps.filter(function (a) {
                    return a.id === item.id && a.repo !== item.repo && a.update;
                });

                if (others.length) {
                    let also = element('p', { className: 'mg-note' }, ['Installed by hand, so any repository can update it - the update sets where its updates come from. Also offered by: ']);

                    others.forEach(function (a, i) {
                        let open = element('a', { href: '#', textContent: a.repo_name + ' (' + a.version + ')' });

                        open.addEventListener('click', function (event) {
                            event.preventDefault();

                            showDetail('apps', a);
                        });

                        if (i) {
                            also.appendChild(document.createTextNode(', '));
                        }

                        also.appendChild(open);
                    });

                    page.notes.appendChild(also);
                }
            }

            if (item.id === 'store') {
                storeRemoveButton(page);
            } else {
                addButton(page, 'Remove', function () {
                    if (window.confirm('Remove ' + details.name + '?' + (details.data_folder ? ' Its data in Nas_Prog/' + details.data_folder + ' is kept.' : ''))) {
                        startJob({ job: 'app_uninstall', repo: item.repo, id: item.id }, page.message);
                    }
                });
            }
        }

        /**
         * Adds an installed app's Configure button: its own page inside the dashboard (CenterType 1). Other apps'
         * "configuration" address is their web interface (e.g. Plex's): it's the Open button - from WD's details when
         * the repository gives no address.
         *
         * @param {Object} page    The page's parts
         * @param {Object} inst    The installed app
         * @param {string} openUrl The page's Open address, if it has one
         *
         * @return {void}
         */
        function configureButton(page, inst, openUrl) {
            if (!inst.url || inst.id === 'store' || (inst.center_type !== 1 && openUrl)) {
                return;
            }

            addButton(page, inst.center_type === 1 ? 'Configure' : 'Open', function () {
                if (inst.center_type === 1) {
                    remember('return', { kind: state.detail.kind, id: inst.id, tab: state.tab });

                    if (appsPage) {
                        appsPage.configure(inst.id, inst.url, inst.name);
                    } else if (window.go_sub_page) {
                        window.go_sub_page('/apps/' + inst.id + '/' + inst.url, inst.id);
                    }

                    return;
                }

                let port = inst.url_port && inst.url_port !== '80' ? ':' + inst.url_port : '';

                window.open('http://' + (window.IP_ADDRESS || state.catalogue.nas.ip) + port + '/' + inst.id + '/' + inst.url, '_blank', 'noopener');
            }, !inst.enabled, 'st-primary');
        }

        // Running: the NAS's own on / off switch for an app, through its own handler (which checks what apps depend on)
        let refusals = {
            13: 'it needs an app that isn\'t installed or running',
            19: 'it conflicts with an app that\'s running',
            15: 'an app that\'s running needs it'
        };

        /**
         * Switches an app on or off with the NAS's own handler, which checks what apps depend on.
         *
         * @param {string}   id   The app's id
         * @param {boolean}  on   Whether to switch it on
         * @param {Function} done Called with '' or why it was refused
         *
         * @return {void}
         */
        function setRunning(id, on, done) {
            let $ = window.jQuery;

            $.ajax({
                url: '/cgi-bin/apkg_mgr.cgi',
                type: 'POST',
                cache: false,
                dataType: 'xml',
                data: { cmd: 'cgi_apps_set', f_module_name: id, f_enable: on ? 1 : 0 }
            }).done(function (xml) {
                let result = parseInt($(xml).find('result').text(), 10);

                done(refusals[result] || '');
            }).fail(function () {
                done('the NAS didn\'t answer - try again');
            });
        }

        /**
         * Adds an installed app's Running switch to its page (the NAS's own on / off switch).
         *
         * @param {Object} page The page's parts
         * @param {Object} inst The installed app
         *
         * @return {void}
         */
        function runSwitch(page, inst) {
            if (!window.jQuery) {
                return;
            }

            let box = element('input', { type: 'checkbox', checked: inst.enabled });

            page.bar.appendChild(element('label', { className: 'st-switch' }, [box, 'Running']));

            box.addEventListener('change', function () {
                let on = box.checked;

                if (!on && inst.id === 'store' && !window.confirm('Turn the Store off? The NAS\'s own Apps page comes back.')) {
                    box.checked = true;

                    return;
                }

                box.disabled             = true;
                page.message.textContent = (on ? 'Starting ' : 'Stopping ') + inst.name + '…';
                page.message.className   = '';

                setRunning(inst.id, on, function (error) {
                    box.disabled = false;

                    if (error) {
                        box.checked              = !on;
                        page.message.textContent = inst.name + ' can\'t be ' + (on ? 'started' : 'stopped') + ': ' + error + '.';
                        page.message.className   = 'mg-bad';

                        return;
                    }

                    inst.enabled = on;

                    // The page is drawn again with the app's new state: the message goes with it
                    state.flash = inst.name + (on ? ' is running.' : ' is stopped.');

                    loadCatalogue().then(function () {
                        if (state.detail) {
                            reopenDetail();
                        }
                    });
                });
            });
        }

        /**
         * Adds an installed app's or recipe's "Update automatically" switch to its page - and, when it's ticked but
         * tonight's run would leave its new version alone, why.
         *
         * @param {Object} page The page's parts
         * @param {string} kind apps or recipes
         * @param {string} id   Its id
         * @param {string} name Its name
         *
         * @return {void}
         */
        function autoSwitch(page, kind, id, name) {
            let auto    = state.catalogue.auto;
            let box     = element('input', { type: 'checkbox', checked: auto[kind].indexOf(id) !== -1 });
            let planned = auto.plan[kind + ':' + id];

            page.bar.appendChild(element('label', { className: 'st-switch', title: 'Every night at 04:30 (see the Activity tab)' }, [box, 'Update automatically']));

            if (box.checked && planned && planned.state === 'skip' && planned.to) {
                page.notes.appendChild(element('p', { className: 'st-notice', textContent: planned.to + ' won\'t be installed automatically: ' + planned.reason + '.' }));
            }

            box.addEventListener('change', function () {
                let on = box.checked;

                box.disabled = true;

                call('auto_set', { kind: kind, id: id, on: on ? '1' : '0' }).then(function (response) {
                    box.disabled = false;

                    if (!response.ok) {
                        box.checked              = !on;
                        page.message.textContent = response.error;
                        page.message.className   = 'mg-bad';

                        return;
                    }

                    state.catalogue.auto     = response.auto;
                    page.message.textContent = on ? name + ' is updated automatically, every night at 04:30.' : name + ' is no longer updated automatically.';
                    page.message.className   = 'mg-ok';

                    showAuto();
                });
            });
        }

        /**
         * Shows the automatic updates on the Activity tab: what tonight's run would do with each ticked app and recipe,
         * what the last one did, and the ntfy topic (when the ntfy app is installed) - in a box that opens and closes,
         * summed up on its title line. It's as the user left it (this browser session), else open only when an update
         * is left for them.
         *
         * @return {void}
         */
        function showAuto() {
            let auto  = state.catalogue.auto;
            let list  = part('auto-list');
            let keys  = Object.keys(auto.plan);
            let topic = part('auto-topic');

            list.textContent = '';

            keys.forEach(function (key) {
                let item = auto.plan[key];
                let text = {
                    update:  'updated to ' + item.to + ' tonight',
                    current: 'up to date (' + item.from + ')',
                    skip:    (item.to ? item.to + ' left for you: ' : 'not updated: ') + item.reason
                }[item.state];

                list.appendChild(element('li', { className: item.state === 'skip' ? 'mg-bad' : '' }, [element('strong', { textContent: item.name }), ' - ' + text]));
            });

            if (!keys.length) {
                list.appendChild(element('li', { className: 'mg-note', textContent: 'None are ticked yet.' }));
            }

            let done = auto.last.results.filter(function (result) {
                return result.state === 'updated' || result.state === 'failed';
            }).map(function (result) {
                return result.name + (result.state === 'updated' ? ' updated to ' : ' failed to update to ') + result.to;
            });

            part('auto-last').textContent = auto.last.checked ? 'Last run ' + auto.last.checked.replace('T', ' ').slice(0, 16) + ': ' + (done.length ? done.join('; ') : 'nothing needed updating') + '.' : '';

            // Its title line: how many are ticked, what tonight brings, and the last run
            let count = function (state) {
                return keys.filter(function (key) {
                    return auto.plan[key].state === state;
                }).length;
            };
            let tonight = count('update');
            let left    = count('skip');
            let summary = keys.length ? keys.length + ' ticked: ' + (tonight ? tonight + ' to update tonight' : 'all up to date') + (left ? ', ' + left + ' left for you' : '') : 'none ticked';

            if (auto.last.checked) {
                summary += ' - last run ' + auto.last.checked.replace('T', ' ').slice(0, 16);
            }

            part('auto-summary').textContent = '(' + summary + ')';
            part('auto-summary').className   = left ? 'mg-bad' : 'mg-note';

            let open = recall('auto-open');

            part('auto').open = open === null ? left > 0 : open;

            part('auto-ntfy').hidden = !auto.ntfy && !auto.topic;

            if (document.activeElement !== topic) {
                topic.value = auto.topic;
            }
        }

        /**
         * Shows the message kept for a page drawn again (e.g. after switching an app on or off).
         *
         * @param {Object} page The page's parts
         *
         * @return {void}
         */
        function showFlash(page) {
            if (state.flash) {
                page.message.textContent = state.flash;
                page.message.className   = 'mg-ok';

                state.flash = null;
            }
        }

        /**
         * Adds the Store's own Remove button: the NAS's own Apps page comes back, and everything it installed stays.
         *
         * @param {Object} page The page's parts
         *
         * @return {void}
         */
        function storeRemoveButton(page) {
            addButton(page, 'Remove', function () {
                if (window.confirm('Remove the Store?\n\nThe NAS\'s own Apps page comes back. Everything the Store installed stays installed, and its settings (e.g. your repositories) are kept in Nas_Prog/_store for if you install it again.')) {
                    startJob({ job: 'app_uninstall', repo: '', id: 'store' }, page.message);
                }
            });
        }

        /**
         * Once the Store has removed itself, its page has nothing left to call: says so, with the way to the NAS's own
         * page.
         *
         * @return {void}
         */
        function storeGone() {
            root.textContent = '';

            let open = element('button', { type: 'button', className: 'st-primary', textContent: 'Open the NAS\'s Apps page' });

            open.addEventListener('click', function () {
                if (window.go_page) {
                    window.go_page('/web/addons/app.php', 'nav_addons');
                } else {
                    window.location.reload();
                }
            });

            root.appendChild(element('div', { className: 'header_1 st-title' }, [element('span', { textContent: 'Store' })]));
            root.appendChild(element('div', { className: 'hr_0' }, [element('div', { className: 'hr_1' })]));
            root.appendChild(element('p', { textContent: 'The Store has been removed. Everything it installed is still installed, and its settings are kept in Nas_Prog/_store.' }));
            root.appendChild(element('p', {}, [open]));
        }

        /**
         * Whether the current job is the Store removing itself.
         *
         * @return {boolean} Whether it is
         */
        function removingStore() {
            return state.job && state.job.action === 'app_uninstall' && state.job.target === 'store';
        }

        /**
         * Opens the page of an installed app that no repository offers (e.g. one of WD's): what the NAS knows about it.
         *
         * @param {Object} app The installed app
         *
         * @return {void}
         */
        function showInstalledDetail(app) {
            state.detail = { kind: 'installed', item: app };
            state.status = null;

            part('list').hidden = true;

            let view = part('detail');

            view.hidden      = false;
            view.textContent = '';

            view.appendChild(detailHead(app, { name: app.name, version: app.version, license: '', repo_name: '' }));

            let page = { bar: element('div', { className: 'st-actions' }), status: element('div', { className: 'st-status' }), message: element('p') };

            page.status.hidden = true;

            configureButton(page, app);
            runSwitch(page, app);

            if (app.id === 'store') {
                storeRemoveButton(page);
            } else {
                addButton(page, 'Remove', function () {
                    if (window.confirm('Remove ' + app.name + '?')) {
                        startJob({ job: 'app_uninstall', repo: '', id: app.id }, page.message);
                    }
                });
            }

            [page.bar, page.status, page.message].forEach(function (element) {
                view.appendChild(element);
            });

            showFlash(page);

            state.status = { el: page.status, kind: 'apps', id: app.id };

            showStatus();

            let from   = app.repo ? state.catalogue.repos.filter(function (repo) {
                return repo.url === app.repo;
            })[0] : null;
            let origin = app.repo && !from ? 'Installed by the Store from ' + app.repo + ', which it no longer reads: add that repository again for its updates.'
                : 'Not offered by any repository the Store reads.';

            view.appendChild(element('p', { className: 'mg-note', textContent: (app.installed ? 'Installed ' + app.installed + '. ' : '') + origin }));

            if (app.description) {
                view.appendChild(element('p', { textContent: app.description }));
            }
        }

        /**
         * Opens the current page again, from the catalogue as it is now (after a job, or switching an app on or off).
         *
         * @return {void}
         */
        function reopenDetail() {
            let kind = state.detail.kind;
            let item = state.detail.item;

            if (kind === 'installed') {
                let app = installedApp(item.id);

                if (app) {
                    showInstalledDetail(app);
                } else {
                    showTab(state.tab);
                }

                return;
            }

            let current = state.catalogue[kind].filter(function (i) {
                return i.repo === item.repo && i.id === item.id;
            })[0] || (installedItems().filter(function (i) {
                return i.kind === kind && i.repo === item.repo && i.id === item.id;
            })[0] || {}).entry;

            if (current) {
                showDetail(kind, current);
            } else {
                showTab(state.tab);
            }
        }

        // ------------------------------------------------------------------------------------------------------------
        // Recipes: the wizard, settings, update and removal

        /**
         * Adds a recipe's actions to its page: Install (with its wizard); or Update, Settings and Remove - with its
         * folders, as the app sees them.
         *
         * @param {Object} page    The page's parts
         * @param {Object} item    The recipe in the catalogue
         * @param {Object} details Its details
         *
         * @return {void}
         */
        function renderRecipeActions(page, item, details) {
            if (!details.installed) {
                if (!item.from_here && item.source_gone) {
                    // Its repository is no longer read: this one can take it over (its settings and data stay)
                    page.notes.appendChild(element('p', { className: 'st-notice', textContent: 'Installed from ' + (item.source_name || 'another repository')
                        + ', which the Store no longer reads - so it gets no updates. Switch it to this repository: its settings, folders and containers stay as they are, and its updates come from here.' }));

                    addButton(page, 'Switch to this repository', function () {
                        call('recipe_switch', { repo: item.repo, id: item.id }).then(function (response) {
                            if (!response.ok) {
                                page.message.textContent = response.error;
                                page.message.className   = 'mg-bad';

                                return;
                            }

                            state.flash = details.name + ' now comes from ' + item.repo_name + '.';

                            loadCatalogue().then(function () {
                                reopenDetail();
                            });
                        });
                    }, page.blocked, 'st-primary');

                    return;
                }

                if (!item.from_here) {
                    page.notes.appendChild(element('p', { className: 'st-notice', textContent: 'Installed from ' + (item.source_name || 'another repository') + ': its settings, updates and removal are on its page there.' }));

                    return;
                }
                let installButton = panelButton(page, 'Install', 'install', function (form) {
                    form.appendChild(element('h4', { textContent: 'Install' }));

                    if (details.existing) {
                        form.appendChild(element('p', { className: 'st-notice', textContent: 'Settings from an earlier install were found in ' + details.existing + ': they\'re filled in below and reused (e.g. its database password).' }));
                    }

                    let fields = wizard(form, details.wizard);

                    form.appendChild(element('p', { className: 'mg-note', textContent: 'Its settings and data go in ' + details.data_folder + (details.web ? '. With the Nginx app, it gets the site ' + details.web + '.<your domain>' : '') + '.' }));

                    let install = element('button', { type: 'button', className: 'st-primary', textContent: 'Install', disabled: page.blocked });

                    install.addEventListener('click', function () {
                        startJob({ job: 'recipe_install', repo: item.repo, id: item.id, answers: JSON.stringify(fields.values()) }, page.message, fields.errors);
                    });

                    form.appendChild(element('p', {}, [install]));
                }, page.blocked);

                installButton.classList.add('st-primary');

                return;
            }

            page.notes.appendChild(element('p', { className: 'mg-note', textContent: 'Installed ' + details.installed.version + ' - its folder: ' + details.installed.data }));

            autoSwitch(page, 'recipes', item.id, details.name);

            if (details.mounts && details.mounts.length) {
                // What to type in the app's own settings, e.g. Immich's external libraries
                let mounts = element('div', { className: 'st-notice' }, [element('strong', { textContent: 'Your folders, as ' + details.name + ' sees them' })]);
                let table  = element('table', { className: 'st-mounts' });

                details.mounts.forEach(function (mount) {
                    table.appendChild(element('tr', {}, [element('td', { textContent: mount[1] }), element('td', { textContent: '→' }), element('td', {}, [element('code', { textContent: mount[2] })])]));
                });

                mounts.appendChild(table);

                page.notes.appendChild(mounts);
            }

            if (item.update) {
                let update = function (answers) {
                    startJob({ job: 'recipe_update', repo: item.repo, id: item.id, answers: JSON.stringify(answers.values()) }, page.message, answers.errors);
                };

                if (details.update_fields.length) {
                    // An update with new options asks them first
                    panelButton(page, 'Update to ' + item.version, 'update', function (form) {
                        form.appendChild(element('h4', { textContent: 'Update to ' + item.version }));

                        let fields       = wizard(form, details.update_fields);
                        let updateButton = element('button', { type: 'button', className: 'st-primary', textContent: 'Update', disabled: page.blocked });

                        updateButton.addEventListener('click', function () {
                            update(fields);
                        });

                        form.appendChild(element('p', {}, [updateButton]));

                    }, page.blocked).classList.add('st-primary');
                } else {
                    addButton(page, 'Update to ' + item.version, function () {
                        if (window.confirm('Update ' + details.name + ' to ' + item.version + '?')) {
                            update({
                                values: function () {
                                    return {};
                                }
                            });
                        }
                    }, page.blocked, 'st-primary');
                }
            }

            if (details.settings.length) {
                panelButton(page, 'Settings', 'settings', function (form) {
                    form.appendChild(element('h4', { textContent: 'Settings' }));

                    let settings = wizard(form, details.settings);
                    let save     = element('button', { type: 'button', className: 'st-primary', textContent: 'Save and apply' });

                    save.addEventListener('click', function () {
                        startJob({ job: 'recipe_change', repo: item.repo, id: item.id, answers: JSON.stringify(settings.values()) }, page.message, settings.errors);
                    });

                    form.appendChild(element('p', {}, [save]));
                });
            }

            panelButton(page, 'Remove', 'remove', function (form) {
                form.appendChild(element('h4', { textContent: 'Remove' }));

                let boxes = [];

                details.deletable.forEach(function (deletable) {
                    let box = element('input', { type: 'checkbox' });

                    box.dataset.key = deletable.key;

                    boxes.push(box);

                    form.appendChild(element('p', {}, [element('label', {}, [box, ' Also delete ' + deletable.label + ': ' + deletable.folder])]));
                });

                let dataBox = element('input', { type: 'checkbox' });

                form.appendChild(element('p', {}, [element('label', {}, [dataBox, ' Also delete its folder ' + details.installed.data + ' (its settings and data - otherwise installing it again reuses them)'])]));

                if (details.kept.length) {
                    form.appendChild(element('p', { className: 'mg-note', textContent: 'Always kept: ' + details.kept.join(', ') }));
                }

                let remove = element('button', { type: 'button', textContent: 'Remove' });

                remove.addEventListener('click', function () {
                    let deleting = boxes.filter(function (box) {
                        return box.checked;
                    }).map(function (box) {
                        return box.dataset.key;
                    });

                    if (window.confirm('Remove ' + details.name + '?' + (deleting.length || dataBox.checked ? ' The folders ticked are deleted for good.' : ''))) {
                        startJob({ job: 'recipe_uninstall', repo: item.repo, id: item.id, delete: JSON.stringify(deleting), delete_data: dataBox.checked ? '1' : '' }, page.message);
                    }
                });

                form.appendChild(element('p', {}, [remove]));
            });
        }

        /**
         * Where a mounted folder appears in its container, as the server works it out.
         *
         * @param {string} target The option's mount target
         * @param {string} folder The folder on the NAS
         *
         * @return {string} The path in the container
         */
        function mountedAs(target, folder) {
            let volume   = state.catalogue.volume + '/';
            let relative = folder.indexOf(volume) === 0 ? folder.slice(volume.length) : folder.replace(/^\/mnt\//, '');

            return target.replace(/\/$/, '') + '/' + relative;
        }

        /**
         * Builds a recipe's form, for its install, update or settings: a field per option (advanced ones folded away).
         *
         * @param {HTMLElement}    container Where the form goes
         * @param {Array.<Object>} fields    The fields, from the server's wizard
         *
         * @return {Object} { values(): the answers, by key, errors(map): shows the settings refused, by key }
         */
        function wizard(container, fields) {
            let getters    = {};
            let errorParts = {};
            let advanced   = element('details', {}, [element('summary', { textContent: 'Advanced' })]);
            let zones      = (window.Intl && Intl.supportedValuesOf) ? Intl.supportedValuesOf('timeZone') : [];

            fields.forEach(function (field) {
                let box = element('div', { className: 'st-field' });

                box.appendChild(element('label', { textContent: field.label + (field.required ? '' : ' (optional)') }));

                let input;

                if (field.type === 'boolean') {
                    input = element('input', { type: 'checkbox', checked: !!field.value });

                    box.firstChild.textContent = '';
                    box.firstChild.appendChild(input);
                    box.firstChild.appendChild(document.createTextNode(' ' + field.label));

                    getters[field.key] = function () {
                        return input.checked;
                    };
                } else if (field.type === 'choice') {
                    input = element('select');

                    field.choices.forEach(function (choice) {
                        input.appendChild(element('option', { value: choice.value, textContent: choice.label }));
                    });

                    input.value = field.value;

                    getters[field.key] = function () {
                        return input.value;
                    };
                } else if (field.type === 'folder' && field.multiple) {
                    let list = element('div');

                    let addRow = function (value) {
                        let row    = element('div');
                        let text   = element('input', { type: 'text', value: value || '', placeholder: state.catalogue.volume + '/…', spellcheck: false, autocomplete: 'off' });
                        let shown  = element('div', { className: 'mg-note st-mounted' });
                        let update = function () {
                            shown.textContent = text.value.trim() && field.mount ? 'In the app: ' + mountedAs(field.mount.target, text.value.trim().replace(/\/+$/, '')) : '';
                        };

                        text.addEventListener('input', update);

                        update();

                        let remove = element('button', { type: 'button', textContent: 'Remove' });

                        remove.addEventListener('click', function () {
                            row.remove();
                        });

                        row.appendChild(text);
                        row.appendChild(remove);
                        row.appendChild(shown);

                        list.appendChild(row);
                    };

                    (field.value || []).forEach(addRow);

                    let add = element('button', { type: 'button', textContent: 'Add a folder' });

                    add.addEventListener('click', function () {
                        addRow('');
                    });

                    box.appendChild(list);
                    box.appendChild(add);

                    getters[field.key] = function () {
                        return [].map.call(list.querySelectorAll('input'), function (input) {
                            return input.value.trim();
                        }).filter(Boolean);
                    };
                } else {
                    let type = field.type === 'password' ? 'password' : (field.type === 'number' || field.type === 'port' ? 'number' : 'text');

                    input = element('input', { type: type, value: field.value === undefined || field.value === null ? '' : field.value, spellcheck: false, autocomplete: field.type === 'password' ? 'new-password' : 'off' });

                    if (field.saved) {
                        input.placeholder = '(saved - leave empty to keep)';
                    }

                    if (field.min !== undefined) {
                        input.min = field.min;
                    }

                    if (field.max !== undefined) {
                        input.max = field.max;
                    }

                    if (field.type === 'timezone' && zones.length) {
                        let listId   = 'st-zones-' + Math.random().toString(36).slice(2);
                        let datalist = element('datalist', { id: listId });

                        zones.forEach(function (zone) {
                            datalist.appendChild(element('option', { value: zone }));
                        });

                        box.appendChild(datalist);

                        input.setAttribute('list', listId);
                    }

                    if (field.type === 'folder' && !field.value) {
                        input.placeholder = state.catalogue.volume + '/…';
                    }

                    getters[field.key] = function () {
                        return input.value.trim();
                    };
                }

                if (input && field.type !== 'boolean') {
                    box.appendChild(input);
                }

                if (field.help) {
                    box.appendChild(element('div', { className: 'mg-note', textContent: field.help }));
                }

                errorParts[field.key] = element('div', { className: 'st-field-error' });

                box.appendChild(errorParts[field.key]);

                (field.advanced ? advanced : container).appendChild(box);
            });

            if (advanced.children.length > 1) {
                container.appendChild(advanced);
            }

            return {
                /**
                 * The form's answers, clearing the errors shown.
                 *
                 * @return {Object} The answers, by key
                 */
                values: function () {
                    let values = {};

                    Object.keys(getters).forEach(function (key) {
                        values[key] = getters[key]();
                    });

                    Object.keys(errorParts).forEach(function (key) {
                        errorParts[key].textContent = '';
                    });

                    return values;
                },

                /**
                 * Shows the settings refused, opening the Advanced part if one is there.
                 *
                 * @param {Object} map Why each was refused, by key
                 *
                 * @return {void}
                 */
                errors: function (map) {
                    Object.keys(map).forEach(function (key) {
                        if (errorParts[key]) {
                            errorParts[key].textContent = map[key];

                            if (errorParts[key].closest('details')) {
                                errorParts[key].closest('details').open = true;
                            }
                        }
                    });
                }
            };
        }

        // ------------------------------------------------------------------------------------------------------------
        // Repositories

        /**
         * Shows the Repositories tab: each repository's details, with Remove (and Accept the new key, when its key has
         * changed).
         *
         * @return {void}
         */
        function showRepos() {
            let listEl = part('repo-list');

            listEl.textContent = '';

            state.catalogue.repos.forEach(function (repo) {
                let entry = element('div', { className: 'st-repo' });
                let box   = element('div', { className: 'st-repo-info' });

                entry.appendChild(box);

                box.appendChild(element('strong', { textContent: repo.name || repo.url }));

                if (repo.default) {
                    box.appendChild(element('span', { className: 'st-badge', textContent: 'Default' }));
                }

                box.appendChild(element('div', { className: 'mg-note', textContent: repo.url }));

                if (repo.summary) {
                    box.appendChild(element('div', { textContent: repo.summary }));
                }

                let facts = [];

                if (repo.name) {
                    facts.push(repo.apps + ' apps, ' + repo.recipes + ' recipes');
                }

                if (repo.maintainer) {
                    facts.push('by ' + repo.maintainer);
                }

                if (repo.updated) {
                    facts.push('updated ' + repo.updated.slice(0, 10));
                }

                facts.push(repo.signed ? 'signed (key ' + repo.fingerprint + ')' : 'not signed');

                box.appendChild(element('div', { className: 'mg-note', textContent: facts.join(' · ') }));

                if (repo.homepage) {
                    box.appendChild(element('div', {}, [externalLink(repo.homepage, repo.homepage)]));
                }

                if (repo.error) {
                    box.appendChild(element('div', { className: 'mg-bad', textContent: repo.error }));
                }

                let actions = element('div', { className: 'st-repo-actions' });

                if (repo.key_changed) {
                    box.appendChild(element('p', { className: 'st-notice', textContent: 'Its signing key has changed to ' + repo.new_fingerprint + '. Only accept it if its maintainer announced the change - otherwise someone may be impersonating it.' }));

                    let accept = element('button', { type: 'button', textContent: 'Accept the new key' });

                    accept.addEventListener('click', function () {
                        if (!window.confirm('Trust the new key ' + repo.new_fingerprint + '?')) {
                            return;
                        }

                        call('accept_key', { url: repo.url, fingerprint: repo.new_fingerprint }).then(function (response) {
                            if (!response.ok) {
                                say(response.error, false, 'repo-message');

                                return;
                            }

                            loadCatalogue();
                        });
                    });

                    actions.appendChild(accept);
                }

                let remove = element('button', { type: 'button', textContent: 'Remove' });

                remove.addEventListener('click', function () {
                    let from = installedItems().filter(function (installedItem) {
                        return installedItem.recipe ? installedItem.repo === repo.url : installedItem.app.repo === repo.url;
                    }).map(function (installedItem) {
                        return installedItem.name;
                    });

                    if (!window.confirm('Remove the repository ' + (repo.name || repo.url) + '?' + (from.length
                        ? '\n\nInstalled from it: ' + from.join(', ') + '. They stay installed and keep working (their settings can still be changed), but get no updates until it\'s added again.'
                        : ' Nothing installed came from it.'))) {
                        return;
                    }

                    call('remove_repo', { url: repo.url }).then(function (response) {
                        if (!response.ok) {
                            say(response.error, false, 'repo-message');

                            return;
                        }

                        loadCatalogue();
                    });
                });

                actions.appendChild(remove);
                entry.appendChild(actions);
                listEl.appendChild(entry);
            });

            if (!state.catalogue.repos.length) {
                listEl.appendChild(element('p', { className: 'mg-note', textContent: 'No repositories.' }));
            }

            // The default repository, if it was removed: one click adds it back (its signing key remembered again)
            if (!state.catalogue.repos.some(function (repo) { return repo.default; })) {
                let restore = element('button', { type: 'button', textContent: 'Add this project\'s repository back' });

                restore.addEventListener('click', function () {
                    say('Adding…', true, 'repo-message');

                    call('add_repo', { url: state.catalogue.default_repo }).then(function (response) {
                        if (!response.ok) {
                            say(response.error, false, 'repo-message');

                            return;
                        }

                        say('Added ' + response.name + '.', true, 'repo-message');
                        loadCatalogue();
                    });
                });

                listEl.appendChild(element('p', {}, [restore]));
            }
        }

        // ------------------------------------------------------------------------------------------------------------
        // Jobs: the full log is on the Activity tab; an app's or recipe's page shows only how its latest job went

        /**
         * What a job was for.
         *
         * @param {Object} job The job
         *
         * @return {string} apps or recipes
         */
        function jobKind(job) {
            return job.action.indexOf('recipe_') === 0 ? 'recipes' : 'apps';
        }

        /**
         * Shows the current job on the Activity tab, with its log - kept scrolled to the end if it was there.
         *
         * @param {Object} response The API's answer: { job, log }
         *
         * @return {void}
         */
        function showJob(response) {
            let job = response.job;

            state.job = job;

            let tab = root.querySelector('[data-st-tab="activity"]');

            tab.textContent = job && job.state === 'running' ? 'Activity (working…)' : 'Activity';

            part('job').hidden           = !job;
            part('activity-none').hidden = !!job;

            showStatus();

            if (!job) {
                return;
            }

            part('job-title').textContent   = job.title;
            part('job-state').textContent   = { running: 'running…', done: 'done', failed: 'failed' }[job.state] || job.state;
            part('job-state').className     = job.state === 'done' ? 'mg-ok' : (job.state === 'failed' ? 'mg-bad' : '');
            part('job-times').textContent   = 'Started ' + (job.started || '').replace('T', ' ').slice(0, 19) + (job.finished ? ' - finished ' + job.finished.replace('T', ' ').slice(0, 19) : '');
            part('job-message').textContent = job.message || '';

            let log   = part('job-log');
            let atEnd = log.scrollTop + log.clientHeight >= log.scrollHeight - 10;

            log.textContent = response.log;

            if (atEnd) {
                log.scrollTop = log.scrollHeight;
            }

            button('job-close').hidden = job.state === 'running';
        }

        /**
         * Shows how the latest job went on the page of the app or recipe it was for.
         *
         * @return {void}
         */
        function showStatus() {
            let status = state.status;
            let job    = state.job;

            if (!status || !status.el.isConnected) {
                return;
            }

            status.el.textContent = '';
            status.el.hidden      = !(job && job.target === status.id && jobKind(job) === status.kind);

            if (status.el.hidden) {
                return;
            }

            status.el.className = 'st-status st-' + job.state;

            let text    = job.state === 'running' ? job.title + '…' : (job.state === 'done' ? '✓ ' : 'Failed: ') + (job.message || job.title);
            let logLink = element('a', { href: '#', textContent: job.state === 'running' ? 'Follow the log' : 'Show the log' });

            logLink.addEventListener('click', function (event) {
                event.preventDefault();

                showTab('activity');
            });

            status.el.appendChild(element('span', { textContent: text + ' ' }));
            status.el.appendChild(logLink);
        }

        /**
         * Follows the current job until it ends, then loads the catalogue again (and redraws the open page). When the
         * Store removes itself, says it's gone.
         *
         * @return {void}
         */
        function pollJob() {
            if (state.polling) {
                return;
            }

            state.polling = true;

            let tick = function () {
                call('job').then(function (response) {
                    // Its page and API go as the Store removes itself
                    if (!response.ok) {
                        state.polling = false;

                        if (removingStore()) {
                            storeGone();
                        }

                        return;
                    }

                    showJob(response);

                    if (removingStore() && response.job.state === 'done') {
                        state.polling = false;

                        storeGone();

                        return;
                    }

                    if (response.job && response.job.state === 'running') {
                        setTimeout(tick, 1500);

                        return;
                    }

                    state.polling = false;

                    // When an app is being switched back on, that redraws its page - once, with the message
                    loadCatalogue().then(function () {
                        if (!switchBackOn(response.job) && state.detail) {
                            reopenDetail();
                        }
                    });
                });
            };

            tick();
        }

        /**
         * After an app's install or update: switches it on again if its installer left it off and it should be running
         * (some do - e.g. Plex's).
         *
         * @param {Object} job The job that ended
         *
         * @return {boolean} Whether it's doing so
         */
        function switchBackOn(job) {
            let wanted = recall('running');

            if (!wanted || !job || job.target !== wanted.id || (job.action !== 'app_install' && job.action !== 'app_update')) {
                return false;
            }

            remember('running', null);

            let inst = installedApp(wanted.id);

            if (job.state !== 'done' || !wanted.on || !inst || inst.enabled || !window.jQuery) {
                return false;
            }

            setRunning(inst.id, true, function (error) {
                let text = error ? inst.name + '\'s installer left it switched off, and it couldn\'t be started: ' + error + '.'
                    : inst.name + '\'s installer left it switched off - it\'s running again.';

                // On its page, if that's open - redrawn with its new state - else at the top
                if (state.detail && !error) {
                    state.flash = text;
                } else {
                    say(text, !error);
                }

                loadCatalogue().then(function () {
                    if (state.detail) {
                        reopenDetail();
                    }
                });
            });

            return true;
        }

        // ------------------------------------------------------------------------------------------------------------

        [].forEach.call(root.querySelectorAll('[data-st-tab]'), function (tabButton) {
            tabButton.addEventListener('click', function () {
                showTab(tabButton.getAttribute('data-st-tab'));
            });
        });

        part('search').addEventListener('input', showList);
        part('category').addEventListener('change', showList);
        part('installed-only').addEventListener('change', showList);

        /**
         * Reads every repository's catalogue again.
         *
         * @param {string} working What to say meanwhile
         *
         * @return {void}
         */
        function refresh(working) {
            say(working, true);

            button('refresh').disabled = true;

            call('refresh', {}).then(function (response) {
                button('refresh').disabled = false;

                if (!response.ok) {
                    say(response.error, false);

                    return;
                }

                say(response.errors.length ? response.errors.join(' · ') : 'Up to date.', !response.errors.length);
                loadCatalogue();
            });
        }

        button('refresh').addEventListener('click', function () {
            refresh('Refreshing the repositories…');
        });

        // The automatic updates' box stays as the user left it (for this browser session): their click, before it
        // opens or closes
        part('auto').querySelector('summary').addEventListener('click', function () {
            remember('auto-open', !part('auto').open);
        });

        button('auto-topic').addEventListener('click', function () {
            say('Saving…', true, 'auto-message');

            call('auto_topic', { topic: part('auto-topic').value.trim() }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false, 'auto-message');

                    return;
                }

                state.catalogue.auto = response.auto;

                say(response.auto.topic ? 'Saved - the automatic updates are told to "' + response.auto.topic + '".' : 'Saved - ntfy isn\'t told.', true, 'auto-message');
                showAuto();
            });
        });

        button('repo-add').addEventListener('click', function () {
            let url = part('repo-url').value.trim();

            say('Adding…', true, 'repo-message');

            call('add_repo', { url: url, confirm: part('repo-confirm').checked ? '1' : '' }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false, 'repo-message');

                    return;
                }

                say('Added ' + response.name + (response.fingerprint ? ' - its signing key (' + response.fingerprint + ') is now required for its updates' : ' (not signed)') + '.', true, 'repo-message');

                part('repo-url').value = '';
                part('repo-confirm').checked = false;

                loadCatalogue();
            });
        });

        button('job-close').addEventListener('click', function () {
            call('clear_job', {}).then(function () {
                showJob({ job: null, log: '' });
            });
        });

        if (appsPage) {
            root.querySelector('[data-st-tab="wd"]').hidden = false;
            root.querySelector('[data-st-tab="manual"]').hidden = !appsPage.wdManual;
        }

        let back = recall('return');

        remember('return', null);
        showTab(back ? back.tab : (recall('tab') || 'installed'));

        loadCatalogue().then(function () {
            // After an app's Configure page, or asked for by the Nginx app's start page (a recipe's Configure link)
            if (back && state.catalogue) {
                let kind = back.kind === 'recipes' ? 'recipes' : 'apps';
                let item = installedItems().filter(function (installedItem) {
                    return installedItem.id === back.id && installedItem.kind === kind;
                })[0];

                if (item) {
                    openInstalled(item);
                }
            }

            // A repository not checked in the last hour - or never: new versions are looked for by themselves
            if (state.catalogue && state.catalogue.stale) {
                refresh('Checking the repositories for new versions…');
            }

            call('job').then(function (response) {
                if (response.ok && response.job) {
                    showJob(response);

                    if (response.job.state === 'running') {
                        pollJob();
                    }
                }
            });
        });
    })();
    </script>
</div>
