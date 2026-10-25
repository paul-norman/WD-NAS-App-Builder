<?php
// OpenSSH management actions (JSON), for NAS admins only - see manage_helpers.php
require __DIR__ . '/manage_helpers.php';
manage_require_admin('openssh');

// manage/ lives inside the app's install directory (symlinks are resolved in __DIR__)
$app_path = dirname(__DIR__);
$data_path = dirname($app_path) . '/_openssh';
$keys_file = $data_path . '/authorized_keys';
$settings_file = $data_path . '/settings';
$ctl = $app_path . '/ssh_ctl.sh';
$keygen = $app_path . '/binaries/bin/ssh-keygen';
require $app_path . '/lib/ssh.php';

// The settings file (KEY=value lines, also read by ssh_ctl.sh), with defaults
function ssh_settings($file)
{
	$settings = ['PASSWORDS' => 'on'];
	foreach (@file($file, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
		if (preg_match('/^([A-Z_]+)=(.*)$/', $line, $m) && isset($settings[$m[1]])) {
			$settings[$m[1]] = $m[2];
		}
	}
	return $settings;
}

function ssh_ctl($ctl, $command)
{
	return manage_run(['/bin/sh', $ctl, $command]);
}

// The login user's own keys (~/.ssh/authorized_keys - WD's login user is sshd, whose home is /home/root): kept across
// reboots only if /home/root leads to a disk (e.g. the Entware app's home folder) - WD's own is in RAM
function ssh_home_keys($keygen)
{
	$home = '/home/root';
	$real = realpath($home);
	return [
		'file' => $home . '/.ssh/authorized_keys',
		'kept' => $real !== false && strpos($real, '/mnt/') === 0,
		'keys' => ssh_keys_read($keygen, $home . '/.ssh/authorized_keys'),
	];
}

function ssh_write_keys($file, array $lines)
{
	$text = $lines ? implode("\n", $lines) . "\n" : '';
	$ok = is_file($file) ? manage_write_file($file, $text) : file_put_contents($file, $text) !== false && chmod($file, 0600);
	if (!$ok) {
		manage_fail(500, 'The keys could not be saved');
	}
}

$settings = ssh_settings($settings_file);
$action = isset($_GET['action']) ? $_GET['action'] : 'status';

if ($action === 'status') {
	list(, $status) = ssh_ctl($ctl, 'status');
	$state = [];
	foreach (explode("\n", $status) as $line) {
		if (preg_match('/^([A-Z]+)=(.*)$/', $line, $m)) {
			$state[$m[1]] = $m[2];
		}
	}
	list(, $version) = manage_run([$app_path . '/binaries/bin/sshd', '-V']);
	list(, $port) = manage_run(['/bin/sh', '-c', '"$0" -T -f /etc/ssh/sshd_config 2>/dev/null | awk \'tolower($1) == "port" { print $2; exit }\'',
		$app_path . '/binaries/bin/sshd']);
	$log = @file('/var/log/sshd.log', FILE_IGNORE_NEW_LINES) ?: [];
	manage_json([
		// app: the app's sshd is running; wd: WD's (e.g. the app fell back); none: SSH is off in the dashboard
		'listener' => isset($state['LISTENER']) ? $state['LISTENER'] : 'none',
		'linked' => isset($state['LINKED']) && $state['LINKED'] === 'yes',
		'sandbox' => isset($state['SANDBOX']) ? $state['SANDBOX'] : '',
		'fallback' => isset($state['FALLBACK']) ? $state['FALLBACK'] : '',
		'version' => preg_match('/OpenSSH_(\S+?),/', $version, $m) ? $m[1] : '',
		'port' => (int)trim($port) ?: 22,
		'passwords' => $settings['PASSWORDS'] !== 'off',
		'host_keys' => ssh_host_fingerprints($keygen),
		'keys' => array_map(function ($key) { unset($key['line']); return $key; }, ssh_keys_read($keygen, $keys_file)),
		'home' => (function ($home) {
			$home['keys'] = array_map(function ($key) { unset($key['line']); return $key; }, $home['keys']);
			return $home;
		})(ssh_home_keys($keygen)),
		'log' => array_slice($log, -30),
	]);
}

manage_require_action('openssh');

if ($action === 'add_key') {
	list($line, $info) = ssh_key_check($keygen, isset($_POST['key']) ? $_POST['key'] : '', isset($_POST['name']) ? $_POST['name'] : '');
	if ($line === null) {
		manage_fail(400, $info);
	}
	$keys = ssh_keys_read($keygen, $keys_file);
	foreach ($keys as $key) {
		if ($key['fingerprint'] === $info['fingerprint']) {
			manage_fail(400, 'That key is already there (' . ($key['comment'] !== '' ? $key['comment'] : $key['fingerprint']) . ')');
		}
	}
	ssh_write_keys($keys_file, array_merge(array_column($keys, 'line'), [$line]));
	ssh_ctl($ctl, 'keys');
	manage_json(['fingerprint' => $info['fingerprint'], 'type' => $info['type'], 'comment' => $info['comment']]);
}

if ($action === 'remove_key') {
	$fingerprint = isset($_POST['fingerprint']) ? (string)$_POST['fingerprint'] : '';
	$keys = ssh_keys_read($keygen, $keys_file);
	$left = array_values(array_filter($keys, function ($key) use ($fingerprint) { return $key['fingerprint'] !== $fingerprint; }));
	if (count($left) === count($keys)) {
		manage_fail(404, 'No such key');
	}
	// (with password logins off, the last key is the only way in)
	if ($settings['PASSWORDS'] === 'off' && !$left && !ssh_home_keys($keygen)['keys']) {
		manage_fail(409, 'That\'s the last key, and password logins are off: turn password logins on first, or you couldn\'t log in at all');
	}
	ssh_write_keys($keys_file, array_column($left, 'line'));
	ssh_ctl($ctl, 'keys');
	manage_json([]);
}

if ($action === 'passwords') {
	$on = !empty($_POST['on']);
	if (!$on && !ssh_keys_read($keygen, $keys_file) && !ssh_home_keys($keygen)['keys']) {
		manage_fail(409, 'Add a key first: with password logins off, keys are the only way in');
	}
	if (!manage_write_file($settings_file, 'PASSWORDS=' . ($on ? 'on' : 'off') . "\n")) {
		manage_fail(500, 'The setting could not be saved');
	}
	list($code, $output) = ssh_ctl($ctl, 'restart');
	if ($code !== 0) {
		manage_fail(500, 'OpenSSH could not restart, so WD\'s sshd is running again: ' . trim($output));
	}
	manage_json(['passwords' => $on]);
}

if ($action === 'restart') {
	list($code, $output) = ssh_ctl($ctl, 'restart');
	if ($code !== 0) {
		manage_fail(500, 'OpenSSH could not restart, so WD\'s sshd is running again: ' . trim($output));
	}
	manage_json([]);
}

manage_fail(400, 'Unknown action');
