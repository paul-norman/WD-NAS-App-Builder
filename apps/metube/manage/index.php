<?php
// MeTube's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('metube');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="metube-manage">
    <?php manage_styles('metube-manage'); ?>

    <h2>MeTube</h2>
    <table>
        <tr><td>Status</td><td data-mt="status">…</td></tr>
        <tr><td>Versions</td><td data-mt="version">-</td></tr>
        <tr><td>Watch page</td><td data-mt="address">-</td></tr>
    </table>
    <p><a class="mg-button" data-mt="link" href="#" target="_blank" rel="noopener">Open the Watch page</a>
        <button type="button" data-mt-action="restart">Restart</button></p>
    <p data-mt="top-message"></p>
    <p class="mg-note">Everyone in the household downloads and watches on the Watch page, each with their own videos
        (in their own folder) and their own clean-up. MeTube itself is never shown: its own page lists everyone's downloads.</p>

    <h3>People</h3>
    <table data-mt="users"></table>
    <p><input type="text" data-mt="name" placeholder="Name (e.g. alex)" autocomplete="off" spellcheck="false">
        <input type="text" data-mt="password" placeholder="Password (leave empty to generate one)" autocomplete="off" spellcheck="false">
        <button type="button" data-mt-action="add">Add</button></p>
    <p data-mt="users-message"></p>
    <p class="mg-note">Names are lower-case letters, digits and . _ - ; passwords are 8-128 characters (letters, digits,
        symbols or spaces). A password is shown once, when it's set.</p>
    <p data-mt="shown" hidden>Password for <strong data-mt="shown-name"></strong>: <code data-mt="shown-password"></code>
        <button type="button" data-mt-action="copy">Copy</button></p>

    <h3>Download folder</h3>
    <p><input type="text" data-mt="folder" size="50" spellcheck="false" placeholder="/mnt/HD/HD_a2/Public/Watch Later">
        <button type="button" data-mt-action="folder">Save</button></p>
    <p data-mt="folder-message"></p>
    <p class="mg-note">Each person's videos go into a folder of their own in it (e.g. Watch Later/alex), with a thumbnail
        beside each. It must be in a share (it's made if missing); MeTube restarts. <span data-mt="folder-state"></span></p>

    <h3>Clean-up</h3>
    <p>Delete a video <input type="number" data-mt="watched-days" min="0" max="3650" style="width: 5em"> days after it was
        last watched, or <input type="number" data-mt="unwatched-days" min="0" max="3650" style="width: 5em"> days after
        downloading if never watched (0: never). <button type="button" data-mt-action="cleanup">Save</button></p>
    <p data-mt="cleanup-message"></p>
    <p class="mg-note">The defaults: each person can change their own on the Watch page, and keep any video.</p>

    <h3>Media server (optional)</h3>
    <p class="mg-note">To watch on a TV, add the download folder to Plex, Jellyfin or Emby as a library - the whole folder
        (one library for a shared TV account), or each person's folder as their own library (private). Connected here, the
        Watch page also counts what was watched there (by any of its accounts), for the clean-up. Nothing is changed in the
        media server.</p>
    <p><select data-mt="server-type">
            <option value="">None</option>
            <option value="plex">Plex</option>
            <option value="jellyfin">Jellyfin</option>
            <option value="emby">Emby</option>
        </select>
        <input type="text" data-mt="server-url" size="30" placeholder="http://127.0.0.1:32400" spellcheck="false">
        <input type="password" data-mt="server-token" size="24" placeholder="Token / API key" autocomplete="off"></p>
    <details>
        <summary>A media server on another machine</summary>
        <p>The download folder as it sees it: <input type="text" data-mt="path-from" size="30" spellcheck="false" placeholder="e.g. /media/Watch Later">
            is this NAS's <input type="text" data-mt="path-to" size="30" spellcheck="false" placeholder="/mnt/HD/HD_a2/Public/Watch Later"></p>
    </details>
    <p><button type="button" data-mt-action="server-test">Test</button>
        <button type="button" data-mt-action="server-save">Save</button></p>
    <p data-mt="server-message"></p>
    <p class="mg-note">Plex: its token (Plex's support article "Finding an authentication token"). Jellyfin / Emby:
        Dashboard → API Keys → new key. The key is kept on the NAS and never shown again (leave it empty to keep it).</p>

    <h3>yt-dlp (the downloader)</h3>
    <p><label><input type="checkbox" data-mt="ytdlp-auto"> Update it every night (YouTube changes often, and older
        versions stop working)</label> <button type="button" data-mt-action="ytdlp-save">Save</button>
        <button type="button" data-mt-action="ytdlp-now">Update now</button></p>
    <p data-mt="ytdlp-message"></p>
    <p class="mg-note" data-mt="ytdlp-status"></p>

    <h3>Access</h3>
    <p><label><input type="checkbox" data-mt="local"> Only through the Nginx app (HTTPS)</label>
        <button type="button" data-mt-action="listen">Save</button></p>
    <p data-mt="access-message"></p>
    <p class="mg-note">Otherwise the Watch page is also reachable on port 8086 from the local network, over plain HTTP.
        Both restart.</p>

    <details class="mg-section">
        <summary>Latest warnings</summary>
        <pre data-mt="log"></pre>
    </details>

    <p data-mt="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('metube', 'mt'); ?>
        <?php manage_secret_script(); ?>

        let loaded     = false;
        let shown      = '';
        let siteStates = {
            no_nginx:  'the Nginx app isn\'t set up',
            no_domain: 'set a domain in the Nginx app',
            off:       'switched off in the Nginx app'
        };

        /**
         * Shows a password just set, once (it isn't kept).
         *
         * @param {Object} response The API's answer: the user's name and password
         *
         * @return {void}
         */
        function showPassword(response) {
            shown = response.password;

            part('shown-name').textContent     = response.name;
            part('shown-password').textContent = response.password;
            part('shown').hidden               = false;
        }

        /**
         * Lists the people, each with their number of videos and New password / Remove buttons.
         *
         * @param {Object[]} users Their names and video counts
         *
         * @return {void}
         */
        function showUsers(users) {
            let table = part('users');

            table.textContent = '';

            if (!users.length) {
                table.insertRow().insertCell().textContent = 'Nobody yet - add the household\'s members below.';

                return;
            }

            users.forEach(function (user) {
                let row      = table.insertRow();
                let renew    = document.createElement('button');
                let remove   = document.createElement('button');
                let controls;

                row.insertCell().textContent = user.name;
                row.insertCell().textContent = user.videos + (user.videos === 1 ? ' video' : ' videos');
                controls = row.insertCell();

                renew.type         = 'button';
                renew.textContent  = 'New password';
                remove.type        = 'button';
                remove.textContent = 'Remove';

                renew.addEventListener('click', function () {
                    actAt('users-message', 'new_password', { name: user.name }, 'Saving…', `New password for ${user.name} (shown below).`).then(function (response) {
                        if (response) {
                            showPassword(response);
                        }
                    });
                });

                remove.addEventListener('click', function () {
                    if (!window.confirm(`Remove ${user.name}?`)) {
                        return;
                    }

                    let videos = user.videos > 0 && window.confirm(`Delete ${user.name}'s ${user.videos} videos too? (Cancel keeps them in their folder.)`);

                    actAt('users-message', 'remove_user', { name: user.name, delete_videos: videos ? 1 : '' }, 'Removing…', `${user.name} removed.`);
                });

                controls.appendChild(renew);
                controls.appendChild(document.createTextNode(' '));
                controls.appendChild(remove);
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

                let status = part('status');
                let good   = response.running && response.answering && response.watch;

                status.textContent = good ? 'Running' : (!response.folder_ok ? 'Waiting for a download folder' :
                    'MeTube ' + (response.answering ? 'running' : 'stopped') + ', the Watch page ' + (response.watch ? 'running' : 'stopped'));
                status.className   = good ? 'mg-ok' : 'mg-bad';

                part('version').textContent = `MeTube ${response.version || '?'}, yt-dlp ${response.ytdlp || '?'}`;

                // The Watch page's addresses: the Nginx app's (HTTPS), and port 8086 on the local network unless only
                // through the Nginx app
                let addresses = [];

                if (response.site.url) {
                    addresses.push(response.site.url);
                }

                if (response.listen === 'all') {
                    addresses.push('http://' + window.location.hostname + ':8086/');
                }

                part('address').textContent = (addresses.join(' and ') || 'none - turn off "Only through the Nginx app", or set the Nginx app up') +
                    (response.site.url ? '' : ' (HTTPS: ' + siteStates[response.site.state] + ')');
                part('address').className   = addresses.length ? '' : 'mg-bad';
                part('link').hidden         = !addresses.length;
                part('link').href           = addresses[0] || '#';

                part('folder-state').textContent = response.download_dir === '' ? 'None is set yet.' :
                    (response.folder_ok ? '' : 'It doesn\'t exist yet.');
                part('ytdlp-status').textContent = response.ytdlp_status ? `Last update: ${response.ytdlp_status}` : 'Not updated yet (the packaged version is in use).';

                // The settings, once (not while being changed)
                if (!loaded) {
                    part('local').checked            = response.listen === 'local';
                    part('folder').value             = response.download_dir;
                    part('watched-days').value       = response.watched_days;
                    part('unwatched-days').value     = response.unwatched_days;
                    part('ytdlp-auto').checked       = response.ytdlp_update;
                    part('server-type').value        = response.media_server.type;
                    part('server-url').value         = response.media_server.url;
                    part('server-token').placeholder = response.media_server.token_set ? 'Saved (leave empty to keep)' : 'Token / API key';
                    part('path-from').value          = response.media_server.path_from;
                    part('path-to').value            = response.media_server.path_to;

                    loaded = true;
                }

                showUsers(response.users);

                part('log').textContent = response.log.length ? response.log.join('\n') : 'Nothing logged';
            });
        }

        /**
         * The media server's settings, as the page has them.
         *
         * @return {Object} Its type, address, token and path mapping
         */
        function server() {
            return {
                type:      part('server-type').value,
                url:       part('server-url').value.trim(),
                token:     part('server-token').value.trim(),
                path_from: part('path-from').value.trim(),
                path_to:   part('path-to').value.trim()
            };
        }

        // Keep the page current, until the dashboard removes it
        <?php manage_timer_script(); ?>

        /**
         * Runs one of the API's actions as act() does, but says how it went in the page's section that asked for it
         * (where the person is looking), not at the bottom of the page.
         *
         * @param {string} where   The section's message part (e.g. users-message)
         * @param {string} action  The API's action
         * @param {Object} data    What to post
         * @param {string} working What to say meanwhile
         * @param {string} done    What to say once it's done
         *
         * @return {Promise.<(Object|null)>} Its answer (null if it failed)
         */
        function actAt(where, action, data, working, done) {
            say(working, true, where);

            return call(action, data).then(function (response) {
                if (!response.ok) {
                    say(response.error, false, where);

                    return null;
                }

                say(done, true, where);
                setTimeout(refresh, 2000);

                return response;
            });
        }

        button('restart').addEventListener('click', function () {
            actAt('top-message', 'restart', { confirm: 1 }, 'Restarting…', 'Restarted.');
        });

        button('add').addEventListener('click', function () {
            let name = part('name').value.trim();

            actAt('users-message', 'add_user', { name: name, password: part('password').value.trim() }, `Adding ${name}…`, `${name} added (their password is shown below).`).then(function (response) {
                if (response) {
                    showPassword(response);

                    part('name').value     = '';
                    part('password').value = '';
                }
            });
        });

        button('copy').addEventListener('click', function () {
            copyText(shown).then(function (copied) {
                say(copied ? 'Password copied.' : 'Could not copy - select it instead.', copied, 'users-message');
            });
        });

        button('folder').addEventListener('click', function () {
            actAt('folder-message', 'folder', { folder: part('folder').value.trim() }, 'Saving (MeTube restarts)…', 'Download folder saved.');
        });

        button('cleanup').addEventListener('click', function () {
            actAt('cleanup-message', 'cleanup', { watched_days: part('watched-days').value, unwatched_days: part('unwatched-days').value }, 'Saving…', 'Clean-up saved.');
        });

        button('server-test').addEventListener('click', function () {
            actAt('server-message', 'media_test', server(), 'Asking the media server…', 'It answered.').then(function (response) {
                if (response) {
                    say(response.message, true, 'server-message');
                }
            });
        });

        button('server-save').addEventListener('click', function () {
            actAt('server-message', 'media_server', server(), 'Saving…', part('server-type').value ? 'Media server saved.' : 'No media server.').then(function (response) {
                if (response) {
                    part('server-token').value = '';
                }
            });
        });

        button('ytdlp-save').addEventListener('click', function () {
            actAt('ytdlp-message', 'ytdlp_setting', { update: part('ytdlp-auto').checked ? 1 : '' }, 'Saving…', 'Saved.');
        });

        button('ytdlp-now').addEventListener('click', function () {
            actAt('ytdlp-message', 'ytdlp_update', { confirm: 1 }, 'Updating yt-dlp (this can take a minute)…', 'yt-dlp is up to date.');
        });

        button('listen').addEventListener('click', function () {
            let local = part('local').checked;

            actAt('access-message', 'listen', { listen: local ? 'local' : 'all' }, 'Saving…', local ? 'The Watch page is now only reachable through the Nginx app.' :
                'The Watch page is reachable on port 8086 too.');
        });

        refresh();
    })();
    </script>
</div>
