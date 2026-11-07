<?php
// rclone's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('rclone');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="rclone-manage">
    <?php manage_styles('rclone-manage'); ?>
    <style>
        #rclone-manage [data-rc="jobs"] td { vertical-align: top; }
        #rclone-manage [data-rc="job-log"] { max-height: 20rem; overflow: auto; }
    </style>

    <h2>rclone</h2>
    <table>
        <tr><td>Status</td><td data-rc="status">…</td></tr>
        <tr><td>Version</td><td data-rc="version">-</td></tr>
        <tr><td>Address</td><td data-rc="address">-</td></tr>
    </table>
    <p><a class="mg-button" data-rc="link" href="#" target="_blank" rel="noopener">Open rclone</a>
        <button type="button" data-rc-action="restart">Restart rclone</button></p>

    <h3>Logging in</h3>
    <p>User name <code>admin</code>, password <code data-rc="password">••••••••••••</code>
        <button type="button" data-rc-action="show">Show</button> <button type="button" data-rc-action="copy">Copy</button>
        <button type="button" data-rc-action="new-password">New password</button></p>
    <p class="mg-note">Your browser asks for it first, then rclone's own login page (its address is filled in). In rclone,
        set up your cloud storage under Remotes - for Google Drive, OneDrive, Dropbox and the like, rclone shows how to let
        it in.</p>

    <h3>Remotes</h3>
    <p data-rc="remotes">-</p>

    <h3>Jobs</h3>
    <table data-rc="jobs"></table>
    <p><label>Name <input type="text" data-rc="job-name" size="20" placeholder="e.g. Photos to the cloud"></label>
        <label><select data-rc="job-mode">
            <option value="copy">Copy</option>
            <option value="sync">Sync (mirror)</option>
        </select></label></p>
    <p><label>From <input type="text" data-rc="job-source" size="40" spellcheck="false" placeholder="/mnt/HD/HD_a2/Public/Photos"></label>
        <label>to <input type="text" data-rc="job-destination" size="30" spellcheck="false" placeholder="gdrive:Backups/Photos"></label></p>
    <p><label>Runs <select data-rc="job-hour"></select></label>
        <button type="button" data-rc-action="add-job">Add job</button></p>
    <p class="mg-note">Each end is a folder in the NAS's shares (<code>/mnt/HD/HD_a2/...</code>) or a remote's folder
        (<code>name:path</code>), either way round. <b>Copy</b> adds and updates files, never deleting any. <b>Sync</b>
        makes the destination the same as the source - <b>deleting what isn't in the source</b>. Jobs run as rclone's own
        user, which can use the shares.</p>
    <details class="mg-section" data-rc="job-log-box" hidden>
        <summary data-rc="job-log-title">The job's last run</summary>
        <pre data-rc="job-log"></pre>
    </details>

    <h3>Settings</h3>
    <p><label><input type="checkbox" data-rc="local"> Only through the Nginx app (HTTPS)</label>
        <button type="button" data-rc-action="settings">Save</button></p>
    <p class="mg-note">Its web interface restarts (jobs carry on).</p>

    <details class="mg-section">
        <summary>rclone's log</summary>
        <pre data-rc="log"></pre>
    </details>

    <p data-rc="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('rclone', 'rc'); ?>
        <?php manage_secret_script(); ?>

        let loaded = false;

        /**
         * Makes an element, with its text (set as text).
         *
         * @param {string} tag  Its tag
         * @param {string} text Its text ('' for none)
         *
         * @return {HTMLElement} The element
         */
        function element(tag, text) {
            let node = document.createElement(tag);

            if (text) {
                node.textContent = text;
            }

            if (tag === 'button') {
                node.type = 'button';
            }

            return node;
        }

        /**
         * When a job runs, as the page says it.
         *
         * @param {number} hour The hour (-1: only when run from this page)
         *
         * @return {string} When
         */
        function when(hour) {
            return hour < 0 ? 'When run from this page' : `Daily at ${String(hour).padStart(2, '0')}:00`;
        }

        /**
         * A job's last run, as the page says it.
         *
         * @param {Object} status Its state, and when it started and finished (seconds since 1970)
         *
         * @return {string} How it went
         */
        function lastRun(status) {
            if (!status.state) {
                return 'Never run';
            }

            let started = new Date(status.started * 1000).toLocaleString();
            let names   = {
                running:     `Running since ${started}`,
                ok:          `Done ${new Date(status.finished * 1000).toLocaleString()}`,
                failed:      `Failed ${new Date(status.finished * 1000).toLocaleString()}`,
                interrupted: `Interrupted (started ${started})`
            };

            return names[status.state] || status.state;
        }

        /**
         * Shows the jobs, each with Run now, its last run's log and Remove.
         *
         * @param {Array.<Object>} jobs The jobs, with their last runs
         *
         * @return {void}
         */
        function fillJobs(jobs) {
            let table = part('jobs');

            table.textContent = '';

            if (!jobs.length) {
                table.insertRow().insertCell().textContent = 'No jobs yet.';

                return;
            }

            jobs.forEach(function (job) {
                let row  = table.insertRow();
                let what = row.insertCell();

                what.appendChild(element('b', job.name));
                what.appendChild(element('br', ''));
                what.appendChild(document.createTextNode(`${job.mode === 'sync' ? 'Sync' : 'Copy'} ${job.source} → ${job.destination}`));
                what.appendChild(element('br', ''));
                what.appendChild(document.createTextNode(when(job.hour)));

                let state = row.insertCell();

                state.textContent = lastRun(job.status);
                state.className   = job.status.state === 'failed' || job.status.state === 'interrupted' ? 'mg-bad' : (job.status.state === 'ok' ? 'mg-ok' : '');

                let actions = row.insertCell();
                let run     = element('button', 'Run now');
                let log     = element('button', 'Log');
                let remove  = element('button', 'Remove');

                run.disabled = job.status.state === 'running';

                [run, log, remove].forEach(function (item) {
                    actions.appendChild(item);
                    actions.appendChild(document.createTextNode(' '));
                });

                run.addEventListener('click', function () {
                    act('run_job', { id: job.id }, `Starting ${job.name}…`, `${job.name} started.`);
                });

                log.addEventListener('click', function () {
                    call('job_log', { id: job.id }).then(function (response) {
                        if (!response.ok) {
                            say(response.error, false);

                            return;
                        }

                        part('job-log-title').textContent = `${job.name}: its last run`;
                        part('job-log').textContent       = response.log.length ? response.log.join('\n') : 'Nothing logged';
                        part('job-log-box').hidden        = false;
                        part('job-log-box').open          = true;
                    });
                });

                remove.addEventListener('click', function () {
                    if (window.confirm(`Remove the job ${job.name}? (Nothing it copied is touched.)`)) {
                        act('delete_job', { id: job.id }, 'Removing…', 'Removed.');
                    }
                });
            });
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

                const status  = part('status');
                const url     = response.site.url || (response.listen === 'local' ? '' : response.address);
                const remotes = Object.keys(response.remotes);

                status.textContent = !response.running ? 'Stopped' : (response.answering ? 'Running' : 'Starting…');
                status.className   = response.running && response.answering ? 'mg-ok' : 'mg-bad';

                part('version').textContent = response.version || '-';
                part('address').textContent = [response.site.url, response.listen === 'local' ? '' : response.address].filter(Boolean).join(' and ') || '-';
                // Its login page, with its own address filled in (the interface calls rclone's API there)
                part('link').href           = url ? `${url}login/?${new URLSearchParams({ url: url, user: 'admin' }).toString()}` : '#';
                part('remotes').textContent = remotes.length
                    ? remotes.map(function (name) {
                        return `${name} (${response.remotes[name] || '?'})`;
                    }).join(', ')
                    : 'None yet: set them up in rclone (or with rclone config over SSH).';

                fillJobs(response.jobs);

                if (!loaded) {
                    part('local').checked = response.listen === 'local';

                    loaded = true;
                }

                part('log').textContent = response.log.length ? response.log.join('\n') : 'Nothing logged';
            });
        }

        // Keep the page current, until the dashboard removes it
        <?php manage_timer_script(); ?>
        <?php manage_act_script(); ?>

        // The hours a job can run at
        let hours = part('job-hour');

        hours.appendChild(new Option('When run from this page', '-1'));

        for (let hour = 0; hour < 24; hour++) {
            hours.appendChild(new Option(when(hour), String(hour)));
        }

        hours.value = '2';

        button('restart').addEventListener('click', function () {
            act('restart', { confirm: 1 }, 'Restarting rclone…', 'rclone restarted.');
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
            if (!window.confirm('Make a new password? rclone\'s web interface restarts.')) {
                return;
            }

            act('new_password', { confirm: 1 }, 'Making a new password…', 'New password in use.').then(function (response) {
                if (response) {
                    password.set(response.password);
                }
            });
        });

        button('add-job').addEventListener('click', function () {
            act('add_job', {
                name:        part('job-name').value,
                mode:        part('job-mode').value,
                source:      part('job-source').value,
                destination: part('job-destination').value,
                hour:        part('job-hour').value
            }, 'Adding the job…', 'Job added.').then(function (response) {
                if (response) {
                    ['job-name', 'job-source', 'job-destination'].forEach(function (name) {
                        part(name).value = '';
                    });
                }
            });
        });

        button('settings').addEventListener('click', function () {
            act('settings', { listen: part('local').checked ? 'local' : 'all' }, 'Saving…', 'Saved - rclone restarted.');
        });

        refresh();
    })();
    </script>
</div>
