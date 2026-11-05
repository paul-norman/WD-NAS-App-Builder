<?php
// Paperless-ngx's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('paperless-ngx');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="paperless-manage">
    <?php manage_styles('paperless-manage'); ?>

    <h2>Paperless-ngx</h2>
    <table>
        <tr><td>Status</td><td data-pl="status">…</td></tr>
        <tr><td>Processes</td><td data-pl="services">-</td></tr>
        <tr><td>Version</td><td data-pl="version">-</td></tr>
        <tr><td>Address</td><td data-pl="address">-</td></tr>
    </table>
    <p class="mg-note mg-bad" data-pl="valkey-note" hidden>Paperless needs the Valkey app: install and start it.</p>
    <p><a class="mg-button" data-pl="link" href="#" target="_blank" rel="noopener">Open Paperless</a>
        <button type="button" data-pl-action="restart">Restart Paperless</button></p>

    <h3>Logging in</h3>
    <p>User name <code>admin</code>, password <code data-pl="password">••••••••••••</code>
        <button type="button" data-pl-action="show">Show</button> <button type="button" data-pl-action="copy">Copy</button>
        <button type="button" data-pl-action="new-password">New password</button></p>
    <p class="mg-note">The first password is generated; if you change it in Paperless, this one no longer applies (a new
        one from here does). Add more users in Paperless itself.</p>

    <h3>Adding documents</h3>
    <p>Drop files (PDFs, images, text) in the consume folder <code data-pl="consume">-</code> - over SMB, from a
        scanner's "scan to folder", or another app - or upload them in Paperless. They're imported, read (OCR) and
        removed from the folder.</p>

    <h3>Settings</h3>
    <p><label>Consume folder <input type="text" data-pl="consume-dir" size="40" spellcheck="false"></label></p>
    <p><label>Documents' language (for OCR)
        <select data-pl="ocr-language">
            <option value="eng">English</option>
            <option value="deu">German</option>
            <option value="eng+deu">English and German</option>
        </select></label></p>
    <p><label><input type="checkbox" data-pl="local"> Only through the Nginx app (HTTPS)</label>
        <button type="button" data-pl-action="settings">Save</button></p>
    <p class="mg-note">The consume folder must be in one of the NAS's shares. Paperless restarts.</p>

    <details class="mg-section">
        <summary>Paperless's latest log lines</summary>
        <pre data-pl="log"></pre>
    </details>

    <p data-pl="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('paperless-ngx', 'pl'); ?>
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

                const status  = part('status');
                const names   = Object.keys(response.services);
                const up      = names.filter(function (name) {
                    return response.services[name];
                });
                const url     = response.site.url || (response.listen === 'local' ? '' : response.address);

                if (response.answering && up.length === names.length) {
                    status.textContent = 'Running';
                } else if (response.launching) {
                    status.textContent = `Starting (${response.state || 'waiting'})…`;
                } else if (up.length) {
                    status.textContent = 'Starting…';
                } else {
                    status.textContent = response.state === 'no Valkey' ? 'Stopped: the Valkey app is not running' : 'Stopped';
                }

                status.className = response.answering && up.length === names.length ? 'mg-ok' : 'mg-bad';

                part('services').textContent    = names.map(function (name) {
                    return `${name} ${response.services[name] ? '✓' : '✗'}`;
                }).join(', ');
                part('version').textContent     = response.version || '-';
                part('address').textContent     = [response.site.url, response.listen === 'local' ? '' : response.address].filter(Boolean).join(' and ') || '-';
                part('link').href               = url || '#';
                part('consume').textContent     = response.consume_dir || '-';
                part('valkey-note').hidden      = response.valkey;

                if (!loaded) {
                    part('consume-dir').value  = response.consume_dir;
                    part('ocr-language').value = response.ocr_language;
                    part('local').checked      = response.listen === 'local';

                    loaded = true;
                }

                part('log').textContent = response.log.length ? response.log.join('\n') : 'Nothing logged';
            });
        }

        // Keep the page current, until the dashboard removes it
        <?php manage_timer_script(); ?>
        <?php manage_act_script(); ?>

        button('restart').addEventListener('click', function () {
            act('restart', { confirm: 1 }, 'Restarting Paperless…', 'Paperless restarting - it takes a minute to be ready.');
        });

        // The password: Show / Hide and Copy (fetched when first needed)
        const password = secretControls(part('password'), button('show'), button('copy'), function () {
            return call('password', { show: 1 }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return null;
                }

                return response.password;
            });
        });

        button('new-password').addEventListener('click', function () {
            if (!window.confirm('Give the admin user a new password? The current one stops working at once.')) {
                return;
            }

            act('new_password', { confirm: 1 }, 'Setting a new password…', 'New password in use.').then(function (response) {
                if (response) {
                    password.set(response.password);
                }
            });
        });

        button('settings').addEventListener('click', function () {
            act('settings', {
                consume_dir:  part('consume-dir').value,
                ocr_language: part('ocr-language').value,
                listen:       part('local').checked ? 'local' : 'all'
            }, 'Saving…', 'Saved - Paperless restarting.');
        });

        refresh();
    })();
    </script>
</div>
