<?php
// The Tasks app's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('tasks');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="tasks-manage">
    <?php manage_styles('tasks-manage'); ?>
    <style>
        #tasks-manage [data-tk="tasks"] td {
            vertical-align: top;
        }

        #tasks-manage [data-tk="tasks"] td:last-child {
            white-space: nowrap;
        }

        #tasks-manage .tk-off {
            opacity: 0.55;
        }

        #tasks-manage textarea {
            box-sizing:  border-box;
            width:       100%;
            min-height:  18rem;
            padding:     0.5rem;
            font-family: Consolas, Menlo, monospace;
            font-size:   13px;
            line-height: 1.45;
            white-space: pre;
            tab-size:    4;
        }

        #tasks-manage input[type=time] {
            box-sizing:       border-box;
            height:           32px;
            padding:          0 6px;
            border:           1px solid #c8c8c8;
            background-color: #f0f0f0;
            font:             14px Arial, Helvetica, sans-serif;
            vertical-align:   middle;
        }

        #tasks-manage input[type=number] {
            width: 5rem;
        }

        #tasks-manage [data-tk="editor"] {
            margin:     1rem 0;
            padding:    0.25rem 1rem 0.5rem;
            border:     1px solid rgba(127, 127, 127, 0.3);
            background: rgba(127, 127, 127, 0.05);
        }

        #tasks-manage [data-tk="output"],
        #tasks-manage [data-tk="history"] {
            max-height: 24rem;
            overflow:   auto;
        }
    </style>

    <h2>Tasks</h2>
    <p data-tk="state">…</p>
    <p class="mg-note">Your own scripts, run by the NAS: at boot, on a schedule, when it shuts down or when you click Run
        now. They run as root (the NAS's administrator), so a script can change anything on the NAS - only add scripts
        you understand. Entware's programs (<code>/opt/bin</code>) can be used too.</p>

    <table data-tk="tasks"></table>
    <p><button type="button" data-tk-action="add">Add a task</button></p>

    <div data-tk="editor" hidden>
        <h4 data-tk="editor-title">New task</h4>
        <p><label>Name <input type="text" data-tk="name" maxlength="60" placeholder="e.g. Nightly copy to USB"></label></p>
        <p><label>Runs <select data-tk="trigger">
            <option value="schedule">On a schedule</option>
            <option value="boot">At boot</option>
            <option value="shutdown">When the NAS shuts down or restarts</option>
            <option value="manual">Only when run from this page</option>
        </select></label></p>
        <p data-tk="schedule-row">
            <label><select data-tk="every">
                <option value="hour">Every hour</option>
                <option value="day">Every day</option>
                <option value="week">Every week</option>
                <option value="month">Every month</option>
                <option value="custom">Custom (cron)</option>
            </select></label>
            <label data-tk="minute-box">at minute <input type="number" data-tk="minute" min="0" max="59" value="0"></label>
            <label data-tk="weekday-box">on <select data-tk="weekday">
                <option value="1">Monday</option>
                <option value="2">Tuesday</option>
                <option value="3">Wednesday</option>
                <option value="4">Thursday</option>
                <option value="5">Friday</option>
                <option value="6">Saturday</option>
                <option value="0">Sunday</option>
            </select></label>
            <label data-tk="monthday-box">on day <input type="number" data-tk="monthday" min="1" max="31" value="1"></label>
            <label data-tk="time-box">at <input type="time" data-tk="time" value="03:00"></label>
            <label data-tk="cron-box"><input type="text" data-tk="cron" spellcheck="false" placeholder="30 2 * * *"></label>
        </p>
        <p class="mg-note" data-tk="cron-note">Cron's five parts: minute, hour, day of the month, month and day of the week
            (0 is Sunday), each <code>*</code>, a number, a range (<code>1-5</code>), a list (<code>0,30</code>) or a step
            (<code>*/15</code>). In the NAS's time zone.</p>
        <p class="mg-note" data-tk="trigger-note"></p>
        <p><label>Script</label><br>
            <textarea data-tk="script" spellcheck="false" placeholder="#!/bin/sh&#10;echo 'Hello from the NAS'"></textarea></p>
        <p class="mg-note">A shell script (BusyBox <code>sh</code>), or any program's script with its own first line
            (<code>#!/opt/bin/python3</code>...). Exit with a code other than 0 to say it failed. It gets
            <code>TASK_ID</code>, <code>TASK_NAME</code> and <code>TASK_REASON</code> (boot, schedule, shutdown or manual).</p>
        <p><label>Stop it after <input type="number" data-tk="timeout" min="1" max="1440" value="30"> minutes</label>
            <label>Tell ntfy <select data-tk="notify">
                <option value="failed">When it fails</option>
                <option value="always">Every run</option>
                <option value="never">Never</option>
            </select></label>
            <label><input type="checkbox" data-tk="enabled" checked> Switched on</label></p>
        <p><button type="button" data-tk-action="save">Save</button>
            <button type="button" data-tk-action="cancel">Cancel</button></p>
    </div>

    <details class="mg-section" data-tk="output-box" hidden>
        <summary data-tk="output-title">The task's last run</summary>
        <pre data-tk="output"></pre>
    </details>

    <h3>Notifications</h3>
    <div data-tk="ntfy-on" hidden>
        <p><label>ntfy topic <input type="text" data-tk="topic" spellcheck="false" placeholder="e.g. nas"></label>
            <button type="button" data-tk-action="settings">Save</button></p>
        <p class="mg-note">Tasks tell this topic of the ntfy app how their runs went, as each one asks (subscribe to it in
            the ntfy app on your phone). Leave it empty for no messages.</p>
    </div>
    <p data-tk="ntfy-off" class="mg-note" hidden>Install the ntfy app to be told on your phone when a task fails.</p>

    <details class="mg-section">
        <summary>Recent runs</summary>
        <pre data-tk="history"></pre>
    </details>

    <p data-tk="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('tasks', 'tk'); ?>

        let loaded  = false;
        let editing = '';
        let days    = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

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
         * A time of day, as the page says it.
         *
         * @param {string|number} hour   The hour
         * @param {string|number} minute The minute
         *
         * @return {string} e.g. 02:30
         */
        function clock(hour, minute) {
            return `${String(hour).padStart(2, '0')}:${String(minute).padStart(2, '0')}`;
        }

        /**
         * Reads a schedule the page's own choices can show (every hour, day, week or month), else it's custom.
         *
         * @param {string} cron The schedule (cron's five parts)
         *
         * @return {Object} every (hour, day, week, month or custom), and the minute, hour, weekday and day of the month
         */
        function readCron(cron) {
            let parts = cron.trim().split(/\s+/);
            let plain = function (value) {
                return /^[0-9]{1,2}$/.test(value);
            };

            if (parts.length === 5 && plain(parts[0]) && parts[2] === '*' && parts[3] === '*') {
                if (parts[1] === '*' && parts[4] === '*') {
                    return { every: 'hour', minute: parts[0] };
                }

                if (plain(parts[1]) && parts[4] === '*') {
                    return { every: 'day', minute: parts[0], hour: parts[1] };
                }

                if (plain(parts[1]) && /^[0-6]$/.test(parts[4])) {
                    return { every: 'week', minute: parts[0], hour: parts[1], weekday: parts[4] };
                }
            }

            if (parts.length === 5 && plain(parts[0]) && plain(parts[1]) && plain(parts[2]) && parts[3] === '*' && parts[4] === '*') {
                return { every: 'month', minute: parts[0], hour: parts[1], monthday: parts[2] };
            }

            return { every: 'custom' };
        }

        /**
         * When a task runs, as the page says it.
         *
         * @param {Object} task The task
         *
         * @return {string} When
         */
        function when(task) {
            let triggers = {
                boot:     'At boot',
                shutdown: 'When the NAS shuts down or restarts',
                manual:   'Only when run from this page'
            };

            if (task.trigger !== 'schedule') {
                return triggers[task.trigger];
            }

            let cron  = readCron(task.schedule);
            let parts = task.schedule.split(/\s+/);
            let says  = {
                hour:   `Every hour, at minute ${cron.minute}`,
                day:    `Every day at ${clock(cron.hour, cron.minute)}`,
                week:   `Every ${days[cron.weekday]} at ${clock(cron.hour, cron.minute)}`,
                month:  `On day ${parts[2]} of every month at ${clock(cron.hour, cron.minute)}`,
                custom: `On the schedule ${task.schedule}`
            };

            return says[cron.every];
        }

        /**
         * A task's last run, as the page says it.
         *
         * @param {Object} status Its state, why it ran, when it started and finished (seconds since 1970), its exit code
         *
         * @return {string} How it went
         */
        function lastRun(status) {
            if (!status.state) {
                return 'Never run';
            }

            let started  = new Date(status.started * 1000).toLocaleString();
            let finished = new Date(status.finished * 1000).toLocaleString();
            let seconds  = status.finished - status.started;
            let names    = {
                running:     `Running since ${started}`,
                ok:          `Done ${finished} (${seconds} s)`,
                failed:      `Failed ${finished} (exit code ${status.code})`,
                timeout:     `Stopped ${finished}: over its time limit`,
                interrupted: `Interrupted (started ${started})`
            };

            return names[status.state] || status.state;
        }

        /**
         * Shows the schedule's parts that its choice needs, and what the trigger means.
         *
         * @return {void}
         */
        function showChoices() {
            let trigger  = part('trigger').value;
            let every    = part('every').value;
            let needs    = {
                hour:   ['minute-box'],
                day:    ['time-box'],
                week:   ['weekday-box', 'time-box'],
                month:  ['monthday-box', 'time-box'],
                custom: ['cron-box']
            };
            let notes    = {
                schedule: '',
                boot:     'It runs once each time the NAS starts, after the apps before it (not when this app is switched on or updated).',
                shutdown: 'It runs when the NAS is shutting down or restarting, before its apps stop - keep it short: the NAS doesn\'t wait long.',
                manual:   'It only runs when you click Run now.'
            };

            part('schedule-row').hidden = trigger !== 'schedule';
            part('cron-note').hidden    = trigger !== 'schedule' || every !== 'custom';
            part('trigger-note').hidden = notes[trigger] === '';

            part('trigger-note').textContent = notes[trigger];

            ['minute-box', 'weekday-box', 'monthday-box', 'time-box', 'cron-box'].forEach(function (name) {
                part(name).hidden = needs[every].indexOf(name) === -1;
            });
        }

        /**
         * The schedule the editor's choices make (cron's five parts).
         *
         * @return {string} The schedule
         */
        function chosenCron() {
            let time   = (part('time').value || '00:00').split(':');
            let hour   = String(Number(time[0]));
            let minute = String(Number(time[1]));
            let makes  = {
                hour:   `${Number(part('minute').value)} * * * *`,
                day:    `${minute} ${hour} * * *`,
                week:   `${minute} ${hour} * * ${part('weekday').value}`,
                month:  `${minute} ${hour} ${Number(part('monthday').value)} * *`,
                custom: part('cron').value.trim()
            };

            return makes[part('every').value];
        }

        /**
         * Opens the editor for a new task, or for one of the tasks (its script fetched first).
         *
         * @param {Object|null} task The task (null for a new one)
         *
         * @return {void}
         */
        function openEditor(task) {
            let fill = function (script) {
                let cron = readCron(task ? task.schedule : '0 3 * * *');

                editing = task ? task.id : '';

                part('editor-title').textContent = task ? `Change ${task.name}` : 'New task';
                part('name').value               = task ? task.name : '';
                part('trigger').value            = task ? task.trigger : 'schedule';
                part('every').value              = cron.every;
                part('minute').value             = cron.minute || '0';
                part('weekday').value            = cron.weekday || '1';
                part('monthday').value           = cron.monthday || '1';
                part('time').value               = clock(cron.hour || 3, cron.minute || 0);
                part('cron').value               = task ? task.schedule : '';
                part('script').value             = script;
                part('timeout').value            = task ? task.timeout : 30;
                part('notify').value             = task ? task.notify : 'failed';
                part('enabled').checked          = task ? task.enabled : true;
                part('editor').hidden            = false;

                showChoices();
                part('editor').scrollIntoView({ block: 'start', behavior: 'smooth' });
                part('name').focus({ preventScroll: true });
            };

            if (!task) {
                fill('#!/bin/sh\n');

                return;
            }

            call('script', { id: task.id }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return;
                }

                fill(response.script);
            });
        }

        /**
         * Shows a task's last run's output.
         *
         * @param {Object} task The task
         *
         * @return {void}
         */
        function showOutput(task) {
            call('output', { id: task.id }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return;
                }

                let text = response.output.length ? response.output.join('\n') : 'Nothing was printed';

                part('output-title').textContent = `${task.name}: its last run`;
                part('output').textContent       = (response.cut ? '(its last 300 lines)\n' : '') + text;
                part('output-box').hidden        = false;
                part('output-box').open          = true;
            });
        }

        /**
         * Shows the tasks, each with its actions.
         *
         * @param {Array.<Object>} tasks The tasks, with their last runs
         *
         * @return {void}
         */
        function fillTasks(tasks) {
            let table = part('tasks');

            table.textContent = '';

            if (!tasks.length) {
                table.insertRow().insertCell().textContent = 'No tasks yet.';

                return;
            }

            tasks.forEach(function (task) {
                let row  = table.insertRow();
                let what = row.insertCell();

                row.className = task.enabled ? '' : 'tk-off';

                what.appendChild(element('b', task.name));
                what.appendChild(element('br', ''));
                what.appendChild(document.createTextNode(task.enabled ? when(task) : `Switched off (${when(task).toLowerCase()})`));

                let state  = row.insertCell();
                let status = task.running ? { state: 'running', started: task.status.started } : task.status;

                state.textContent = lastRun(status);
                state.className   = ['failed', 'timeout', 'interrupted'].indexOf(status.state) !== -1 ? 'mg-bad' : (status.state === 'ok' ? 'mg-ok' : '');

                let actions = row.insertCell();
                let run     = element('button', task.running ? 'Stop' : 'Run now');
                let output  = element('button', 'Output');
                let change  = element('button', 'Change');
                let toggle  = element('button', task.enabled ? 'Switch off' : 'Switch on');
                let remove  = element('button', 'Remove');

                output.disabled = !status.state;

                [run, output, change, toggle, remove].forEach(function (item) {
                    actions.appendChild(item);
                    actions.appendChild(document.createTextNode(' '));
                });

                run.addEventListener('click', function () {
                    if (task.running) {
                        if (window.confirm(`Stop ${task.name} (and what it started)?`)) {
                            act('stop', { id: task.id }, `Stopping ${task.name}…`, `${task.name} stopped.`);
                        }

                        return;
                    }

                    act('run', { id: task.id }, `Starting ${task.name}…`, `${task.name} started.`);
                });

                output.addEventListener('click', function () {
                    showOutput(task);
                });

                change.addEventListener('click', function () {
                    openEditor(task);
                });

                toggle.addEventListener('click', function () {
                    act('enable', { id: task.id, enabled: task.enabled ? '0' : '1' }, 'Saving…',
                        `${task.name} switched ${task.enabled ? 'off' : 'on'}.`);
                });

                remove.addEventListener('click', function () {
                    if (window.confirm(`Remove the task ${task.name} and its script?`)) {
                        act('delete', { id: task.id }, 'Removing…', 'Removed.');
                    }
                });
            });
        }

        /**
         * Loads the tasks from the API and shows them.
         *
         * @return {Promise} Done once they're shown
         */
        function refresh() {
            return call('status').then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return;
                }

                let state = part('state');

                state.textContent = response.active
                    ? 'On: switched-on tasks run by themselves.'
                    : 'Switched off on the NAS\'s Apps page: no task runs by itself (Run now still works).';
                state.className   = response.active ? 'mg-ok' : 'mg-bad';

                fillTasks(response.tasks);

                part('ntfy-on').hidden  = !response.ntfy.installed;
                part('ntfy-off').hidden = response.ntfy.installed;

                if (!loaded) {
                    part('topic').value = response.ntfy.topic;

                    loaded = true;
                }

                part('history').textContent = response.history.length ? response.history.join('\n') : 'No runs yet';
            });
        }

        // Keep the page current, until the dashboard removes it
        <?php manage_timer_script(10000); ?>
        <?php manage_act_script(); ?>

        part('trigger').addEventListener('change', showChoices);
        part('every').addEventListener('change', showChoices);

        // Tab indents in the script, rather than leaving the box
        part('script').addEventListener('keydown', function (event) {
            if (event.key !== 'Tab' || event.shiftKey) {
                return;
            }

            let box   = event.target;
            let start = box.selectionStart;

            event.preventDefault();
            box.value = box.value.slice(0, start) + '    ' + box.value.slice(box.selectionEnd);

            box.selectionStart = box.selectionEnd = start + 4;
        });

        button('add').addEventListener('click', function () {
            openEditor(null);
        });

        button('cancel').addEventListener('click', function () {
            part('editor').hidden = true;
        });

        button('save').addEventListener('click', function () {
            let trigger = part('trigger').value;

            act('save', {
                id:       editing,
                name:     part('name').value,
                trigger:  trigger,
                schedule: trigger === 'schedule' ? chosenCron() : '',
                script:   part('script').value,
                timeout:  part('timeout').value,
                notify:   part('notify').value,
                enabled:  part('enabled').checked ? '1' : '0'
            }, 'Saving…', 'Saved.').then(function (response) {
                if (response) {
                    part('editor').hidden = true;
                }
            });
        });

        button('settings').addEventListener('click', function () {
            act('settings', { topic: part('topic').value }, 'Saving…', 'Saved.');
        });

        refresh();
    })();
    </script>
</div>
