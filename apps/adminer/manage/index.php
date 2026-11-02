<?php
// Adminer's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('adminer');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="adminer-manage">
    <?php manage_styles('adminer-manage'); ?>

    <h2>Adminer</h2>
    <table>
        <tr><td>Status</td><td data-ad="status">…</td></tr>
        <tr><td>Version</td><td data-ad="version">-</td></tr>
        <tr><td>Address</td><td data-ad="address">-</td></tr>
    </table>
    <p><a class="mg-button" data-ad="link" href="#" target="_blank" rel="noopener">Open Adminer</a>
        <button type="button" data-ad-action="restart">Restart Adminer</button></p>

    <h3>Logging in</h3>
    <p>Its HTTPS address (the Nginx app's) asks first for the user name <code>admin</code> and the password: <code data-ad="password">••••••••••••</code>
        <button type="button" data-ad-action="show">Show</button> <button type="button" data-ad-action="copy">Copy</button></p>
    <p><input type="text" data-ad="new" placeholder="New password (leave empty to generate one)" autocomplete="off" spellcheck="false">
        <button type="button" data-ad-action="set">Change password</button></p>
    <p class="mg-note">The new password takes effect immediately. Passwords are 12-128 characters: letters, digits and . _ ~ -</p>
    <p><label><input type="checkbox" data-ad="auth"> Ask for this password first (before Adminer's own login)</label>
        <button type="button" data-ad-action="auth">Save</button></p>
    <p class="mg-note">Without it, anyone who reaches its HTTPS address gets Adminer's login form - which can connect to any
        server, not only the NAS's databases (e.g. to probe the local network) - and only the databases' own logins protect
        the data. Keep it on if its address can be reached from the internet.</p>
    <p>Then Adminer asks for a database login:</p>
    <ul>
        <li><strong>MariaDB</strong> (System: MySQL / MariaDB): server <code>127.0.0.1</code>, and a MariaDB user - e.g. phpMyAdmin's
            <code>admin</code> <span data-ad="mariadb"></span></li>
        <li><strong>PostgreSQL</strong>: server <code>127.0.0.1</code>, and a database user - e.g. one made on the PostgreSQL app's
            page (Databases), or <code>postgres</code> <span data-ad="pg"></span></li>
        <li><strong>Valkey</strong> (System: Redis): server <code>127.0.0.1</code>, username <code>default</code>, and the password on
            the Valkey app's page <span data-ad="valkey"></span></li>
    </ul>
    <h3>Access</h3>
    <p><label><input type="checkbox" data-ad="local"> Only through the Nginx app (HTTPS)</label>
        <button type="button" data-ad-action="listen">Save</button></p>
    <p class="mg-note">Otherwise Adminer is also reachable on port 8084 from the local network, over plain HTTP, with only its
        own database login (which limits failed attempts) - the database logins then cross the network unencrypted. Adminer
        restarts.</p>

    <p class="mg-note">Adminer runs on <span data-ad="php">-</span>, as its own user. Imports of up to 512MB go through
        (Import, or SQL command).</p>

    <details class="mg-section">
        <summary>Adminer's latest output (PHP's server logs each request)</summary>
        <pre data-ad="log"></pre>
    </details>

    <p data-ad="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('adminer', 'ad'); ?>

        let loaded     = false;
        let siteStates = {
            no_nginx:  'the Nginx app isn\'t set up',
            no_domain: 'set a domain in the Nginx app',
            off:       'switched off in the Nginx app'
        };

        <?php manage_secret_script(); ?>

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

                // Its addresses: the Nginx app's (HTTPS), and port 8084 on the local network unless only through the
                // Nginx app
                let addresses = [];

                if (response.site.url) {
                    addresses.push(response.site.url);
                }

                if (response.listen === 'all') {
                    addresses.push('http://' + window.location.hostname + ':8084/');
                }

                part('address').textContent = (addresses.join(' and ') || 'none - turn off "Only through the Nginx app", or set the Nginx app up') +
                    (response.site.url ? '' : ' (HTTPS: ' + siteStates[response.site.state] + ')');
                part('address').className   = addresses.length ? '' : 'mg-bad';
                part('link').hidden         = !addresses.length;
                part('link').href           = addresses[0] || '#';

                if (!loaded) {
                    part('local').checked = response.listen === 'local';
                    part('auth').checked  = response.auth;

                    loaded = true;
                }

                part('mariadb').textContent = response.mariadb ? '' : '(the NAS\'s own MariaDB - the MariaDB app updates it)';
                part('pg').textContent      = !response.postgresql ? '(the PostgreSQL app isn\'t installed)' :
                    (response.php === 'nas' ? '(needs the PHP app: the NAS\'s own PHP has no PostgreSQL driver)' : '');
                part('pg').className        = response.postgresql && response.php === 'nas' ? 'mg-bad' : '';
                part('valkey').textContent  = response.valkey ? '' : '(the Valkey app isn\'t installed)';
                part('php').textContent     = response.php === 'app' ? 'the PHP app\'s PHP 8.5 (MariaDB, PostgreSQL, SQLite)' :
                    (response.php === 'nas' ? 'the NAS\'s own PHP 7.4 (MariaDB and SQLite - install the PHP app for PostgreSQL too, then restart Adminer)' : 'no PHP found');
                part('php').className       = response.php ? '' : 'mg-bad';
                part('log').textContent     = response.log.length ? response.log.join('\n') : 'Nothing logged';
            });
        }

        // Keep the page current, until the dashboard removes it
        <?php manage_timer_script(); ?>
        <?php manage_act_script(); ?>

        button('restart').addEventListener('click', function () {
            act('restart', { confirm: 1 }, 'Restarting Adminer…', 'Adminer restarted.');
        });

        button('auth').addEventListener('click', function () {
            let auth = part('auth').checked;

            act('auth', { auth: auth ? 1 : '' }, 'Saving…', auth ? 'Adminer\'s HTTPS address asks for the password first.' :
                'Adminer\'s HTTPS address no longer asks for the password first: only the databases\' own logins.');
        });

        button('listen').addEventListener('click', function () {
            let local = part('local').checked;

            act('listen', { listen: local ? 'local' : 'all' }, 'Saving…', local ? 'Adminer is now only reachable through the Nginx app.' :
                'Adminer is reachable on port 8084 too.');
        });

        // The site's password: Show / Hide and Copy (fetched when first needed)
        let secret = secretControls(part('password'), button('show'), button('copy'), function () {
            return call('password', { show: 1 }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return null;
                }

                return response.password;
            });
        });

        button('set').addEventListener('click', function () {
            act('set_password', { password: part('new').value.trim() }, 'Saving the password…', 'New password in use.').then(function (response) {
                if (response) {
                    secret.set(response.password);

                    part('new').value = '';
                }
            });
        });

        refresh();
    })();
    </script>
</div>
