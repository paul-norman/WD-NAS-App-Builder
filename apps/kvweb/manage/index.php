<?php
// kvweb's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('kvweb');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="kvweb-manage">
    <?php manage_styles('kvweb-manage'); ?>

    <h2>kvweb</h2>
    <table>
        <tr><td>Status</td><td data-kv="status">…</td></tr>
        <tr><td>Version</td><td data-kv="version">-</td></tr>
        <tr><td>Address</td><td data-kv="address">-</td></tr>
        <tr><td>Valkey</td><td data-kv="valkey">-</td></tr>
    </table>
    <p><a class="mg-button" data-kv="link" href="#" target="_blank" rel="noopener">Open kvweb</a>
        <button type="button" data-kv-action="restart">Restart kvweb</button></p>

    <h3>Logging in</h3>
    <p>Its address asks for the user name <code>admin</code> and the password: <code data-kv="password">••••••••••••</code>
        <button type="button" data-kv-action="show">Show</button> <button type="button" data-kv-action="copy">Copy</button></p>
    <p><input type="text" data-kv="new" placeholder="New password (leave empty to generate one)" autocomplete="off" spellcheck="false">
        <button type="button" data-kv-action="set">Change password</button></p>
    <p class="mg-note">The new password takes effect immediately. Passwords are 12-128 characters: letters, digits and . _ ~ -</p>
    <p class="mg-note">kvweb then shows the Valkey app's keys: it logs in to Valkey by itself, with the password on the Valkey
        app's page (changing it there restarts kvweb with the new one).</p>

    <h3>Settings</h3>
    <p><label><input type="checkbox" data-kv="readonly"> Read only (keys can be seen, not changed or deleted)</label>
        <button type="button" data-kv-action="readonly">Save</button></p>
    <p class="mg-note">kvweb restarts. Emptying a whole database (FLUSHDB / FLUSHALL) is always blocked.</p>

    <details class="mg-section">
        <summary>kvweb's latest warnings</summary>
        <pre data-kv="log"></pre>
    </details>

    <p data-kv="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('kvweb', 'kv'); ?>
        <?php manage_secret_script(); ?>

        let loaded     = false;
        let siteStates = {
            no_nginx: 'install the Nginx app - kvweb is only reached through it (HTTPS)',
            no_domain: 'set a domain in the Nginx app',
            off:       'switched off in the Nginx app'
        };

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

                status.textContent = !response.running ? 'Stopped (or waiting for Valkey)' : (response.answering ? 'Running' + (response.readonly ? ' (read only)' : '') : 'Starting…');
                status.className   = response.running && response.answering ? 'mg-ok' : 'mg-bad';

                part('version').textContent = response.version || '-';
                part('address').textContent = response.site.url || 'none yet - ' + siteStates[response.site.state];
                part('address').className   = response.site.url ? '' : 'mg-bad';
                part('link').hidden         = !response.site.url;
                part('link').href           = response.site.url || '#';

                let valkey = part('valkey');

                valkey.textContent = !response.valkey ? 'not installed - kvweb needs the Valkey app' : (!response.answering ? '-' :
                    (response.connected ? 'connected' : 'not answering (kvweb reconnects by itself once it does)'));
                valkey.className   = response.valkey && (!response.answering || response.connected) ? '' : 'mg-bad';

                if (!loaded) {
                    part('readonly').checked = response.readonly;

                    loaded = true;
                }

                part('log').textContent = response.log.length ? response.log.join('\n') : 'Nothing logged';
            });
        }

        // Keep the page current, until the dashboard removes it
        <?php manage_timer_script(); ?>
        <?php manage_act_script(); ?>

        button('restart').addEventListener('click', function () {
            act('restart', { confirm: 1 }, 'Restarting kvweb…', 'kvweb restarted.');
        });

        button('readonly').addEventListener('click', function () {
            let readonly = part('readonly').checked;

            act('readonly', { readonly: readonly ? 1 : '' }, 'Saving…', readonly ? 'kvweb is now read only.' : 'kvweb can change keys again.');
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
