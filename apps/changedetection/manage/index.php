<?php
// changedetection.io's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('changedetection');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="changedetection-manage">
    <?php manage_styles('changedetection-manage'); ?>

    <h2>changedetection.io</h2>
    <table>
        <tr><td>Status</td><td data-cd="status">…</td></tr>
        <tr><td>Version</td><td data-cd="version">-</td></tr>
        <tr><td>Address</td><td data-cd="address">-</td></tr>
    </table>
    <p><a class="mg-button" data-cd="link" href="#" target="_blank" rel="noopener">Open changedetection.io</a>
        <button type="button" data-cd-action="restart">Restart changedetection.io</button></p>
    <p data-cd="top-message"></p>
    <p class="mg-note">Add the pages to watch in changedetection.io itself - with what to look at on each (a part of the page,
        a price, whether it's back in stock) and how often.</p>

    <h3>Password</h3>
    <p>changedetection.io asks for this password: <code data-cd="password">••••••••</code>
        <button type="button" data-cd-action="show">Show</button>
        <button type="button" data-cd-action="copy">Copy</button></p>
    <p><input type="password" data-cd="new-password" placeholder="New password (leave empty to generate one)" autocomplete="new-password">
        <button type="button" data-show-for="new-password">Show</button>
        <button type="button" data-cd-action="new-password">New password</button></p>
    <p data-cd="password-message"></p>
    <p class="mg-note">Passwords are 12-128 characters (letters, digits, symbols or spaces). It's set here, not in
        changedetection.io's own settings. changedetection.io restarts.</p>

    <h3>Browser</h3>
    <p>Browser: <span data-cd="browser">-</span></p>
    <p><label><input type="radio" name="cd-browser" value="" data-cd="browser-none"> None: every page fetched with plain
        requests</label><br>
        <label><input type="radio" name="cd-browser" value="local" data-cd="browser-local"> Chrome on this NAS (the
        <em>Chrome Browser</em> recipe)</label><br>
        <label><input type="radio" name="cd-browser" value="other" data-cd="browser-other"> A browser on another machine:</label>
        <input type="text" data-cd="browser-url" placeholder="http://192.168.1.20:9222" autocomplete="off" spellcheck="false">
        <button type="button" data-cd-action="browser">Save</button></p>
    <p data-cd="browser-message"></p>
    <p class="mg-note">With a browser, a watch set to <em>Chrome/Javascript</em> (in its Request tab) loads its page in it, for
        pages built by JavaScript - and browser steps (logging in, clicking) and screenshots work. It's driven through
        Patchright, which hides what usually gives an automated browser away. The recipe (Store → Recipes) needs the Docker app
        and about 1GB of memory; another machine's browser is its Chrome DevTools address (Chrome started with
        --remote-debugging-port). changedetection.io restarts.</p>

    <h3>Alerts and pages</h3>
    <p><label>ntfy topic for alerts: <input type="text" data-cd="ntfy-topic" placeholder="e.g. changes" autocomplete="off"
        spellcheck="false"></label></p>
    <p><label><input type="checkbox" data-cd="local-addresses"> Allow pages on the local network (e.g. a router's or a
        printer's)</label></p>
    <p><button type="button" data-cd-action="settings">Save</button></p>
    <p data-cd="settings-message"></p>
    <p class="mg-note" data-cd="ntfy-note">With a topic, every change is also sent to the ntfy app (alongside the alerts set
        in changedetection.io's own settings, which can go to email, Discord, Telegram and many more). changedetection.io
        refuses local network addresses unless allowed: anyone who can add a watch could otherwise look at devices on your
        network. changedetection.io restarts.</p>

    <h3>Access</h3>
    <p><label><input type="checkbox" data-cd="local"> Only through the Nginx app (HTTPS)</label>
        <button type="button" data-cd-action="listen">Save</button></p>
    <p data-cd="access-message"></p>
    <p class="mg-note">Otherwise changedetection.io is also reachable on port 5000 from the local network, over plain HTTP.
        changedetection.io restarts.</p>

    <details class="mg-section">
        <summary>changedetection.io's latest warnings</summary>
        <pre data-cd="log"></pre>
    </details>

    <p data-cd="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('changedetection', 'cd'); ?>
        <?php manage_secret_script(); ?>

        let loaded     = false;
        let password   = '';
        let siteStates = {
            no_nginx:  'the Nginx app isn\'t set up',
            no_domain: 'set a domain in the Nginx app',
            off:       'switched off in the Nginx app'
        };

        /**
         * Describes the browser in use.
         *
         * @param {Object} browser The API's browser: its address, whether it's the recipe's, and its version ('' if it
         *                         doesn't answer)
         *
         * @return {void}
         */
        function showBrowser(browser) {
            let text = 'none (plain requests only)';

            if (browser.url) {
                text = (browser.local ? 'Chrome on this NAS' : browser.url) + ' - ' +
                    (browser.version ? browser.version : 'not answering');
            }

            part('browser').textContent = text;
            part('browser').className   = browser.url && !browser.version ? 'mg-bad' : '';
        }

        /**
         * Loads the app's status from its API and shows it.
         *
         * @return {Promise} Done once it's shown
         */
        function refresh() {
            return call('status').then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return;
                }

                let status = part('status');

                status.textContent = !response.running ? 'Stopped' : (response.answering ? 'Running' : 'Starting…');
                status.className   = response.running && response.answering ? 'mg-ok' : 'mg-bad';

                part('version').textContent = response.version || '-';

                // Its addresses: the Nginx app's (HTTPS), and port 5000 on the local network unless only through the
                // Nginx app
                let addresses = [];

                if (response.site.url) {
                    addresses.push(response.site.url);
                }

                if (response.listen === 'all') {
                    addresses.push('http://' + window.location.hostname + ':5000/');
                }

                part('address').textContent = (addresses.join(' and ') || 'none - turn off "Only through the Nginx app", or set the Nginx app up') +
                    (response.site.url ? '' : ' (HTTPS: ' + siteStates[response.site.state] + ')');
                part('address').className   = addresses.length ? '' : 'mg-bad';
                part('link').hidden         = !addresses.length;
                part('link').href           = addresses.length ? addresses[0] : '#';

                showBrowser(response.browser);
                part('browser-local').disabled = !response.browser.recipe && !response.browser.local;

                if (!loaded) {
                    let other = response.browser.url !== '' && !response.browser.local;

                    part('local').checked           = response.listen === 'local';
                    part('browser-none').checked    = response.browser.url === '';
                    part('browser-local').checked   = response.browser.local;
                    part('browser-other').checked   = other;
                    part('browser-url').value       = other ? response.browser.url : '';
                    part('ntfy-topic').value        = response.ntfy_topic;
                    part('ntfy-topic').disabled     = !response.ntfy && response.ntfy_topic === '';
                    part('local-addresses').checked = response.local_addresses;

                    loaded = true;
                }

                part('log').textContent = response.log.length ? response.log.join('\n') : 'Nothing logged';
            });
        }

        // Keep the page current, until the dashboard removes it
        <?php manage_timer_script(); ?>
        <?php manage_act_script(); ?>

        button('restart').addEventListener('click', function () {
            act('restart', { confirm: 1 }, 'Restarting changedetection.io…', 'changedetection.io restarted.', 'top-message');
        });

        button('show').addEventListener('click', function () {
            call('show_password', { confirm: 1 }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false, 'password-message');

                    return;
                }

                password = response.password;

                part('password').textContent = password;
            });
        });

        button('copy').addEventListener('click', function () {
            let copy = password ? Promise.resolve({ ok: true, password: password }) : call('show_password', { confirm: 1 });

            copy.then(function (response) {
                if (!response.ok) {
                    say(response.error, false, 'password-message');

                    return;
                }

                password = response.password;

                copyText(password).then(function (copied) {
                    say(copied ? 'Password copied.' : 'Could not copy - Show it and select it instead.', copied, 'password-message');
                });
            });
        });

        button('new-password').addEventListener('click', function () {
            let typed = part('new-password').value.trim();

            act('new_password', { password: typed }, 'Saving…', typed ? 'New password saved.' :
                'New password generated (shown above).', 'password-message').then(function (response) {
                if (response) {
                    password = response.password;

                    part('password').textContent = password;
                    part('new-password').value   = '';
                }
            });
        });

        part('browser-url').addEventListener('focus', function () {
            part('browser-other').checked = true;
        });

        button('browser').addEventListener('click', function () {
            let chosen  = root.querySelector('input[name="cd-browser"]:checked');
            let browser = chosen ? chosen.value : '';

            if (browser === 'other') {
                browser = part('browser-url').value.trim();
            }

            act('browser', { browser: browser }, 'Saving…', 'Browser saved.', 'browser-message');
        });

        button('settings').addEventListener('click', function () {
            act('settings', { ntfy_topic: part('ntfy-topic').value.trim(), local_addresses: part('local-addresses').checked ? 1 : 0 },
                'Saving…', 'Saved.', 'settings-message');
        });

        button('listen').addEventListener('click', function () {
            let local = part('local').checked;

            act('listen', { listen: local ? 'local' : 'all' }, 'Saving…', local ? 'changedetection.io is now only reachable through the Nginx app.' :
                'changedetection.io is reachable on port 5000 too.', 'access-message');
        });

        refresh();
    })();
    </script>
</div>
