<?php
// The Python app's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('python');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="python-manage">
    <?php manage_styles('python-manage'); ?>

    <h2>Python</h2>
    <table>
        <tr><td>python3</td><td data-py="active">…</td></tr>
        <tr><td>The app's Python</td><td data-py="app">-</td></tr>
        <tr><td>WD's Python</td><td data-py="wd">-</td></tr>
        <tr><td>pip<span data-py="uv-label"> / uv</span></td><td data-py="tools">-</td></tr>
        <tr><td>Commands</td><td data-py="links">-</td></tr>
    </table>
    <p><button type="button" data-py-action="use-app">Use the app's Python</button>
        <button type="button" data-py-action="use-wd">Use WD's Python 3.9</button></p>
    <p class="mg-note">WD's boot scripts and its Windows network discovery (wsdd<span data-py="wsdd"></span>) start before
        the apps, so they always run on WD's own Python. The choice is kept across reboots and reinstalls.</p>

    <h3>Packages</h3>
    <p>Packages go in a virtual environment (packages installed into the app's Python itself would be lost with its next
        update), kept wherever you like - e.g. under <code>/home/root</code> (persistent with the Entware app) or on a
        share:</p>
    <pre>python3 -m venv /home/root/venvs/myproject
/home/root/venvs/myproject/bin/pip install requests
/home/root/venvs/myproject/bin/python myscript.py</pre>
    <div data-py="uv-help" hidden>
        <p>Or with uv, which also runs tools and single scripts with their own packages:</p>
        <pre>uv venv /home/root/venvs/myproject
uvx ruff check myscript.py
uv run --with requests myscript.py</pre>
    </div>
    <p class="mg-note">Virtual environments use the app's Python, so they keep working across the app's updates within
        3.14 (a new 3.x line needs them made again). The NAS has no compiler: packages are installed from ready-built
        wheels, which almost all popular packages have.</p>

    <p data-py="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('python', 'py'); ?>

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

                let active = part('active');

                active.textContent = (response.active || '-') + (response.app_active ? ' (the app\'s)' : ' (WD\'s)');
                active.className   = response.app_active ? 'mg-ok' : '';

                part('app').textContent   = response.app_version || 'not found';
                part('wd').textContent    = response.wd_version || 'not found';
                part('tools').textContent = [response.pip, response.uv].filter(Boolean).join(', ') || '-';
                part('uv-label').hidden   = !response.uv;
                part('uv-help').hidden    = !response.uv;
                part('links').textContent = response.links.length ? response.links.join(', ') : 'none (WD\'s python3 only)';
                part('wsdd').textContent  = response.wsdd ? ', now running on ' + response.wsdd : '';

                button('use-app').disabled = response.app_active;
                button('use-wd').disabled  = !response.app_active;
            });
        }

        /**
         * Switches the NAS's python3 to the app's Python or WD's, and shows the status again.
         *
         * @param {string} which app or wd
         * @param {string} done  What to say once it's done
         *
         * @return {void}
         */
        function usePython(which, done) {
            call('use', { python: which }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return;
                }

                say(done, true);
                refresh();
            });
        }

        button('use-app').addEventListener('click', function () {
            usePython('app', 'python3 is now the app\'s Python.');
        });

        button('use-wd').addEventListener('click', function () {
            usePython('wd', 'python3 is now WD\'s Python 3.9 (pip3, uv and uvx are removed until you switch back).');
        });

        refresh();
    })();
    </script>
</div>
