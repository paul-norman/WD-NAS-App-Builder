<?php
// Jellyfin's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
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
		var root = document.getElementById('jellyfin-manage');
		var api = '/apps/jellyfin/api.php';
		var csrf = <?php echo json_encode(manage_csrf_token('jellyfin')); ?>;
		var labels = {
			HardwareAccelerationType: 'Hardware acceleration',
			VaapiDevice: 'VA-API device',
			HardwareDecodingCodecs: 'Hardware decoding',
			EnableDecodingColorDepth10Hevc: 'HEVC 10-bit decoding',
			EnableDecodingColorDepth10Vp9: 'VP9 10-bit decoding',
			EnableDecodingColorDepth10HevcRext: 'HEVC RExt 8/10-bit decoding',
			EnableDecodingColorDepth12HevcRext: 'HEVC RExt 12-bit decoding',
			EnableHardwareEncoding: 'Hardware encoding (H.264)',
			EnableIntelLowPowerH264HwEncoder: 'Intel low-power H.264 encoder',
			EnableIntelLowPowerHevcHwEncoder: 'Intel low-power HEVC encoder',
			AllowHevcEncoding: 'Allow encoding in HEVC',
			AllowAv1Encoding: 'Allow encoding in AV1',
			EnableTonemapping: 'Tone mapping',
			EnableVppTonemapping: 'VPP tone mapping'
		};
		var codecNames = { h264: 'H.264', hevc: 'HEVC', mpeg2video: 'MPEG-2', vc1: 'VC-1', vp8: 'VP8', vp9: 'VP9', av1: 'AV1' };
		var wasRestarting = false;

		function part(name) { return root.querySelector('[data-jf="' + name + '"]'); }
		function button(name) { return root.querySelector('[data-jf-action="' + name + '"]'); }

		function say(text, good) {
			var message = part('message');
			message.textContent = text;
			message.className = good ? 'mg-ok' : 'mg-bad';
		}

		// API calls carry X-Requested-With (nasAdmin requires it) and this page's CSRF token
		function call(action, data) {
			var options = { method: data ? 'POST' : 'GET', credentials: 'same-origin',
				headers: { 'X-Requested-With': 'XMLHttpRequest', 'X-CSRF-Token': csrf } };
			if (data) {
				options.headers['Content-Type'] = 'application/x-www-form-urlencoded';
				options.body = new URLSearchParams(data).toString();
			}
			return fetch(api + '?action=' + action, options).then(function (response) {
				return response.json().catch(function () { return { ok: false, error: 'Unexpected response (' + response.status + ')' }; });
			});
		}

		// A setting's value as shown on the page
		function show(name, value) {
			if (value === null || value === undefined) { return '(Jellyfin\'s default)'; }
			if (name === 'HardwareDecodingCodecs') {
				return value.length ? value.map(function (c) { return codecNames[c] || c; }).join(', ') : 'none';
			}
			if (value === 'true') { return 'on'; }
			if (value === 'false') { return 'off'; }
			return value === 'vaapi' ? 'VA-API' : (value === 'none' ? 'none (software)' : value);
		}

		// (the order of the codecs doesn't matter)
		function same(a, b) {
			if (Array.isArray(a) && Array.isArray(b)) { a = a.slice().sort(); b = b.slice().sort(); }
			return JSON.stringify(a) === JSON.stringify(b);
		}

		function refreshTranscoding() {
			call('transcoding').then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				part('driver').textContent = d.driver || 'none found (Jellyfin transcodes in software)';
				var table = part('settings');
				table.textContent = '';
				var head = table.insertRow();
				['Setting', 'Now', 'Recommended'].forEach(function (text) {
					var cell = head.insertCell();
					cell.textContent = text;
					cell.style.fontWeight = 'bold';
				});
				Object.keys(d.recommended).forEach(function (name) {
					var row = table.insertRow();
					var ok = same(d.current[name], d.recommended[name]);
					row.insertCell().textContent = labels[name] || name;
					var now = row.insertCell();
					now.textContent = show(name, d.current[name]);
					now.className = ok ? '' : 'mg-bad';
					row.insertCell().textContent = show(name, d.recommended[name]);
				});
				part('summary').textContent = d.matches ? 'Jellyfin uses the recommended settings.' :
					(d.configured ? 'Some settings differ from the recommended ones (in red).' : 'Jellyfin hasn\'t been started yet.');
				part('summary').className = d.matches ? 'mg-ok' : 'mg-bad';
				button('apply').hidden = d.matches || !d.configured;
			});
		}

		function refresh() {
			return call('status').then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
				var status = part('status');
				status.textContent = d.restarting ? 'Restarting…' : (!d.running ? 'Stopped' :
					(d.health === 'Healthy' ? 'Running' + (d.wizard_done ? '' : ' - open Jellyfin to finish its setup') : 'Starting… (' + (d.health || 'not answering yet') + ')'));
				status.className = d.running && d.health === 'Healthy' && !d.restarting ? 'mg-ok' : 'mg-bad';
				part('version').textContent = d.version || '-';
				part('name').textContent = d.server_name || '-';
				button('restart').disabled = button('apply').disabled = d.restarting;
				if (wasRestarting && !d.restarting) {
					refreshTranscoding();
				}
				wasRestarting = d.restarting;
			});
		}

		part('link').href = 'http://' + window.location.hostname + ':8096/';

		// Keep the page current (e.g. during a restart), until the dashboard removes it
		var timer = setInterval(function () {
			if (!document.body.contains(root)) { clearInterval(timer); return; }
			refresh();
		}, 5000);

		function restart(action, question, done) {
			if (!window.confirm(question)) { return; }
			call(action, { confirm: 1 }).then(function (d) {
				if (!d.ok) { say(d.error, false); return; }
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
