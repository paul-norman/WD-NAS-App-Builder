<?php
// Mailpit's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('mailpit');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="mailpit-manage">
    <?php manage_styles('mailpit-manage'); ?>

    <h2>Mailpit</h2>
    <table>
        <tr><td>Status</td><td data-mp="status">…</td></tr>
        <tr><td>Version</td><td data-mp="version">-</td></tr>
        <tr><td>Messages</td><td data-mp="messages">-</td></tr>
    </table>
    <p><a class="mg-button" data-mp="link" href="#" target="_blank" rel="noopener">Open Mailpit</a>
        <button type="button" data-mp-action="restart">Restart Mailpit</button>
        <button type="button" data-mp-action="delete">Delete all messages</button></p>

    <h3>Sending mail to Mailpit</h3>
    <p>Point your apps' SMTP settings at the NAS, port <code>1026</code>. Any username and password are accepted, and
        nothing is delivered: every message only appears in Mailpit.</p>

    <p data-mp="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('mailpit', 'mp'); ?>

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

                part('version').textContent  = response.version || '-';
                part('messages').textContent = response.answering ? response.total + ' (' + response.unread + ' unread)' : '-';

                button('delete').disabled = !response.answering || response.total === 0;
            });
        }

        part('link').href = 'http://' + window.location.hostname + ':8025/';

        button('restart').addEventListener('click', function () {
            say('Restarting Mailpit…', true);
            call('restart', { confirm: 1 }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return;
                }

                say('Mailpit restarted.', true);
                setTimeout(refresh, 1000);
            });
        });

        button('delete').addEventListener('click', function () {
            if (!window.confirm('Delete all messages in Mailpit? This can\'t be undone.')) {
                return;
            }

            call('delete_all', { confirm: 1 }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return;
                }

                say('All messages deleted.', true);
                refresh();
            });
        });

        refresh();
    })();
    </script>
</div>
