<?php
// The PHP app's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('php');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="php-manage">
    <?php manage_styles('php-manage'); ?>
    <style>
        #php-manage pre { background: rgba(127, 127, 127, 0.15); border-radius: 4px; padding: 0.5rem; max-height: 20rem; overflow: auto; white-space: pre-wrap; font-size: 0.8em; }
        #php-manage details { margin: 0.5rem 0; }
        #php-manage summary { cursor: pointer; }
    </style>

    <h2>PHP</h2>
    <table>
        <tr><td>NAS web interface</td><td data-ph="fpm">…</td></tr>
        <tr><td>Command line (<code>php</code>)</td><td data-ph="cli">…</td></tr>
        <tr><td>Fixes to WD's code</td><td data-ph="patches">…</td></tr>
    </table>
    <p class="mg-note">Disable the app to switch the NAS back to WD's own PHP 7.4, and enable it to switch to PHP 8.5 again
        (running requests finish first, so the switch can take a few seconds).</p>

    <h3>Errors</h3>
    <p data-ph="error-summary">…</p>
    <pre data-ph="errors" hidden></pre>
    <p><button type="button" data-ph-action="refresh">Refresh</button>
        <button type="button" data-ph-action="clear">Clear the log</button></p>
    <p class="mg-note">Only real errors are logged (not deprecations or notices), to <code>Nas_Prog/_php/php-errors.log</code>,
        which is rotated once it reaches 256KB.</p>

    <details class="mg-section">
        <summary>Built-in extensions</summary>
        <p data-ph="extensions">…</p>
    </details>

    <p data-ph="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('php', 'ph'); ?>

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

                let fpm = part('fpm');

                fpm.textContent = 'PHP ' + response.fpm_version + (response.app_php ? '' : ' (WD\'s own)') + (response.restart_pending ? ' - switching in a few seconds…' : '');
                fpm.className   = response.app_php ? 'mg-ok' : 'mg-bad';

                part('cli').textContent           = response.cli_version ? 'PHP ' + response.cli_version : '-';
                part('patches').textContent       = response.patches.length ? response.patches.join(', ') : (response.app_php ? 'none - missing!' : 'none (not needed for PHP 7.4)');
                part('patches').className         = response.app_php && !response.patches.length ? 'mg-bad' : '';
                part('extensions').textContent    = response.extensions.join(', ');
                part('error-summary').textContent = response.error_count ? response.error_count + ' line(s) in the log (the last 100 shown, newest last):' : 'No errors logged.';
                part('error-summary').className   = response.error_count ? 'mg-bad' : 'mg-ok';
                part('errors').hidden             = !response.error_count;
                part('errors').textContent        = response.errors.join('\n');
                part('errors').scrollTop          = part('errors').scrollHeight;

                button('clear').disabled = !response.error_count;
            });
        }

        button('refresh').addEventListener('click', refresh);

        button('clear').addEventListener('click', function () {
            if (!window.confirm('Clear the PHP error log?')) {
                return;
            }

            call('clear_log', { confirm: 1 }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return;
                }

                say('Log cleared.', true);
                refresh();
            });
        });

        refresh();
    })();
    </script>
</div>
