<?php
// Docker's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('docker');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="docker-manage">
    <?php manage_styles('docker-manage'); ?>

    <h2>Docker</h2>
    <table>
        <tr><td>Status</td><td data-dk="status">…</td></tr>
        <tr><td>Version</td><td data-dk="version">-</td></tr>
        <tr><td>Storage driver</td><td data-dk="driver">-</td></tr>
        <tr><td>Kernel modules</td><td data-dk="modules">-</td></tr>
        <tr><td>Memory</td><td data-dk="memory">-</td></tr>
    </table>
    <p class="mg-note" data-dk="driver-note" hidden></p>
    <p><button type="button" data-dk-action="restart">Restart Docker</button>
        <button type="button" data-dk-action="retry" hidden>Retry loading the modules</button></p>
    <p><label>Memory for Docker <select data-dk="memory-percent"></select></label>
        <button type="button" data-dk-action="memory">Save</button></p>
    <p class="mg-note">Docker and all its containers share this part of the NAS's memory; the rest is left for the NAS itself
        and its other apps (e.g. Plex). Leave the NAS enough: when it runs short, it starts stopping processes. A container
        that needs more than Docker's share is stopped instead.</p>

    <h3>Portainer</h3>
    <p data-dk="portainer">-</p>
    <p><a class="mg-button" data-dk="portainer-link" href="#" target="_blank" rel="noopener">Open Portainer</a>
        <button type="button" data-dk-action="restart-portainer">Restart Portainer</button></p>
    <div data-dk="setup-box" hidden>
        <p>Portainer's admin account hasn't been created yet. Its setup page asks for a setup token, and must be completed
            within a few minutes of Portainer starting (restart Portainer if it has timed out).</p>
        <p>Setup token: <code data-dk="token">••••••••••••</code> <button type="button" data-dk-action="token">Show</button>
            <button type="button" data-dk-action="copy-token">Copy</button></p>
    </div>

    <h3>Containers</h3>
    <table data-dk="containers"></table>

    <h3>Disk space</h3>
    <table data-dk="disk"><tr><td class="mg-note">…</td></tr></table>
    <p><button type="button" data-dk-action="disk">Refresh</button>
        <span class="mg-note">Unused images, containers and volumes can be removed in Portainer.</span></p>

    <p data-dk="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('docker', 'dk'); ?>
        <?php manage_secret_script(); ?>

        let memoryLoaded = false;
        let moduleStates = {
            loaded:         'loaded',
            not_built:      'not built for this model',
            wrong_firmware: 'built for another firmware',
            crashed:        'not loaded: a previous attempt never finished (the NAS may have crashed)',
            not_loaded:     'not loaded (see /tmp/debug_apkg)',
        };

        /**
         * Fills a table with a header row and rows of text ({ text, className } for a coloured cell). Container names
         * etc. come from Docker, so they're only ever set as text.
         *
         * @param {HTMLTableElement} table  The table
         * @param {Array.<string>}   header The header row's titles
         * @param {Array.<Array>}    rows   The rows
         * @param {string}           empty  What to show when there are no rows
         *
         * @return {void}
         */
        function fillTable(table, header, rows, empty) {
            table.textContent = '';

            if (!rows.length) {
                table.insertRow().insertCell().textContent = empty;

                return;
            }

            let head = table.insertRow();

            header.forEach(function (text) {
                let cell = head.insertCell();

                cell.textContent = text;
                cell.style.fontWeight = 'bold';
            });

            rows.forEach(function (values) {
                let row = table.insertRow();

                values.forEach(function (value) {
                    let cell = row.insertCell();

                    if (value && typeof value === 'object') {
                        cell.textContent = value.text;
                        cell.className   = value.className;
                    } else {
                        cell.textContent = value;
                    }
                });
            });
        }

        /**
         * A size in gigabytes, for showing.
         *
         * @param {number} bytes The size, in bytes
         *
         * @return {string} The size (e.g. 3.8 GB)
         */
        function formatGigabytes(bytes) {
            return (bytes / 1073741824).toFixed(1) + ' GB';
        }

        /**
         * Shows Docker's memory: the limit in force, what its containers use, and the shares to choose from (filled in
         * once, so a refresh doesn't undo a choice being made).
         *
         * @param {Object}         memory  The memory: total, available, percent, limit and usage (bytes)
         * @param {Array.<number>} choices The shares to offer (percentages)
         *
         * @return {void}
         */
        function showMemory(memory, choices) {
            part('memory').textContent = (memory.limit ? 'up to ' + formatGigabytes(memory.limit) + ' of the NAS\'s ' + formatGigabytes(memory.total) +
                ' (' + Math.round(100 * memory.limit / memory.total) + '%)' : formatGigabytes(memory.total) + ' in the NAS') +
                (memory.limit ? ' - containers use ' + formatGigabytes(memory.usage) : '') + ', ' + formatGigabytes(memory.available) + ' free in the NAS';

            if (memoryLoaded) {
                return;
            }

            let select = part('memory-percent');

            choices.forEach(function (percent) {
                let option = document.createElement('option');

                option.value       = percent;
                option.textContent = percent + '% (' + formatGigabytes(memory.total * percent / 100) + ')';
                option.selected    = percent === memory.percent;

                select.appendChild(option);
            });

            memoryLoaded = true;
        }

        /**
         * Shows the state of the app's kernel modules, and why one isn't loaded (with Retry if loading one never
         * finished).
         *
         * @param {Object} kernel The modules' states, the NAS's firmware and the one they were built for
         *
         * @return {void}
         */
        function showKernel(kernel) {
            let anyCrashed = false;

            part('modules').textContent = kernel.modules.map(function (module) {
                anyCrashed = anyCrashed || module.state === 'crashed';

                return module.name + ': ' + moduleStates[module.state];
            }).join(', ');

            let note = '';

            let wrongFirmware = kernel.modules.some(function (module) {
                return module.state === 'wrong_firmware';
            });

            if (wrongFirmware) {
                note = 'The modules were built for firmware ' + kernel.built_for + ', but this NAS runs ' + kernel.firmware +
                    ': rebuild the app for it to use overlay2 again.';
            } else if (anyCrashed) {
                note = 'Loading a module never finished, so it is no longer tried. Retry only if the NAS crashed for another reason.';
            }

            part('driver-note').textContent = note;
            part('driver-note').hidden      = !note;

            button('retry').hidden = !anyCrashed;
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

                status.textContent = response.restarting ? 'Restarting… (stopping every container can take a minute)' : (response.running ? 'Running' : 'Stopped');
                status.className   = response.running && !response.restarting ? 'mg-ok' : 'mg-bad';

                button('restart').disabled  = response.restarting;
                part('version').textContent = response.version || '-';

                let driver = part('driver');

                driver.textContent = response.driver ? response.driver + (response.driver === 'vfs' ? ' (every image layer is a full copy - uses much more disk space)' : '') : '-';
                driver.className   = response.driver === 'vfs' ? 'mg-bad' : '';

                showKernel(response.kernel);
                showMemory(response.memory, response.memory_choices);

                if (response.unused_driver) {
                    let note = part('driver-note');

                    note.textContent = (note.textContent ? note.textContent + ' ' : '') + 'Images stored with ' + response.unused_driver +
                        ' are still on disk but unused: delete ' + response.docker_root + '/' + response.unused_driver + ' (over SSH) to free their space.';
                    note.hidden      = false;
                }

                let portainer = part('portainer');

                portainer.textContent = response.portainer === 'running' ? 'Running on port 9000 (HTTP) and 9443 (HTTPS)' :
                    (response.portainer ? 'Not running (' + response.portainer + ')' : (response.running ? 'No Portainer container (disable and enable the app to recreate it)' : '-'));
                portainer.className   = response.portainer === 'running' ? 'mg-ok' : 'mg-bad';

                part('setup-box').hidden = response.portainer_has_admin !== false;

                fillTable(part('containers'), ['Name', 'Image', 'State', 'Ports'], response.containers.map(function (container) {
                    return [container.name, container.image, { text: container.status || container.state, className: container.state === 'running' ? 'mg-ok' : 'mg-note' }, container.ports];
                }), response.running ? 'No containers' : '-');
            });
        }

        /**
         * Shows Docker's disk use: images, containers, volumes and build cache.
         *
         * @return {void}
         */
        function refreshDisk() {
            call('disk').then(function (response) {
                if (!response.ok) {
                    fillTable(part('disk'), [], [], response.error);

                    return;
                }

                fillTable(part('disk'), ['', 'Total', 'In use', 'Size', 'Unused'], response.disk.map(function (row) {
                    return [row.type, row.count, row.active, row.size, row.reclaimable];
                }), 'No data');
            });
        }

        part('portainer-link').href = 'http://' + window.location.hostname + ':9000/';

        // Keep the page current (e.g. during a restart), until the dashboard removes it
        <?php manage_timer_script(5000); ?>

        /**
         * Restarts Docker through the API, once confirmed, and shows the status again.
         *
         * @param {Object} data     What to post (e.g. retry_modules)
         * @param {string} question What to ask first
         *
         * @return {void}
         */
        function restart(data, question) {
            if (!window.confirm(question)) {
                return;
            }

            call('restart', data).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return;
                }

                say('Docker is restarting.', true);
                refresh();
            });
        }

        button('restart').addEventListener('click', function () {
            restart({ confirm: 1 }, 'Restart Docker? Every container stops, and only those set to restart automatically start again.');
        });

        button('retry').addEventListener('click', function () {
            restart({ retry_modules: 1 }, 'Retry loading the kernel modules? Docker restarts. If loading them crashes the NAS again, they will not be tried again.');
        });

        button('memory').addEventListener('click', function () {
            let percent = part('memory-percent').value;

            call('memory', { percent: percent }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return;
                }

                say(response.applied ? 'Docker can now use ' + percent + '% of the NAS\'s memory.' :
                    'Saved - it takes effect when Docker next restarts (its containers use more than that right now, or Docker isn\'t set up yet).', response.applied);
                refresh();
            });
        });

        button('restart-portainer').addEventListener('click', function () {
            say('Restarting Portainer…', true);
            call('restart_portainer', { confirm: 1 }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return;
                }

                token.reset();
                say('Portainer restarted - it has a new setup token.', true);
                refresh();
            });
        });

        // Portainer's setup token: Show / Hide and Copy (fetched when first needed, again after Portainer restarts)
        let token = secretControls(part('token'), button('token'), button('copy-token'), function () {
            return call('setup_token', { show: 1 }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return null;
                }

                return response.token;
            });
        });

        button('disk').addEventListener('click', refreshDisk);

        refresh();
        refreshDisk();
    })();
    </script>
</div>
