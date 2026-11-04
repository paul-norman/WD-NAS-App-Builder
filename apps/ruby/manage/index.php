<?php
// Ruby's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('ruby');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="ruby-manage">
    <?php manage_styles('ruby-manage'); ?>

    <h2>Ruby</h2>
    <table>
        <tr><td>Ruby</td><td data-rb="ruby">…</td></tr>
        <tr><td>RubyGems</td><td data-rb="rubygems">-</td></tr>
        <tr><td>Bundler</td><td data-rb="bundler">-</td></tr>
        <tr><td>Gems installed</td><td data-rb="gems">-</td></tr>
    </table>
    <p class="mg-note"><code>ruby</code>, <code>gem</code>, <code>bundle</code>, <code>irb</code>, <code>rake</code> and the
        commands of the gems you install can be used over SSH. Gems are installed in <code data-rb="path">-</code>, so they
        stay when the app is updated (or removed). Ruby's OpenSSL trusts the app's own copy of Mozilla's certificate
        authorities.</p>
    <p class="mg-note">The NAS has no C compiler: gems that come ready-built for Linux (e.g. <code>sqlite3</code>,
        <code>nokogiri</code>, <code>pg</code>, <code>ffi</code>) install as usual, and pure Ruby ones always do. A gem that
        has to compile C code needs a compiler - e.g. the Entware app's (<code>opkg install gcc make</code>).</p>

    <h3>Test server</h3>
    <p>A small example server on port <code>30291</code>, showing that Ruby works on the NAS: <span data-rb="server">…</span></p>
    <p><a class="mg-button" data-rb="link" href="#" target="_blank" rel="noopener">Open the test server</a>
        <button type="button" data-rb-action="restart">Restart it</button></p>

    <p data-rb="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('ruby', 'rb'); ?>

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

                part('ruby').textContent     = response.ruby || 'not found';
                part('rubygems').textContent = response.rubygems || '-';
                part('bundler').textContent  = response.bundler || '-';
                part('gems').textContent     = response.gems.length ? response.gems.join(', ') : 'none yet';
                part('path').textContent     = response.gems_path;

                let server = part('server');

                server.textContent = response.test_server;
                server.className   = response.test_server === 'running' ? 'mg-ok' : 'mg-bad';
            });
        }

        part('link').href = 'http://' + window.location.hostname + ':30291/';

        button('restart').addEventListener('click', function () {
            say('Restarting the test server…', true);
            call('restart', { confirm: 1 }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return;
                }

                say('The test server restarted.', true);
                setTimeout(refresh, 1000);
            });
        });

        refresh();
    })();
    </script>
</div>
