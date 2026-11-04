<?php
// k3s's management page, shown inside the NAS dashboard (CenterType 1) - for NAS admins only, see manage_helpers.php
require __DIR__.'/manage_helpers.php';

manage_require_admin('k3s');

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<div id="k3s-manage">
    <?php manage_styles('k3s-manage'); ?>

    <h2>k3s</h2>
    <table>
        <tr><td>Status</td><td data-ks="status">…</td></tr>
        <tr><td>Version</td><td data-ks="version">-</td></tr>
        <tr><td>Node</td><td data-ks="node">-</td></tr>
        <tr><td>Kernel</td><td data-ks="kernel">-</td></tr>
    </table>
    <p class="mg-note mg-bad" data-ks="kernel-note" hidden></p>
    <p><button type="button" data-ks-action="restart">Restart k3s</button></p>
    <p class="mg-note">Restarting k3s itself leaves the pods running. Disabling the app stops everything.</p>

    <h3>kubectl</h3>
    <p>On the NAS (over SSH): <code>kubectl get pods -A</code>. From another computer, save this kubeconfig as
        <code>~/.kube/config</code> (or point <code>KUBECONFIG</code> at it):</p>
    <pre data-ks="kubeconfig">••••••••••••</pre>
    <p><button type="button" data-ks-action="show">Show</button> <button type="button" data-ks-action="copy">Copy</button></p>
    <p class="mg-note">It's the cluster's admin login - full control of the cluster, and through it of the NAS. Keep it
        private.</p>

    <h3>Pods</h3>
    <table>
        <thead><tr><th>Namespace</th><th>Pod</th><th>State</th><th>Ready</th><th>Restarts</th></tr></thead>
        <tbody data-ks="pods"><tr><td colspan="5">…</td></tr></tbody>
    </table>

    <h3>Settings</h3>
    <p><label>Memory the pods may use
        <select data-ks="memory">
            <option value="">Default (half)</option>
            <option value="25">25%</option>
            <option value="33">33%</option>
            <option value="50">50%</option>
            <option value="60">60%</option>
            <option value="70">70%</option>
            <option value="80">80%</option>
            <option value="90">90%</option>
        </select></label> <span data-ks="memory-mb"></span><br>
        <label><input type="checkbox" data-ks="servicelb"> LoadBalancer services on the NAS's own ports (k3s's ServiceLB)</label>
        <button type="button" data-ks-action="settings">Save</button></p>
    <p class="mg-note">The rest of the memory is kept for the NAS and its other apps. ServiceLB opens each
        LoadBalancer service's ports on the NAS itself - they must not clash with the NAS's own (80 and 443 are the
        dashboard's). k3s restarts.</p>

    <details class="mg-section">
        <summary>k3s's latest log lines</summary>
        <pre data-ks="log"></pre>
    </details>

    <p data-ks="message"></p>

    <script>
    // Wrapped in a closure: nothing may leak into the dashboard's global scope (e.g. it relies on jQuery's $)
    (function () {
        <?php manage_core_script('k3s', 'ks'); ?>
        <?php manage_secret_script(); ?>

        let loaded = false;
        let total  = 0;

        /**
         * Shows the memory the pods may use for the share chosen.
         *
         * @return {void}
         */
        function showMemory() {
            const percent = part('memory').value === '' ? 50 : Number(part('memory').value);

            part('memory-mb').textContent = total ? `(${Math.round(total * percent / 100)} MB of ${total} MB)` : '';
        }

        /**
         * Shows the cluster's pods in their table.
         *
         * @param {Array} pods The pods (namespace, name, state, ready, restarts)
         *
         * @return {void}
         */
        function showPods(pods) {
            const body = part('pods');

            body.textContent = '';

            if (!pods.length) {
                const row  = body.insertRow();
                const cell = row.insertCell();

                cell.colSpan     = 5;
                cell.textContent = 'No pods (yet)';

                return;
            }

            pods.forEach(function (pod) {
                const row = body.insertRow();

                [pod.namespace, pod.name, pod.state, pod.ready, String(pod.restarts)].forEach(function (text, index) {
                    const cell = row.insertCell();

                    cell.textContent = text;

                    if (index === 2) {
                        cell.className = pod.state === 'Running' || pod.state === 'Succeeded' || pod.state === 'Completed' ? 'mg-ok' : 'mg-bad';
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

                const status = part('status');

                if (!response.running) {
                    status.textContent = 'Stopped';
                } else if (!response.answering) {
                    status.textContent = 'Starting…';
                } else {
                    status.textContent = response.ready ? 'Running' : 'Running (node not ready yet)';
                }

                status.className = response.running && response.ready ? 'mg-ok' : 'mg-bad';

                part('version').textContent = response.version ? `${response.version} (Kubernetes ${response.kubernetes || '-'})` : '-';
                part('node').textContent    = response.node || '-';

                const kernel = part('kernel');

                kernel.textContent = response.kernel.length ? 'Missing what Kubernetes needs' : 'Ready'
                    + (response.overlay ? '' : ' (no overlay: images are copied whole)');
                kernel.className   = response.kernel.length ? 'mg-bad' : 'mg-ok';

                part('kernel-note').hidden      = !response.kernel.length;
                part('kernel-note').textContent = response.kernel.join('; ');

                total = response.memory.total_mb;

                if (!loaded) {
                    part('memory').value      = response.memory.chosen ? String(response.memory.percent) : '';
                    part('servicelb').checked = response.servicelb;

                    loaded = true;
                }

                showMemory();
                showPods(response.pods);
                part('log').textContent = response.log.length ? response.log.join('\n') : 'Nothing logged';
            });
        }

        // Keep the page current, until the dashboard removes it
        <?php manage_timer_script(); ?>
        <?php manage_act_script(); ?>

        button('restart').addEventListener('click', function () {
            act('restart', { confirm: 1 }, 'Restarting k3s…', 'k3s restarted - it takes a minute to be ready.');
        });

        // The kubeconfig: Show / Hide and Copy (fetched when first needed)
        secretControls(part('kubeconfig'), button('show'), button('copy'), function () {
            return call('kubeconfig', { show: 1 }).then(function (response) {
                if (!response.ok) {
                    say(response.error, false);

                    return null;
                }

                return response.kubeconfig;
            });
        });

        part('memory').addEventListener('change', showMemory);

        button('settings').addEventListener('click', function () {
            act('settings', { memory: part('memory').value, servicelb: part('servicelb').checked ? 1 : 0 }, 'Saving…', 'Saved - k3s restarted.');
        });

        refresh();
    })();
    </script>
</div>
