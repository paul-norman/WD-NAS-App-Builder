<?php
// ntfy's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('ntfy');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="ntfy-manage">
    <?php manage_styles('ntfy-manage'); ?>

    <h2>ntfy</h2>
    <table>
        <tr><td>Status</td><td data-nt="status">…</td></tr>
        <tr><td>Version</td><td data-nt="version">-</td></tr>
        <tr><td>Address</td><td data-nt="address">-</td></tr>
    </table>
    <p class="mg-note" data-nt="restart-note" hidden>The Nginx app's address for ntfy has changed: restart ntfy so that it
        uses it (the phone apps' server address must match).</p>
    <p><a class="mg-button" data-nt="link" href="#" target="_blank" rel="noopener">Open ntfy</a>
        <button type="button" data-nt-action="restart">Restart ntfy</button></p>

    <h3>Phones and browsers</h3>
    <p>In the ntfy app (Android, iPhone) or ntfy's own web app: server <code data-nt="server">-</code>, user name
        <code>admin</code>, password <code data-nt="password">••••••••••••</code>
        <button type="button" data-nt-action="show">Show</button> <button type="button" data-nt-action="copy">Copy</button>
        <button type="button" data-nt-action="new-password">New password</button></p>
    <p class="mg-note">Then subscribe to the topics the apps send to (e.g. <code>nas</code>). Nobody can read or send
        notifications without logging in.</p>

    <h3>Sending from apps and scripts</h3>
    <p>Access token: <code data-nt="token">••••••••••••</code>
        <button type="button" data-nt-action="show-token">Show</button> <button type="button" data-nt-action="copy-token">Copy</button>
        <button type="button" data-nt-action="new-token">New token</button></p>
    <pre data-nt="example"></pre>
    <p class="mg-note">Uptime Kuma: Settings → Notifications → ntfy, with this server, a topic and the token. Grafana: a
        contact point of type Webhook to <code data-nt="grafana">-</code> with the header <code>Authorization: Bearer
        &lt;token&gt;</code>. Kopia: a notification profile of type Webhook to the topic's address, with the same header.</p>
    <p><label>Topic <input type="text" data-nt="topic" value="nas" size="16" spellcheck="false"></label>
        <button type="button" data-nt-action="test">Send a test notification</button></p>

    <h3>Settings</h3>
    <p><label><input type="checkbox" data-nt="local"> Only through the Nginx app (HTTPS)</label><br>
        <label><input type="checkbox" data-nt="ios"> Instant notifications on iPhones (through ntfy.sh's push relay)</label>
        <button type="button" data-nt-action="settings">Save</button></p>
    <p class="mg-note">iPhones only get notifications at once through Apple's push service, which ntfy reaches through
        ntfy.sh: it's sent each message's ID, not its contents (the phone then fetches it from the NAS). Android phones
        don't need it. ntfy restarts.</p>

    <details class="mg-section">
        <summary>ntfy's latest warnings</summary>
        <pre data-nt="log"></pre>
    </details>

    <p data-nt="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('ntfy', 'nt'); ?>
        <?php manage_secret_script(); ?>

        let loaded = false;

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

                let base = response.base_url || '-';

                part('address').textContent = base + (response.listen === 'local' ? ' (only through the Nginx app)' : '');
                part('server').textContent  = base;
                part('grafana').textContent = base + '/nas?template=grafana';
                part('link').href           = response.base_url || '#';
                part('restart-note').hidden = !response.restart_needed;
                part('example').textContent = 'curl -H "Authorization: Bearer <token>" -H "Title: Backup" -d "Backup finished" ' + base + '/nas';

                if (!loaded) {
                    part('local').checked = response.listen === 'local';
                    part('ios').checked   = response.ios_push;

                    loaded = true;
                }

                part('log').textContent = response.log.length ? response.log.join('\n') : 'Nothing logged';
            });
        }

        // Keep the page current, until the dashboard removes it
        <?php manage_timer_script(); ?>
        <?php manage_act_script(); ?>

        button('restart').addEventListener('click', function () {
            act('restart', { confirm: 1 }, 'Restarting ntfy…', 'ntfy restarted.');
        });

        // The admin password and the apps' token: Show / Hide and Copy (fetched when first needed)
        let password = secretControls(part('password'), button('show'), button('copy'), function () {
            return call('password', { show: 1 }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return null;
                }

                return response.password;
            });
        });

        let token = secretControls(part('token'), button('show-token'), button('copy-token'), function () {
            return call('token', { show: 1 }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return null;
                }

                return response.token;
            });
        });

        button('new-password').addEventListener('click', function () {
            if (!window.confirm('Make a new admin password? The phone apps need it to log in again, and ntfy restarts.')) {
                return;
            }

            act('new_password', { confirm: 1 }, 'Making a new password…', 'New password in use.').then(function (response) {
                if (response) {
                    password.set(response.password);
                }
            });
        });

        button('new-token').addEventListener('click', function () {
            if (!window.confirm('Make a new token? Apps and scripts using the current one stop being able to send, and ntfy restarts.')) {
                return;
            }

            act('new_token', { confirm: 1 }, 'Making a new token…', 'New token in use - update the apps that send notifications.').then(function (response) {
                if (response) {
                    token.set(response.token);
                }
            });
        });

        button('test').addEventListener('click', function () {
            act('test', { topic: part('topic').value }, 'Sending…', 'Sent - it shows up on devices subscribed to "' + part('topic').value + '".');
        });

        button('settings').addEventListener('click', function () {
            act('settings', { listen: part('local').checked ? 'local' : 'all', ios_push: part('ios').checked ? 1 : 0 }, 'Saving…', 'Saved - ntfy restarted.');
        });

        refresh();
    })();
    </script>
</div>
