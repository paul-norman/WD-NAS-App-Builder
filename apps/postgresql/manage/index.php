<?php
// PostgreSQL's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('postgresql');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="postgresql-manage">
    <?php manage_styles('postgresql-manage'); ?>

    <h2>PostgreSQL</h2>
    <table>
        <tr><td>Status</td><td data-pg="status">…</td></tr>
        <tr><td>Connections</td><td data-pg="network">…</td></tr>
    </table>
    <p><label><input type="checkbox" data-pg="network-on"> Accept connections from the local network (with passwords)</label>
        <button type="button" data-pg-action="network">Save</button>
        <span class="mg-note">PostgreSQL restarts, disconnecting its clients.</span></p>
    <p data-pg="network-message"></p>

    <h3>The <code>postgres</code> superuser</h3>
    <p>Password: <code data-pg="password">••••••••••••</code> <button type="button" data-pg-action="show">Show</button> <button type="button" data-pg-action="copy">Copy</button></p>
    <p><input type="text" data-pg="new" placeholder="New password (leave empty to generate one)" autocomplete="off" spellcheck="false">
        <button type="button" data-pg-action="set">Change password</button></p>
    <p data-pg="password-message"></p>
    <p class="mg-note">Connect on port 5432 (the NAS's address, or localhost / the socket in /var/run/postgresql on the NAS).
        Over SSH: <code>PGPASSWORD=… psql -h /var/run/postgresql -U postgres</code>.</p>

    <h3>Extensions</h3>
    <p>Included (add one to a database with <code>CREATE EXTENSION name;</code>): <strong>postgis</strong> (geometry and
        geography - no rasters) and postgis_topology, <strong>vector</strong> (pgvector), <strong>pg_cron</strong>,
        <strong>pg_partman</strong>, <strong>pgaudit</strong>, and PostgreSQL's own (pgcrypto, uuid-ossp, pg_trgm, hstore,
        citext, postgres_fdw, pg_stat_statements…).</p>
    <p>Loaded at start-up (needed before <code>CREATE EXTENSION</code>):
        <label><input type="checkbox" data-pg="pre-pg_cron"> pg_cron</label>
        <label><input type="checkbox" data-pg="pre-pgaudit"> pgaudit</label>
        <button type="button" data-pg-action="preload">Save</button>
        <span class="mg-note">PostgreSQL restarts. pg_cron's jobs live in the postgres database.</span></p>
    <p data-pg="preload-message"></p>

    <h3>Databases</h3>
    <table data-pg="databases"></table>
    <p><input type="text" data-pg="db-name" placeholder="New database" autocomplete="off" spellcheck="false">
        <input type="text" data-pg="db-user" placeholder="Its user (default: the same name)" autocomplete="off" spellcheck="false">
        <button type="button" data-pg-action="create">Create</button></p>
    <p data-pg="create-message"></p>
    <p class="mg-note">Each database gets a user of its own, with a generated password - shown once, so note it down.
        Names are lower case letters, digits and _.</p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('postgresql', 'pg'); ?>
        <?php manage_secret_script(); ?>

        /**
         * Loads the app's status from its API and shows it.
         *
         * @return {Promise} Done once it's shown
         */
        function refresh() {
            return call('status').then(function (response) {
                if (!response.ok) {
                    say(response.error, false, 'network-message');

                    return;
                }

                let status = part('status');

                status.textContent = response.running ? 'Running (PostgreSQL ' + response.version + ')' : 'Not running' + (response.error ? ': ' + response.error : '');
                status.className   = response.running ? 'mg-ok' : 'mg-bad';

                part('network').textContent = response.network ? 'from the local network and the NAS' : 'from the NAS only';
                part('network-on').checked  = response.network;
                part('pre-pg_cron').checked = response.preload.indexOf('pg_cron') !== -1;
                part('pre-pgaudit').checked = response.preload.indexOf('pgaudit') !== -1;

                let table = part('databases');

                table.textContent = '';

                let head = table.insertRow();

                ['Database', 'Owner', 'Size'].forEach(function (text) {
                    let cell = head.insertCell();

                    cell.textContent      = text;
                    cell.style.fontWeight = 'bold';
                });

                response.databases.forEach(function (db) {
                    let row = table.insertRow();

                    [db.name, db.owner, db.size].forEach(function (text) {
                        row.insertCell().textContent = text;
                    });
                });
            });
        }

        button('network').addEventListener('click', function () {
            say('Restarting PostgreSQL…', true, 'network-message');

            call('network', { on: part('network-on').checked ? 1 : '' }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false, 'network-message');

                    return;
                }

                say(response.network ? 'PostgreSQL now accepts connections from the local network.' : 'PostgreSQL now only accepts connections from the NAS.', true, 'network-message');
                refresh();
            });
        });

        button('preload').addEventListener('click', function () {
            let data = new URLSearchParams();

            ['pg_cron', 'pgaudit'].forEach(function (name) {
                if (part('pre-' + name).checked) {
                    data.append('extensions[]', name);
                }
            });

            say('Restarting PostgreSQL…', true, 'preload-message');
            call('preload', data).then(function (response) {
                if (!response.ok) {
                    say(response.error, false, 'preload-message');

                    return;
                }

                say(response.preload.length ? 'Loaded at start-up: ' + response.preload.join(', ') : 'No extensions loaded at start-up.', true, 'preload-message');
                refresh();
            });
        });

        button('create').addEventListener('click', function () {
            call('create_database', { name: part('db-name').value, user: part('db-user').value }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false, 'create-message');

                    return;
                }

                part('db-name').value = part('db-user').value = '';

                say('Created database ' + response.name + ' - user ' + response.user + ', password ' + response.password + ' (note it down: it isn\'t shown again).', true, 'create-message');
                refresh();
            });
        });

        // The password: Show / Hide and Copy (fetched when first needed)
        let secret = secretControls(part('password'), button('show'), button('copy'), function () {
            return call('password', { show: 1 }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false, 'password-message');

                    return null;
                }

                return response.password || '';
            });
        });

        button('set').addEventListener('click', function () {
            if (!window.confirm('Change the postgres password? Clients using it will need the new one.')) {
                return;
            }

            call('set_password', { password: part('new').value }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false, 'password-message');

                    return;
                }

                part('new').value = '';

                secret.set(response.password);

                say('Password changed.', true, 'password-message');
            });
        });

        refresh();
    })();
    </script>
</div>
