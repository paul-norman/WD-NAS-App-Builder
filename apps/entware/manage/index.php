<?php
// Entware's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('entware');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="entware-manage">
    <?php manage_styles('entware-manage'); ?>
    <style>
        #entware-manage pre { background: rgba(127, 127, 127, 0.15); border-radius: 4px; padding: 0.5rem; max-height: 16rem; overflow: auto; white-space: pre-wrap; font-size: 0.85em; }
        #entware-manage details { margin: 0.5rem 0; }
        #entware-manage summary { cursor: pointer; }
    </style>

    <h2>Entware</h2>
    <table>
        <tr><td>Status</td><td data-ew="status">…</td></tr>
        <tr><td>Architecture</td><td data-ew="arch">-</td></tr>
        <tr><td>Downloads</td><td><span data-ew="https">-</span> <button type="button" data-ew-action="use-https" hidden>Switch to HTTPS</button></td></tr>
        <tr><td>Installed packages</td><td data-ew="count">-</td></tr>
    </table>

    <h3>Updates</h3>
    <p data-ew="updates-summary">-</p>
    <table data-ew="updates"></table>
    <p><button type="button" data-ew-action="check">Check for updates</button>
        <button type="button" data-ew-action="upgrade" hidden>Update all</button></p>

    <h3>Services</h3>
    <table data-ew="services"></table>

    <h3>Packages</h3>
    <p><input type="text" data-ew="term" placeholder="Search, e.g. htop" autocomplete="off" spellcheck="false">
        <button type="button" data-ew-action="search">Search</button></p>
    <table data-ew="results"></table>
    <details>
        <summary>Installed packages</summary>
        <table data-ew="installed"></table>
    </details>

    <div data-ew="job-box" hidden>
        <h3>Progress</h3>
        <pre data-ew="job-log"></pre>
    </div>

    <p data-ew="message"></p>

    <details class="mg-section">
        <summary>Using Entware over SSH</summary>
        <pre>opkg update               # refresh the package list
