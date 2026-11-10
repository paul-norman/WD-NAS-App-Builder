<?php
// Vikunja's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('vikunja');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="vikunja-manage">
    <?php manage_styles('vikunja-manage'); ?>

    <h2>Vikunja</h2>
    <table>
        <tr><td>Status</td><td data-vk="status">…</td></tr>
        <tr><td>Version</td><td data-vk="version">-</td></tr>
        <tr><td>Address</td><td data-vk="address">-</td></tr>
    </table>
    <p class="mg-note" data-vk="restart-note" hidden>The Nginx app's address for Vikunja has changed: restart Vikunja so
        that its links use it.</p>
    <p><a class="mg-button" data-vk="link" href="#" target="_blank" rel="noopener">Open Vikunja</a>
        <button type="button" data-vk-action="restart">Restart Vikunja</button></p>

    <h3>Logging in</h3>
    <p>User name <code>admin</code>, password <code data-vk="password">••••••••••••</code>
        <button type="button" data-vk-action="show">Show</button> <button type="button" data-vk-action="copy">Copy</button>
        <button type="button" data-vk-action="new-password">Reset the password</button></p>
    <p class="mg-note">The app made this account, so nobody else can claim Vikunja. You can change its password in Vikunja's
        own settings: this page then no longer knows it - Reset the password sets a new one it shows.</p>

    <h3>Users</h3>
    <table data-vk="users"></table>
    <p><label>User name <input type="text" data-vk="new-name" size="16" spellcheck="false" placeholder="e.g. sam"></label>
        <label>Email <input type="text" data-vk="new-email" size="24" spellcheck="false" placeholder="sam@example.com"></label>
        <button type="button" data-vk-action="add-user">Add a user</button></p>
    <p data-vk="new-secret" hidden></p>
    <p class="mg-note">Each user gets a generated password, shown here once - they can change it in Vikunja. Vikunja
        sends no email from the NAS (its "forgot password" doesn't work): reset forgotten passwords here. Phone and
        desktop to-do apps connect over CalDAV, with a token made in Vikunja's settings.</p>

    <h3>Backups</h3>
    <p data-vk="backups">-</p>
    <p><button type="button" data-vk-action="backup">Back up now</button></p>
    <p class="mg-note">Every night at 03:05: Vikunja's database (copied safely while it runs) and its attachments, in
        <code>Nas_Prog/_vikunja/backups</code> (only the NAS's administrator can read them). To restore one, stop
        Vikunja and unpack it into <code>Nas_Prog/_vikunja/data</code>.</p>

    <h3>Settings</h3>
    <p><label><input type="checkbox" data-vk="local"> Only through the Nginx app (HTTPS)</label><br>
        <label><input type="checkbox" data-vk="signups"> Anyone who can reach Vikunja can sign up</label><br>
        <label>Keep <input type="number" data-vk="keep" min="1" max="99" value="14"> backups</label>
        <button type="button" data-vk-action="settings">Save</button></p>
    <p class="mg-note">Without the Nginx app's HTTPS only, it's also reachable on port 3456 from the local network, over
        plain HTTP. Keep sign-ups off unless everyone who can reach it should have an account. Vikunja restarts.</p>

    <details class="mg-section">
        <summary>Vikunja's latest log lines</summary>
        <pre data-vk="log"></pre>
    </details>

    <p data-vk="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('vikunja', 'vk'); ?>
        <?php manage_secret_script(); ?>

        let loaded     = false;
        let siteStates = {
            no_nginx:  'the Nginx app isn\'t set up',
            no_domain: 'set a domain in the Nginx app',
            off:       'switched off in the Nginx app'
        };

        /**
         * Shows a user's new password, once.
         *
         * @param {string} user     The user name
         * @param {string} password Their password
         *
         * @return {void}
         */
        function showSecret(user, password) {
            let box = part('new-secret');

            box.textContent = '';
            box.appendChild(document.createTextNode(`${user}'s password: `));
            box.appendChild(Object.assign(document.createElement('code'), { textContent: password }));
            box.appendChild(document.createTextNode(' - give it to them now: this page doesn\'t keep it.'));
            box.hidden = false;
        }

        /**
         * Shows the users, each but admin with a button for a new password.
         *
         * @param {Array.<Object>} users The users: id, name and email
         *
         * @return {void}
         */
        function fillUsers(users) {
            let table = part('users');

            table.textContent = '';

            users.forEach(function (user) {
                let row = table.insertRow();

                row.insertCell().textContent = user.name;
                row.insertCell().textContent = user.email;

                if (user.name === 'admin') {
                    row.insertCell().textContent = '(the password above)';

                    return;
                }

                let reset = document.createElement('button');

                reset.type        = 'button';
                reset.textContent = 'New password';
                reset.addEventListener('click', function () {
                    if (!window.confirm(`Give ${user.name} a new password? Their current one stops working.`)) {
                        return;
                    }

                    act('new_password', { user: user.name }, 'Setting a new password…', `${user.name} has a new password.`).then(function (response) {
                        if (response) {
                            showSecret(user.name, response.password);
                        }
                    });
                });
                row.insertCell().appendChild(reset);
            });
        }

        /**
         * The backups, as the page says them.
         *
         * @param {Array.<Object>} backups The newest backups: name, size (bytes) and time (seconds since 1970)
         *
         * @return {string} The text
         */
        function backupsText(backups) {
            if (!backups.length) {
                return 'None yet.';
            }

            let latest = backups[0];
            let size   = latest.size >= 1048576 ? `${(latest.size / 1048576).toFixed(1)} MB` : `${Math.max(1, Math.round(latest.size / 1024))} KB`;

            return `Latest: ${new Date(latest.time * 1000).toLocaleString()} (${size}, ${latest.name})`;
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

                // Its addresses: the Nginx app's (HTTPS), and port 3456 on the local network unless only through the
                // Nginx app
                let addresses = [];

                if (response.site.url) {
                    addresses.push(response.site.url);
                }

                if (response.listen === 'all') {
                    addresses.push(`http://${window.location.hostname}:3456/`);
                }

                let none  = 'none - turn off "Only through the Nginx app", or set the Nginx app up';
                let https = response.site.url ? '' : ` (HTTPS: ${siteStates[response.site.state]})`;

                part('address').textContent = `${addresses.join(' and ') || none}${https}`;
                part('address').className   = addresses.length ? '' : 'mg-bad';
                part('link').hidden         = !addresses.length;
                part('link').href           = addresses[0] || '#';
                part('restart-note').hidden = !response.restart_needed;
                part('backups').textContent = backupsText(response.backups);

                fillUsers(response.users);

                if (!loaded) {
                    part('local').checked   = response.listen === 'local';
                    part('signups').checked = response.signups;
                    part('keep').value      = response.backup_keep;

                    loaded = true;
                }

                part('log').textContent = response.log.length ? response.log.join('\n') : 'Nothing logged';
            });
        }

        // Keep the page current, until the dashboard removes it
        <?php manage_timer_script(); ?>
        <?php manage_act_script(); ?>

        button('restart').addEventListener('click', function () {
            act('restart', { confirm: 1 }, 'Restarting Vikunja…', 'Vikunja restarted.');
        });

        // The admin password: Show / Hide and Copy (fetched when first needed)
        let password = secretControls(part('password'), button('show'), button('copy'), function () {
            return call('password', { show: 1 }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return null;
                }

                return response.password;
            });
        });

        button('new-password').addEventListener('click', function () {
            if (!window.confirm('Set a new password for Vikunja\'s admin account?')) {
                return;
            }

            act('new_password', { user: 'admin' }, 'Setting a new password…', 'New password in use.').then(function (response) {
                if (response) {
                    password.set(response.password);
                }
            });
        });

        button('add-user').addEventListener('click', function () {
            let name = part('new-name').value.trim();

            act('add_user', { name: name, email: part('new-email').value.trim() }, 'Adding…', `${name} added.`).then(function (response) {
                if (response) {
                    showSecret(response.user, response.password);
                    part('new-name').value  = '';
                    part('new-email').value = '';
                }
            });
        });

        button('backup').addEventListener('click', function () {
            act('backup', { confirm: 1 }, 'Backing up…', 'Backed up.');
        });

        button('settings').addEventListener('click', function () {
            act('settings', {
                listen:      part('local').checked ? 'local' : 'all',
                signups:     part('signups').checked ? 1 : 0,
                backup_keep: part('keep').value
            }, 'Saving…', 'Saved - Vikunja restarted.');
        });

        refresh();
    })();
    </script>
</div>
