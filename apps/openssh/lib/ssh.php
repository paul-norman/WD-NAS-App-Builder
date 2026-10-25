<?php
// SSH keys for the management page: reading authorized_keys files and checking new keys (with the app's ssh-keygen)

// The key types accepted from the page (as OpenSSH 10 accepts them: DSA is gone)
const SSH_KEY_TYPES = 'ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521'
	. '|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com';

// A key's details from ssh-keygen -l ("3072 SHA256:... comment (RSA)"): ['bits', 'fingerprint', 'comment', 'type'], or null
function ssh_key_info($keygen, $line)
{
	list($code, $output) = manage_run([$keygen, '-l', '-f', '-'], [], $line . "\n");
	if ($code !== 0 || !preg_match('/^(\d+) (SHA256:\S+) (.*) \(([^)]+)\)$/', trim($output), $m)) {
		return null;
	}
	return ['bits' => (int)$m[1], 'fingerprint' => $m[2], 'comment' => $m[3], 'type' => $m[4]];
}

// The keys in an authorized_keys file, each with its line and details (lines ssh-keygen doesn't understand are skipped)
function ssh_keys_read($keygen, $file)
{
	$keys = [];
	foreach (@file($file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [] as $line) {
		$line = trim($line);
		if ($line === '' || $line[0] === '#') {
			continue;
		}
		$info = ssh_key_info($keygen, $line);
		if ($info !== null) {
			$keys[] = $info + ['line' => $line];
		}
	}
	return $keys;
}

// A public key pasted on the page, checked: [line to add, details] - or [null, the reason it's refused]. Only the key
// itself (type, key, comment): no options such as command="...", which would need more care than a paste box offers
function ssh_key_check($keygen, $text, $name)
{
	$text = trim(preg_replace('/\s+/', ' ', (string)$text));
	if ($text === '') {
		return [null, 'Paste a public key (the contents of its .pub file)'];
	}
	if (strpos($text, 'PRIVATE KEY') !== false) {
		return [null, 'That\'s a private key: paste the public one (the .pub file) - and keep the private key to yourself'];
	}
	if (!preg_match('/^(' . SSH_KEY_TYPES . ') ([A-Za-z0-9+\/]+={0,3})(?: (.*))?$/', $text, $m)) {
		return [null, 'That isn\'t a public key OpenSSH accepts: it starts with its type, e.g. ssh-ed25519 AAAA…'];
	}
	$name = trim(preg_replace('/[\x00-\x1f\x7f]+/', ' ', (string)$name));
	$comment = $name !== '' ? $name : (isset($m[3]) ? trim($m[3]) : '');
	$line = $m[1] . ' ' . $m[2] . ($comment !== '' ? ' ' . $comment : '');
	$info = ssh_key_info($keygen, $line);
	if ($info === null) {
		return [null, 'That key is damaged (ssh-keygen can\'t read it): copy the whole line from the .pub file'];
	}
	if ($info['type'] === 'RSA' && $info['bits'] < 2048) {
		return [null, 'RSA keys need at least 2048 bits (this one has ' . $info['bits'] . '): make an Ed25519 key instead'];
	}
	return [$line, $info];
}

// The NAS's host keys' fingerprints (what a computer shows when it first connects)
function ssh_host_fingerprints($keygen)
{
	$fingerprints = [];
	foreach (glob('/etc/ssh/ssh_host_*_key.pub') ?: [] as $file) {
		list($code, $output) = manage_run([$keygen, '-l', '-f', $file]);
		if ($code === 0 && preg_match('/^(\d+) (SHA256:\S+) .* \(([^)]+)\)$/', trim($output), $m)) {
			$fingerprints[] = ['type' => $m[3], 'bits' => (int)$m[1], 'fingerprint' => $m[2]];
		}
	}
	return $fingerprints;
}
