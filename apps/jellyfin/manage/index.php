<?php
// Jellyfin's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see
// manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('jellyfin');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="jellyfin-manage">
    <?php manage_styles('jellyfin-manage'); ?>

    <h2>Jellyfin</h2>
    <table>
        <tr><td>Status</td><td data-jf="status">…</td></tr>
        <tr><td>Version</td><td data-jf="version">-</td></tr>
        <tr><td>Server name</td><td data-jf="name">-</td></tr>
    </table>
    <p><a class="mg-button" data-jf="link" href="#" target="_blank" rel="noopener">Open Jellyfin</a>
        <button type="button" data-jf-action="restart">Restart Jellyfin</button></p>

    <h3>Hardware transcoding</h3>
    <p>GPU: <span data-jf="driver">…</span></p>
    <table data-jf="settings"></table>
    <p data-jf="summary"></p>
    <p><button type="button" data-jf-action="apply" hidden>Apply the recommended settings</button></p>
    <p class="mg-note">The recommended settings come from what this NAS's GPU can decode and encode. Applying them restarts
        Jellyfin, which stops any playback; all other settings are kept. They can still be changed in Jellyfin's dashboard
        (Playback → Transcoding).</p>

    <p data-jf="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('jellyfin', 'jf'); ?>

        let codecNames    = { h264: 'H.264', hevc: 'HEVC', mpeg2video: 'MPEG-2', vc1: 'VC-1', vp8: 'VP8', vp9: 'VP9', av1: 'AV1' };
        let wasRestarting = false;
        let labels        = {
            HardwareAccelerationType:           'Hardware acceleration',
            VaapiDevice:                        'VA-API device',
            HardwareDecodingCodecs:             'Hardware decoding',
            EnableDecodingColorDepth10Hevc:     'HEVC 10-bit decoding',
            EnableDecodingColorDepth10Vp9:      'VP9 10-bit decoding',
            EnableDecodingColorDepth10HevcRext: 'HEVC RExt 8/10-bit decoding',
            EnableDecodingColorDepth12HevcRext: 'HEVC RExt 12-bit decoding',
            EnableHardwareEncoding:              'Hardware encoding (H.264)',
            EnableIntelLowPowerH264HwEncoder:    'Intel low-power H.264 encoder',
            EnableIntelLowPowerHevcHwEncoder:    'Intel low-power HEVC encoder',
            AllowHevcEncoding:                   'Allow encoding in HEVC',
            AllowAv1Encoding:                    'Allow encoding in AV1',
            EnableTonemapping:                   'Tone mapping',
            EnableVppTonemapping:                'VPP tone mapping'
        };

        /**
         * A transcoding setting's value as the page shows it.
         *
         * @param {string} name  The setting
         * @param {*}      value Its value (null or undefined: Jellyfin's default)
         *
         * @return {string} The value, for showing
         */
        function formatValue(name, value) {
            if (value === null || value === undefined) {
                return '(Jellyfin\'s default)';
            }

            if (name === 'HardwareDecodingCodecs') {
                return value.length ? value.map(function (codec) {
                    return codecNames[codec] || codec;
                }).join(', ') : 'none';
            }

            if (value === 'true') {
                return 'on';
            }

            if (value === 'false') {
                return 'off';
            }

            return value === 'vaapi' ? 'VA-API' : (value === 'none' ? 'none (software)' : value);
        }

        /**
         * Whether two settings' values are the same (the order of codecs doesn't matter).
         *
         * @param {*} a A value
         * @param {*} b The value to compare it with
         *
         * @return {boolean} Whether they are
         */
        function isSame(a, b) {
            if (Array.isArray(a) && Array.isArray(b)) {
                a = a.slice().sort();
                b = b.slice().sort();
            }

            return JSON.stringify(a) === JSON.stringify(b);
        }

        /**
         * Shows the GPU's driver and Jellyfin's transcoding settings next to the recommended ones (those that differ in
         * red), with Apply when they differ.
         *
         * @return {void}
         */
        function refreshTranscoding() {
            call('transcoding').then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return;
                }

                part('driver').textContent = response.driver || 'none found (Jellyfin transcodes in software)';

                let table = part('settings');

                table.textContent = '';

                let head = table.insertRow();

                ['Setting', 'Now', 'Recommended'].forEach(function (text) {
                    let cell = head.insertCell();

                    cell.textContent      = text;
                    cell.style.fontWeight = 'bold';
                });

                Object.keys(response.recommended).forEach(function (name) {
                    let row = table.insertRow();
                    let ok  = isSame(response.current[name], response.recommended[name]);

                    row.insertCell().textContent = labels[name] || name;

                    let now = row.insertCell();

                    now.textContent = formatValue(name, response.current[name]);
                    now.className = ok ? '' : 'mg-bad';
                    row.insertCell().textContent = formatValue(name, response.recommended[name]);
                });

                part('summary').textContent = response.matches ? 'Jellyfin uses the recommended settings.' :
                    (response.configured ? 'Some settings differ from the recommended ones (in red).' : 'Jellyfin hasn\'t been started yet.');
                part('summary').className = response.matches ? 'mg-ok' : 'mg-bad';
                button('apply').hidden = response.matches || !response.configured;
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

                status.textContent = response.restarting ? 'Restarting…' : (!response.running ? 'Stopped' :
                    (response.health === 'Healthy' ? 'Running' + (response.wizard_done ? '' : ' - open Jellyfin to finish its setup') : 'Starting… (' + (response.health || 'not answering yet') + ')'));
                status.className = response.running && response.health === 'Healthy' && !response.restarting ? 'mg-ok' : 'mg-bad';

                part('version').textContent = response.version || '-';
                part('name').textContent    = response.server_name || '-';
                button('restart').disabled  = button('apply').disabled = response.restarting;

                if (wasRestarting && !response.restarting) {
                    refreshTranscoding();
                }

                wasRestarting = response.restarting;
            });
        }

        part('link').href = 'http://' + window.location.hostname + ':8096/';

        // Keep the page current (e.g. during a restart), until the dashboard removes it
        <?php manage_timer_script(5000); ?>

        /**
         * Restarts Jellyfin through the API, once confirmed, and shows the status again.
         *
         * @param {string} action   The API's action (restart, or apply - restarting with the recommended settings)
         * @param {string} question What to ask first
         * @param {string} done     What to say once it's started
         *
         * @return {void}
         */
        function restart(action, question, done) {
            if (!window.confirm(question)) {
                return;
            }

            call(action, { confirm: 1 }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return;
                }

                say(done, true);
                refresh();
            });
        }

        button('restart').addEventListener('click', function () {
            restart('restart', 'Restart Jellyfin? Any playback stops.', 'Jellyfin is restarting.');
        });

        button('apply').addEventListener('click', function () {
            restart('apply', 'Apply the recommended transcoding settings? Jellyfin restarts, which stops any playback.',
                'Applying the settings - Jellyfin is restarting.');
        });

        refresh();
        refreshTranscoding();
    })();
    </script>
</div>