opkg find '*name*'        # search for a package
opkg install &lt;package&gt;    # install a package
opkg list-installed       # show installed packages
opkg upgrade              # update installed packages</pre>
        <p class="mg-note">Packages are kept in <code>Nas_Prog/_entware/opt</code> (mounted on <code>/opt</code>) and root's home folder in
            <code>Nas_Prog/_entware/home</code>: both survive reinstalls. See the
            <a href="https://github.com/Entware/Entware/wiki" target="_blank" rel="noopener">Entware wiki</a> for more.</p>
    </details>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('entware', 'ew'); ?>

        let installed     = {};
        let jobWasRunning = false;

        /**
         * Fills a table with rows: text values (package names etc. are only ever set as text), or { text, className },
         * or { button, onClick } for a button (disabled while a job runs).
         *
         * @param {HTMLTableElement}    table  The table
         * @param {Array.<string>|null} header The header row's titles, or null for none
         * @param {Array.<Array>}       rows   The rows
         * @param {string}              empty  What to show when there are no rows ('' for nothing)
         *
         * @return {void}
         */
        function fillTable(table, header, rows, empty) {
            table.textContent = '';

            if (!rows.length) {
                if (empty) {
                    table.insertRow().insertCell().textContent = empty;
                }

                return;
            }

            if (header) {
                let head = table.insertRow();

                header.forEach(function (text) {
                    let cell = head.insertCell();

                    cell.textContent = text;
                    cell.style.fontWeight = 'bold';
                });
            }

            rows.forEach(function (values) {
                let row = table.insertRow();

                values.forEach(function (value) {
                    let cell = row.insertCell();

                    [].concat(value).forEach(function (item) {
                        if (item && item.button) {
                            let button = document.createElement('button');

                            button.type        = 'button';
                            button.textContent = item.button;
                            button.disabled    = jobWasRunning;

                            button.addEventListener('click', item.onClick);

                            cell.appendChild(button);
                        } else if (item && typeof item === 'object') {
                            cell.textContent = item.text;
                            cell.className   = item.className;
                        } else {
                            cell.textContent = item;
                        }
                    });
                });
            });
        }

        /**
         * Starts a package job (after asking and if a question is given) and shows the status again - the page follows its progress.
         *
         * @param {string} action   The API's action (e.g. install)
         * @param {Object} data     What to post
         * @param {string} question What to ask first, or '' to go ahead
         *
         * @return {void}
         */
        function startJob(action, data, question) {
            if (question && !window.confirm(question)) {
                return;
            }

            call(action, data).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return;
                }

                say('', true);
                refresh();
            });
        }

        /**
         * Shows Entware's services, each with whether it runs and its Start, Stop and Restart buttons.
         *
         * @param {Array.<Object>} services The services: name and running (true, false or null)
         *
         * @return {void}
         */
        function showServices(services) {
            fillTable(part('services'), null, services.map(function (service) {
                return [
                    service.name,
                    {
                        text:      service.running === null ? 'unknown' : (service.running ? 'running' : 'stopped'),
                        className: service.running ? 'mg-ok' : 'mg-note'
                    },
                    ['start', 'stop', 'restart'].map(function (command) {
                        return {
                            button: command.charAt(0).toUpperCase() + command.slice(1),
                            onClick: function () {
                                say(command.charAt(0).toUpperCase() + command.slice(1) + ': ' + service.name + '…', true);
                                call('service', { service: service.name, command: command }).then(function (response) {
                                    if (!response.ok) {
                                        say(response.error, false);

                                        return;
                                    }

                                    say(response.output || 'Done.', true);
                                    refresh();
                                });
                            }
                        };
                    })
                ];
            }), 'No services (they come with packages such as sshd or nginx)');
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

                status.textContent = !response.installed ? 'Not installed' + (response.mounted ? '' : ' (/opt is not mounted - enable the app)') :
                    (response.job_running ? 'Busy (see Progress below)' : 'Ready');
                status.className   = response.installed ? 'mg-ok' : 'mg-bad';

                part('arch').textContent   = response.arch || '-';
                part('https').textContent  = response.installed ? (response.https ? 'HTTPS' : 'HTTP (not encrypted)') : '-';
                part('https').className    = response.installed && !response.https ? 'mg-bad' : '';
                button('use-https').hidden = !response.installed || response.https;
                part('count').textContent  = response.packages.length;

                if (part('updates').rows.length === 0) {
                    part('updates-summary').textContent = response.updates_last_check === '' ? 'Not checked yet.' :
                        'Last check: ' + response.updates_last_check + ' update(s) available.';
                }

                installed = {};

                response.packages.forEach(function (pkg) {
                    installed[pkg.name] = pkg.version;
                });

                fillTable(part('installed'), ['Package', 'Version', ''], response.packages.map(function (pkg) {
                    return [pkg.name, pkg.version, pkg.core ? { text: 'part of Entware', className: 'mg-note' } : { button: 'Remove', onClick: function () {
                        startJob('remove', { packages: pkg.name }, 'Remove ' + pkg.name + '? Packages that need it may stop working.');
                    } }];
                }), 'None');

                showServices(response.services);

                // A package job's output, until it is dismissed by the next job
                part('job-box').hidden      = response.job_log === '';
                part('job-log').textContent = response.job_log;
                part('job-log').scrollTop   = part('job-log').scrollHeight;

                if (jobWasRunning && !response.job_running) {
                    say('Finished - see Progress.', true);

                    part('updates').textContent = '';
                    button('upgrade').hidden    = true;
                }

                jobWasRunning = response.job_running;

                root.querySelectorAll('button').forEach(function (button) {
                    button.disabled = response.job_running && button.dataset.ewAction !== 'search';
                });
            });
        }

        // Keep the page current (e.g. while a package job runs), until the dashboard removes it
        <?php manage_timer_script(4000); ?>

        button('check').addEventListener('click', function () {
            say('Checking for updates…', true);
            call('check_updates', { check: 1 }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return;
                }

                say('', true);
                part('updates-summary').textContent = response.updates.length ? response.updates.length + ' update(s) available:' : 'Everything is up to date.';

                fillTable(part('updates'), ['Package', 'Installed', 'New'], response.updates.map(function (item) {
                    return [item.name, item.version, item.new_version];
                }));

                button('upgrade').hidden = !response.updates.length;
            });
        });

        button('use-https').addEventListener('click', function () {
            startJob('use_https', { confirm: 1 }, 'Switch Entware to HTTPS downloads? This first updates all installed packages, then installs wget-ssl and ca-bundle.');
        });

        button('upgrade').addEventListener('click', function () {
            startJob('upgrade', { all: 1 }, 'Update all Entware packages? Services may restart.');
        });

        /**
         * Searches Entware's packages for the term typed, showing the first 200 matches with an Install button for
         * those not installed.
         *
         * @return {void}
         */
        function search() {
            let term = part('term').value.trim();

            say('Searching…', true);
            call('search', { term: term }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return;
                }

                say(response.more ? 'Showing the first 200 matches - try a longer search.' : '', true);

                fillTable(part('results'), ['Package', 'Version', 'Description', ''], response.results.map(function (item) {
                    return [
                        item.name, item.version, item.description, installed[item.name] ? { text: 'installed', className: 'mg-ok' } :
                        {
                            button: 'Install',
                            onClick: function () {
                                startJob('install', { packages: item.name }, 'Install ' + item.name + '?');
                            }
                        }];
                }), 'Nothing found');
            });
        }

        button('search').addEventListener('click', search);

        part('term').addEventListener('keydown', function (event) {
            if (event.key === 'Enter') {
                event.preventDefault();

                search();
            }
        });

        refresh();
    })();
    </script>
</div>
