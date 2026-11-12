<?php
// The MariaDB app's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('mariadb');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="mariadb-manage">
    <?php manage_styles('mariadb-manage'); ?>
    <style>
        #mariadb-manage pre { background: rgba(127, 127, 127, 0.15); border-radius: 4px; padding: 0.5rem; max-height: 16rem; overflow: auto; white-space: pre-wrap; font-size: 0.8em; }
    </style>

    <h2>MariaDB</h2>
    <table>
        <tr><td>Running</td><td data-md="version">…</td></tr>
        <tr><td>Mode</td><td data-md="mode">…</td></tr>
        <tr><td>Data</td><td data-md="data">…</td></tr>
        <tr><td>WD's own data</td><td data-md="wd">…</td></tr>
    </table>
    <p class="mg-note">MariaDB 11.8 runs on a copy of WD's data (made the first time), so WD's own stays untouched: disable
        the app to switch the NAS back to WD's MariaDB 10.5 with it (anything changed under 11.8 stays in the copy). It
        listens where WD's did (the NAS only, socket /var/lib/mysql/mysql.sock, port 3306), so phpMyAdmin works as before.
        On a NAS without a MariaDB of its own, the app runs MariaDB by itself, on its own new data, in the same place.</p>

    <p class="mg-note" data-md="rebuilt" hidden></p>

    <h3>Warnings and errors (since it last started)</h3>
    <pre data-md="problems">…</pre>

    <p data-md="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('mariadb', 'md'); ?>

        call('status').then(function (response) {
            if (!response.ok) {
                say(response.error, false);

                return;
            }

            let version = part('version');

            version.textContent = !response.running ? 'not running' : response.version + (response.app_server ? '' : ' (WD\'s own)');
            version.className   = response.running && response.app_server ? 'mg-ok' : 'mg-bad';

            part('data').textContent     = response.app_server ? response.copy + (response.copy_size ? ' (' + response.copy_size + ')' : '') : 'WD\'s own';
            part('wd').textContent       = response.wd_datadir || '-';
            part('mode').textContent     = response.mode === 'own' ? 'By itself (the NAS has no MariaDB of its own)' : 'Underneath WD\'s own MariaDB';
            part('problems').textContent = response.problems.length ? response.problems.join('\n') : 'None.';

            if (response.rebuilt) {
                let rebuilt = response.rebuilt.split(' ');

                part('rebuilt').textContent = 'WD\'s MariaDB data had an inconsistent catalogue (system tables listed whose files were missing), so on '
                    + rebuilt[0] + ' MariaDB 11.8\'s system tables were rebuilt, with your databases and users carried over. The copy as it was is kept in '
                    + rebuilt.slice(2).join(' ') + ' (WD\'s own data was never changed).';
                part('rebuilt').hidden = false;
            }
        });
    })();
    </script>
</div>
