/**
 * Added by the Nginx app to the NAS dashboard's pages, on the dashboard's own site (see sites_app_conf() in sites.php):
 * opens an app's own page in the dashboard (its Configure page) from the start page's links, which are the dashboard's
 * address with #configure=<id>/<page> - or a recipe's page in the Store, with #recipe=<id>. Those pages only exist inside
 * the dashboard (the NAS refuses them opened on their own), so the request is remembered for this tab - through the
 * dashboard's login, if it asks for one - and once the dashboard is ready, its Apps page is opened, then the app's page:
 * the Store's way (the Store app replaces the Apps page), or the dashboard's own. A recipe's page is the Store's: it's
 * given the page to reopen when it loads, as it keeps one itself after an app's Configure page. A request is forgotten
 * once it's done, or after 10 minutes.
 */
(function () {
    // The dashboard loads pages into itself, and this comes with some of them: only once per page
    if (window.nginxAppDashboard) {
        return;
    }

    window.nginxAppDashboard = true;

    const key    = 'nginx-app-configure';
    const name   = '[A-Za-z0-9_-][A-Za-z0-9._-]*';
    const app    = new RegExp(`^#configure=(${name})/(${name})$`).exec(window.location.hash);
    const recipe = new RegExp(`^#recipe=(${name})$`).exec(window.location.hash);
    let request  = null;

    try {
        if (app || recipe) {
            let wanted = app ? { id: app[1], page: app[2] } : { id: recipe[1], page: '', recipe: true };

            wanted.at = Date.now();
            window.sessionStorage.setItem(key, JSON.stringify(wanted));
            window.history.replaceState(null, '', window.location.pathname + window.location.search);
        }

        request = JSON.parse(window.sessionStorage.getItem(key));
    } catch (exception) {
        return;
    }

    if (!request || typeof request.id !== 'string' || typeof request.page !== 'string' || Date.now() - request.at > 600000) {
        forget();

        return;
    }

    let asked = 0;
    let tries = 0;
    let timer = window.setInterval(step, 500);

    /**
     * Forgets the request (done, or no longer wanted).
     *
     * @return {void}
     */
    function forget() {
        try {
            window.sessionStorage.removeItem(key);
        } catch (exception) { /* (nothing kept) */ }
    }

    /**
     * Stops, forgetting the request.
     *
     * @return {void}
     */
    function done() {
        window.clearInterval(timer);
        forget();
    }

    /**
     * One step, every half second: waits for the dashboard (not its login page - the request is kept for after it),
     * opens its Apps page, then the app's page once the Apps page is ready. Gives up after a minute on this page.
     *
     * @return {void}
     */
    function step() {
        tries++;

        if (tries > 120) {
            window.clearInterval(timer);

            return;
        }

        // The dashboard, logged in: its page loader and its Apps menu item
        if (typeof window.go_page !== 'function' || typeof window.go_sub_page !== 'function' || !document.getElementById('nav_addons')) {
            return;
        }

        if (!asked) {
            asked = tries;

            // A recipe's page: the Store opens it when it loads (as it reopens one after an app's Configure page)
            if (request.recipe) {
                try {
                    window.sessionStorage.setItem('store-return', JSON.stringify({ kind: 'recipes', id: request.id, tab: 'installed' }));
                } catch (exception) { /* (the Store's own page instead) */ }
            }

            window.go_page('/web/addons/app.php', 'nav_addons');

            return;
        }

        // A recipe's page is the Store's: done once the Store shows (or, without it, nothing more to do)
        if (request.recipe) {
            if (document.getElementById('store-manage') || tries - asked >= 20) {
                done();
            }

            return;
        }

        // The Store's Apps page, once it shows the Store (it opens an app's page with a way back to it)
        if (window.storeApps && document.getElementById('store-manage')) {
            done();
            window.storeApps.configure(request.id, request.page, request.id);

            return;
        }

        // The dashboard's own Apps page (no Store app): after a few seconds, the app's page in it
        if (!window.storeApps && tries - asked >= 6) {
            done();
            window.go_sub_page(`/apps/${request.id}/${request.page}`, request.id);
        }
    }
})();
