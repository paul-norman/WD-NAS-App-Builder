// The project's website (built by ci/site.py): the visitor's NAS model - chosen on the home page, remembered, or given
// as ?model= in a link - shows which apps it can run and points each Download at its package. Without this script,
// every page still works: the cards lead to the apps' pages, which list every model's download
(function () {
    'use strict';

    const STORAGE_KEY = 'wd-nas-model';
    const THEME_KEY   = 'wd-nas-theme';
    const models      = {
        MyCloudPR4100:   'My Cloud PR4100',
        MyCloudPR2100:   'My Cloud PR2100',
        WDMyCloudDL4100: 'My Cloud DL4100',
        WDMyCloudDL2100: 'My Cloud DL2100',
        WDMyCloudEX4100: 'My Cloud EX4100',
        WDMyCloudEX2100: 'My Cloud EX2100',
        MyCloudEX2Ultra: 'My Cloud EX2 Ultra',
        WDMyCloudMirror: 'My Cloud Mirror (Gen 2)',
        WDMyCloud:       'My Cloud (Gen 2)',
        WDCloud:         'WD Cloud'
    };

    /**
     * The model remembered on this browser (none if storage isn't available, e.g. in a private window).
     *
     * @return {string} Its id, or ''
     */
    function remembered() {
        try {
            return window.localStorage.getItem(STORAGE_KEY) || '';
        } catch (error) {
            return '';
        }
    }

    /**
     * Remembers the model on this browser, where it can.
     *
     * @param {string} model Its id
     *
     * @return {void}
     */
    function remember(model) {
        try {
            window.localStorage.setItem(STORAGE_KEY, model);
        } catch (error) {
            // Not remembered: it's chosen again next time
        }
    }

    /**
     * The model to show: one given in the address (?model=PR4100 - its id, or its short name), else the remembered one.
     *
     * @return {string} Its id, or ''
     */
    function chosenModel() {
        const given = new URLSearchParams(window.location.search).get('model') || '';
        const found = Object.keys(models).find(function (model) {
            return given !== '' && (model.toLowerCase() === given.toLowerCase() || model.toLowerCase().endsWith(given.toLowerCase()));
        });

        return found || (models[remembered()] ? remembered() : '');
    }

    /**
     * Points an item's Download at its package for the model, or marks the item as not available for it.
     *
     * @param {HTMLElement} item  The card (with data-downloads, or data-models for recipes)
     * @param {string}      model The model's id ('' for none chosen)
     *
     * @return {void}
     */
    function showDownload(item, model) {
        const available = model === '' || (item.dataset.models || '').split(' ').indexOf(model) !== -1;
        const button    = item.querySelector('[data-site="download"]');

        item.classList.toggle('unavailable', !available);

        if (!button || !item.dataset.downloads) {
            return;
        }

        const download = model !== '' ? JSON.parse(item.dataset.downloads)[model] : null;

        if (download) {
            button.href        = download[0];
            button.textContent = `${button.textContent.replace(/ \(.*\)$/, '')} (${download[1]})`;
        }
    }

    /**
     * The home page: the model picker, and the cards following the model, search and category.
     *
     * @return {void}
     */
    function homePage() {
        const picker   = document.querySelector('.models');
        const search   = document.querySelector('[data-site="search"]');
        const category = document.querySelector('[data-site="category"]');
        const note     = document.querySelector('[data-site="picker-note"]');
        const cards    = Array.prototype.slice.call(document.querySelectorAll('.cards .card'));
        const store    = document.querySelector('.store-card');
        let model      = chosenModel();

        /**
         * Shows the cards for the model, search and category.
         *
         * @return {void}
         */
        function update() {
            const words   = search.value.trim().toLowerCase();
            const wanted  = category.value;
            let available = 0;

            Array.prototype.forEach.call(picker.querySelectorAll('.model'), function (button) {
                button.setAttribute('aria-pressed', button.dataset.model === model ? 'true' : 'false');
            });

            picker.classList.toggle('chosen', model !== '');

            if (store) {
                showDownload(store, model);
            }

            cards.forEach(function (card) {
                const matches = (words === '' || `${card.dataset.name} ${card.dataset.summary}`.indexOf(words) !== -1)
                    && (wanted === '' || (card.dataset.categories || '').split(' ').indexOf(wanted) !== -1);

                card.classList.toggle('hidden', !matches);
                showDownload(card, model);

                if (matches && !card.dataset.recipe && !card.classList.contains('unavailable')) {
                    available++;
                }
            });

            document.querySelector('[data-site="app-count"]').textContent = String(available);
            document.querySelector('[data-site="none"]').hidden = cards.some(function (card) {
                return !card.classList.contains('hidden');
            });

            if (model !== '') {
                const arm = picker.querySelector(`[data-model="${model}"]`).classList.contains('model-arm');

                note.hidden      = false;
                note.textContent = `Showing what a ${models[model]} can run` + (arm
                    ? ' - an ARM model: most apps are built for the Intel models only, so the others are greyed out.'
                    : '. Pick another model to change it.');
            }
        }

        Array.prototype.forEach.call(picker.querySelectorAll('.model'), function (button) {
            button.addEventListener('click', function () {
                model = button.dataset.model;
                remember(model);
                update();
                document.getElementById('store').scrollIntoView({ behavior: 'smooth' });
            });
        });

        search.addEventListener('input', update);
        category.addEventListener('change', update);
        update();
    }

    /**
     * An app's page: its download for the model highlighted, with a line saying which it is.
     *
     * @return {void}
     */
    function appPage() {
        const model = chosenModel();
        const line  = document.querySelector('[data-site="your-download"]');
        const copy  = document.querySelector('[data-site="copy-link"]');

        // Its address, to share: copied where the browser allows it
        if (copy && navigator.clipboard) {
            copy.hidden = false;
            copy.addEventListener('click', function () {
                navigator.clipboard.writeText(document.querySelector('[data-site="share-url"]').textContent).then(function () {
                    copy.textContent = 'Copied';
                });
            });
        }

        if (model === '' || !line) {
            return;
        }

        const row = document.querySelector(`.downloads tr[data-model="${model}"]`);

        if (row) {
            row.classList.add('yours');
            line.textContent = `Your NAS: ${models[model]} - its download is highlighted.`;
        } else {
            line.textContent = `There's no download for your NAS (${models[model]}).`;
        }
    }

    /**
     * The light / dark toggle: the theme shown is the visitor's choice (remembered), else the system's. Browsers that hide
     * the system's setting (e.g. LibreWolf) report light, so the toggle is the only way to dark there.
     *
     * @return {void}
     */
    function themeToggle() {
        const button = document.querySelector('[data-site="theme"]');
        const root   = document.documentElement;
        const system = window.matchMedia('(prefers-color-scheme: dark)');

        /**
         * Marks the theme being shown, so the button offers the other one.
         *
         * @return {void}
         */
        function show() {
            const shown = root.dataset.theme || (system.matches ? 'dark' : 'light');
            const label = `Switch to ${shown === 'dark' ? 'light' : 'dark'} mode`;

            root.dataset.themeShown = shown;
            button.setAttribute('aria-label', label);
            button.title = label;
        }

        if (!button) {
            return;
        }

        button.hidden = false;
        button.addEventListener('click', function () {
            root.dataset.theme = root.dataset.themeShown === 'dark' ? 'light' : 'dark';

            try {
                window.localStorage.setItem(THEME_KEY, root.dataset.theme);
            } catch (error) {
                // Not remembered: the system's theme comes back next time
            }

            show();
        });
        system.addEventListener('change', show);
        show();
    }

    themeToggle();

    if (document.querySelector('.models')) {
        homePage();
    } else {
        appPage();
    }
})();
