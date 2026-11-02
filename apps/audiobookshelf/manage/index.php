<?php
// Audiobookshelf's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('audiobookshelf');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="audiobookshelf-manage">
    <?php manage_styles('audiobookshelf-manage'); ?>

    <h2>Audiobookshelf</h2>
    <table>
        <tr><td>Status</td><td data-ab="status">…</td></tr>
        <tr><td>Version</td><td data-ab="version">-</td></tr>
        <tr><td>Address</td><td data-ab="address">-</td></tr>
    </table>
    <p><a class="mg-button" data-ab="link" href="#" target="_blank" rel="noopener">Open Audiobookshelf</a>
        <button type="button" data-ab-action="restart">Restart Audiobookshelf</button></p>

    <h3>Root user</h3>
    <p>User name <code>root</code>, password <code data-ab="password">••••••••••••</code>
        <button type="button" data-ab-action="show">Show</button> <button type="button" data-ab-action="copy">Copy</button>
        <button type="button" data-ab-action="new-password">New password</button></p>
    <p class="mg-note">The app created this administrator when Audiobookshelf first started, so that no one else could.
        Create a user for each person in Audiobookshelf (Settings → Users), and log in to its phone apps with those. This
        page logs in as root with this password, so keep it as the app set it.</p>

    <h3>Libraries</h3>
    <table data-ab="libraries"></table>
    <p class="mg-note">Libraries are added in Audiobookshelf (Settings → Libraries): a folder of audiobooks (one folder per
        book, e.g. <code>Audiobooks/Author/Title</code>) or of podcasts. Audiobookshelf runs as its own user in the NAS's
        share group: it can read any share, and what it writes there (podcast episodes, merged M4B files) can be changed over
        SMB too. New files are picked up as they appear.</p>

    <h3>Settings</h3>
    <p><label><input type="checkbox" data-ab="local"> Only through the Nginx app (HTTPS)</label></p>
    <p><label>Podcast feeds on your own network <input type="text" data-ab="local-feeds" spellcheck="false"
        placeholder="e.g. 192.168.1.20, podcasts.home"></label></p>
    <p><button type="button" data-ab-action="settings">Save</button></p>
    <p class="mg-note">The Audiobookshelf apps for Android and iPhone connect to the address above. Podcast feeds on the
        internet always work; Audiobookshelf only fetches from addresses on your own network when they're listed here (it
        refuses them otherwise, so that a feed can't reach the NAS's own services). Audiobookshelf restarts.</p>

    <details class="mg-section">
        <summary>Audiobookshelf's latest warnings</summary>
        <pre data-ab="log"></pre>
    </details>

    <p data-ab="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('audiobookshelf', 'ab'); ?>

        let loaded = false;

        <?php manage_secret_script(); ?>
        <?php manage_act_script(); ?>

        /**
         * Shows Audiobookshelf's libraries and their folders, saying where it can't open or write into one (a podcast
         * library needs to write) - or why there's nothing to show.
         *
         * @param {Array.<Object>|null} libraries The libraries, or null if they couldn't be read
         * @param {boolean}             answering Whether Audiobookshelf answers
         * @param {boolean}             known     Whether the page knows the root user's password
         *
         * @return {void}
         */
        function fillLibraries(libraries, answering, known) {
            let table = part('libraries');

            table.textContent = '';

            if (!libraries) {
                table.insertRow().insertCell().textContent = !answering ? 'Audiobookshelf isn\'t running'
                    : (known ? 'Can\'t log in to Audiobookshelf as root with the password above (make a new one to fix it)'
                        : 'The root user was made elsewhere: its password isn\'t known to this page');

                return;
            }

            if (!libraries.length) {
                table.insertRow().insertCell().textContent = 'No libraries yet - add one in Audiobookshelf (Settings → Libraries)';

                return;
            }

            libraries.forEach(function (library) {
                let row = table.insertRow();

                row.insertCell().textContent = library.name;
                row.insertCell().textContent = (library.type === 'podcast' ? 'Podcasts' : 'Books')
                    + (library.items === null ? '' : ' - ' + library.items + (library.items === 1 ? ' item' : ' items'));

                let cell = row.insertCell();

                library.folders.forEach(function (folder) {
                    let line = document.createElement('div');

                    line.textContent = folder.path + (folder.can === 'none' ? ' - Audiobookshelf can\'t open this folder'
                        : (folder.can === 'read' && library.type === 'podcast' ? ' - Audiobookshelf can\'t write here: new episodes will fail' : ''));

                    if (folder.can === 'none' || (folder.can === 'read' && library.type === 'podcast')) {
                        line.className = 'mg-bad';
                    }

                    cell.appendChild(line);
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

                let status = part('status');

                status.textContent = !response.running ? 'Stopped' : (response.answering ? 'Running' : 'Starting…');
                status.className   = response.running && response.answering ? 'mg-ok' : 'mg-bad';

                part('version').textContent = response.version || '-';

                let addresses = [];

                if (response.site.url) {
                    addresses.push(response.site.url);
                }

                if (response.listen !== 'local' && response.local_url) {
                    addresses.push(response.local_url);
                }

                part('address').textContent = addresses.join(' or ') || '-';
                part('link').href           = response.site.url || response.local_url || '#';

                fillLibraries(response.libraries, response.answering, response.password_known);

                if (!loaded) {
                    part('local').checked     = response.listen === 'local';
                    part('local-feeds').value = response.local_feeds;

                    loaded = true;
                }

                part('log').textContent = response.log.length ? response.log.join('\n') : 'Nothing logged';
            });
        }

        // Keep the page current, until the dashboard removes it
        <?php manage_timer_script(); ?>

        button('restart').addEventListener('click', function () {
            act('restart', { confirm: 1 }, 'Restarting Audiobookshelf…', 'Audiobookshelf restarted.');
        });

        // The root password: Show / Hide and Copy (fetched when first needed)
        let password = secretControls(part('password'), button('show'), button('copy'), function () {
            return call('password', { show: 1 }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return null;
                }

                return response.password || 'not known (made elsewhere)';
            });
        });

        button('new-password').addEventListener('click', function () {
            if (!window.confirm('Give root a new password? Apps logged in as root need the new one.')) {
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
                listen:      part('local').checked ? 'local' : 'all',
                local_feeds: part('local-feeds').value
            }, 'Saving…', 'Saved - Audiobookshelf restarted.');
        });

        refresh();
    })();
    </script>
</div>
