<?php
// Radicale's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('radicale');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="radicale-manage">
    <?php manage_styles('radicale-manage'); ?>

    <h2>Radicale</h2>
    <table>
        <tr><td>Status</td><td data-rd="status">…</td></tr>
        <tr><td>Version</td><td data-rd="version">-</td></tr>
        <tr><td>Address</td><td data-rd="address">-</td></tr>
    </table>
    <p><a class="mg-button" data-rd="link" href="#" target="_blank" rel="noopener">Open Radicale</a>
        <button type="button" data-rd-action="restart">Restart Radicale</button></p>
    <p data-rd="top-message"></p>
    <p class="mg-note">Radicale's own web page (log in as one of the users below) creates more calendars and address books,
        and imports or exports them (.ics and .vcf files).</p>

    <h3>Users</h3>
    <p class="mg-note">Each user has their own calendar and contacts, plus the Family calendar and Family contacts, which every
        user sees and can change. Nobody sees another user's own calendars.</p>
    <table data-rd="users"></table>
    <p data-rd="renew-box" hidden>New password for <strong data-rd="renew-name"></strong>:
        <input type="password" data-rd="renew-password" placeholder="Leave empty to generate one" autocomplete="new-password">
        <button type="button" data-show-for="renew-password">Show</button>
        <button type="button" data-rd-action="renew-save">Save</button>
        <button type="button" data-rd-action="renew-cancel">Cancel</button></p>
    <p><input type="text" data-rd="name" placeholder="New user's name (e.g. alex)" autocomplete="off" spellcheck="false">
        <input type="password" data-rd="password" placeholder="Password (leave empty to generate one)" autocomplete="new-password">
        <button type="button" data-show-for="password">Show</button>
        <button type="button" data-rd-action="add">Add user</button></p>
    <p data-rd="users-message"></p>
    <p class="mg-note">Names are lower-case letters, digits and . _ - ; passwords are 12-128 characters (letters, digits,
        symbols or spaces). A password is shown once, when it's set - "New password" makes another. Removing a user keeps their
        calendars and contacts (adding them again with the same name gets them back). Radicale remembers a login for 15
        seconds, so a removed user or an old password still works that long.</p>
    <p data-rd="shown" hidden>Password for <strong data-rd="shown-name"></strong>: <code data-rd="shown-password"></code>
        <button type="button" data-rd-action="copy">Copy</button></p>

    <h3>On an iPhone or iPad</h3>
    <p>Settings → Apps → Calendar → Calendar Accounts → Add Account → Other → Add CalDAV Account, with the server
        <code data-rd="server">-</code>, the user's name and password. Then the same for contacts (Settings → Apps →
        Contacts → Contacts Accounts → Add Account → Other → Add CardDAV Account).</p>
    <p class="mg-note">Android: DAVx⁵ (from the Play Store or F-Droid), with the address <code data-rd="address-dav">-</code>.
        Thunderbird finds the calendars and address books from the same address and the user's name.</p>

    <h3>Access</h3>
    <p><label><input type="checkbox" data-rd="local"> Only through the Nginx app (HTTPS)</label>
        <button type="button" data-rd-action="listen">Save</button></p>
    <p data-rd="access-message"></p>
    <p class="mg-note">Otherwise Radicale is also reachable on port 5232 from the local network, over plain HTTP (passwords
        then cross the network unencrypted - and iPhones warn about it). Radicale restarts.</p>

    <details class="mg-section">
        <summary>Radicale's latest warnings</summary>
        <pre data-rd="log"></pre>
    </details>

    <p data-rd="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('radicale', 'rd'); ?>
        <?php manage_secret_script(); ?>

        let loaded     = false;
        let shown      = '';
        let renewing   = '';
        let siteStates = {
            no_nginx:  'the Nginx app isn\'t set up',
            no_domain: 'set a domain in the Nginx app',
            off:       'switched off in the Nginx app'
        };

        /**
         * Shows a password just set, once (it isn't kept).
         *
         * @param {Object} response The API's answer: the user's name and password
         * @param {string} typed    The password typed ('' when generated): one typed isn't shown again
         *
         * @return {void}
         */
        function showPassword(response, typed) {
            if (typed) {
                part('shown').hidden = true;

                return;
            }

            shown = response.password;

            part('shown-name').textContent     = response.name;
            part('shown-password').textContent = response.password;
            part('shown').hidden               = false;
        }

        /**
         * Lists the users, each with New password and Remove buttons.
         *
         * @param {string[]} users Their names
         *
         * @return {void}
         */
        function showUsers(users) {
            let table = part('users');

            table.textContent = '';

            if (!users.length) {
                let row = table.insertRow();

                row.insertCell().textContent = 'No users yet - add one below.';

                return;
            }

            users.forEach(function (name) {
                let row      = table.insertRow();
                let renew    = document.createElement('button');
                let remove   = document.createElement('button');
                let controls = row.insertCell();

                row.insertCell().textContent = name;

                renew.type         = 'button';
                renew.textContent  = 'New password';
                remove.type        = 'button';
                remove.textContent = 'Remove';

                renew.addEventListener('click', function () {
                    renewing = name;

                    part('renew-name').textContent = renewing;
                    part('renew-password').value   = '';
                    part('renew-box').hidden       = false;
                    part('renew-password').focus();
                });

                remove.addEventListener('click', function () {
                    if (!window.confirm('Remove ' + name + '? Their calendars and contacts are kept.')) {
                        return;
                    }

                    act('remove_user', { name: name }, 'Removing…', name + ' removed.', 'users-message');
                });

                controls.appendChild(renew);
                controls.appendChild(document.createTextNode(' '));
                controls.appendChild(remove);
            });
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

                // Its addresses: the Nginx app's (HTTPS), and port 5232 on the local network unless only through the
                // Nginx app
                let addresses = [];

                if (response.site.url) {
                    addresses.push(response.site.url);
                }

                if (response.listen === 'all') {
                    addresses.push('http://' + window.location.hostname + ':5232/');
                }

                part('address').textContent = (addresses.join(' and ') || 'none - turn off "Only through the Nginx app", or set the Nginx app up') +
                    (response.site.url ? '' : ' (HTTPS: ' + siteStates[response.site.state] + ')');
                part('address').className   = addresses.length ? '' : 'mg-bad';
                part('link').hidden         = !addresses.length;
                part('link').href           = addresses.length ? addresses[0] + '.web/' : '#';

                // For the phones: iPhones take a host name (HTTPS) or host:port (plain HTTP), DAVx⁵ the address
                part('address-dav').textContent = addresses[0] || '-';
                part('server').textContent      = addresses.length ? addresses[0].replace(/^https?:\/\//, '').replace(/\/$/, '') : '-';

                if (!loaded) {
                    part('local').checked = response.listen === 'local';

                    loaded = true;
                }

                showUsers(response.users);

                part('log').textContent = response.log.length ? response.log.join('\n') : 'Nothing logged';
            });
        }

        // Keep the page current, until the dashboard removes it
        <?php manage_timer_script(); ?>
        <?php manage_act_script(); ?>

        button('restart').addEventListener('click', function () {
            act('restart', { confirm: 1 }, 'Restarting Radicale…', 'Radicale restarted.', 'top-message');
        });

        button('listen').addEventListener('click', function () {
            let local = part('local').checked;

            act('listen', { listen: local ? 'local' : 'all' }, 'Saving…', local ? 'Radicale is now only reachable through the Nginx app.' :
                'Radicale is reachable on port 5232 too.', 'access-message');
        });

        button('add').addEventListener('click', function () {
            let name  = part('name').value.trim();
            let typed = part('password').value.trim();

            act('add_user', { name: name, password: typed }, `Adding ${name}…`,
                typed ? `${name} added, with the password you typed.` : `${name} added (their password is shown below).`, 'users-message').then(function (response) {
                if (response) {
                    showPassword(response, typed);

                    part('name').value     = '';
                    part('password').value = '';
                }
            });
        });

        button('renew-cancel').addEventListener('click', function () {
            part('renew-box').hidden     = true;
            part('renew-password').value = '';
        });

        button('renew-save').addEventListener('click', function () {
            let name  = renewing;
            let typed = part('renew-password').value.trim();

            act('new_password', { name: name, password: typed }, 'Saving…',
                typed ? `New password for ${name} saved.` : `New password for ${name} (shown below).`, 'users-message').then(function (response) {
                if (response) {
                    showPassword(response, typed);

                    part('renew-box').hidden     = true;
                    part('renew-password').value = '';
                }
            });
        });

        part('renew-password').addEventListener('keydown', function (event) {
            if (event.key === 'Enter') {
                button('renew-save').click();
            }
        });

        button('copy').addEventListener('click', function () {
            copyText(shown).then(function (copied) {
                say(copied ? 'Password copied.' : 'Could not copy - select it instead.', copied, 'users-message');
            });
        });

        refresh();
    })();
    </script>
</div>
