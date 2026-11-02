<?php
// ValKey's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('valkey');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="valkey-manage">
    <?php manage_styles('valkey-manage'); ?>

    <h2>ValKey</h2>
    <table>
        <tr><td>Status</td><td data-vk="status">…</td></tr>
        <tr><td>Version</td><td data-vk="version">…</td></tr>
        <tr><td>Listening on</td><td data-vk="listen">…</td></tr>
    </table>

    <h3>Password</h3>
    <p>Clients connect with: <code data-vk="password">••••••••••••</code>
        <button type="button" data-vk-action="show">Show</button> <button type="button" data-vk-action="copy">Copy</button></p>
    <p class="mg-note">e.g. <code>REDISCLI_AUTH=&lt;password&gt; valkey-cli</code> over SSH, or the password setting of your app's Redis / ValKey client.</p>
    <p><input type="text" data-vk="new" placeholder="New password (leave empty to generate one)" autocomplete="off" spellcheck="false">
        <button type="button" data-vk-action="set">Change password</button></p>
    <p class="mg-note">The new password takes effect immediately, so update your clients too. Passwords are 12-128 characters: letters, digits and . _ ~ -</p>
    <p data-vk="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('valkey', 'vk'); ?>
        <?php manage_secret_script(); ?>

        /**
         * Loads the app's status from its API and shows it.
         *
         * @return {void}
         */
        function refresh() {
            call('status').then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return;
                }

                let status = part('status');

                status.textContent = response.running ? 'Running' : 'Stopped';
                status.className   = response.running ? 'mg-ok' : 'mg-bad';

                part('version').textContent = response.version || 'unknown';
                part('listen').textContent  = (response.bind || 'all interfaces') + ', port ' + response.port + (response.has_password ? ' (password required)' : ' (no password!)');
            });
        }

        // The password: Show / Hide and Copy (fetched when first needed)
        let secret = secretControls(part('password'), root.querySelector('[data-vk-action="show"]'), root.querySelector('[data-vk-action="copy"]'), function () {
            return call('password', { show: 1 }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return null;
                }

                return response.password || '(none)';
            });
        });

        root.querySelector('[data-vk-action="set"]').addEventListener('click', function () {
            let input = part('new');

            if (!window.confirm('Change the ValKey password? Clients using the old one will stop working until they are updated.')) {
                return;
            }

            call('set_password', { password: input.value }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return;
                }

                input.value = '';

                secret.set(response.password);

                say(response.applied ? 'Password changed - it is now in use.' : 'Password saved - it will be used when ValKey next starts.', true);
                refresh();
            });
        });

        refresh();
    })();
    </script>
</div>
