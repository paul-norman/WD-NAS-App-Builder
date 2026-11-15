// Gives a RetroAssembly account a new password - hashed as RetroAssembly hashes them (argon2id, with Node.js's own,
// in its own format) - and signs it out everywhere. Run by retroassembly_ctl.sh as RetroAssembly's own user, with its
// Node.js (RetroAssembly may be running: SQLite waits for it):
//     node ra_password.mjs <its folder> <database> <user name> < password
import crypto            from 'node:crypto';
import fs                from 'node:fs';
import { createRequire } from 'node:module';
import { promisify }     from 'node:util';

// As RetroAssembly's src/utils/server/argon2.ts
const OPTIONS = { memory: 65536, parallelism: 4, passes: 3, tagLength: 32 };

/**
 * Bytes as RetroAssembly writes them in a hash: URL-safe Base64, without padding.
 *
 * @param {Buffer} bytes The bytes
 *
 * @return {string} Their Base64
 */
function base64(bytes) {
    return bytes.toString('base64').replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
}

/**
 * Hashes a password as RetroAssembly does.
 *
 * @param {string} password The password
 *
 * @return {Promise<string>} Its hash ($argon2id$v=19$m=...,t=...,p=...$<salt>$<hash>)
 */
async function hash(password) {
    const salt   = crypto.randomBytes(16);
    const digest = await promisify(crypto.argon2)('argon2id', {
        ...OPTIONS,
        message: Buffer.from(password, 'utf8'),
        nonce:   salt,
    });

    const settings = `m=${OPTIONS.memory},t=${OPTIONS.passes},p=${OPTIONS.parallelism}`;

    return `$argon2id$v=19$${settings}$${base64(salt)}$${base64(Buffer.from(digest))}`;
}

const [folder, database, username] = process.argv.slice(2);
const password                     = fs.readFileSync(0, 'utf8').trim();

if (!folder || !database || !username || password.length < 8) {
    console.error('Usage: node ra_password.mjs <its folder> <database> <user name> < password (8 characters or more)');
    process.exit(2);
}

// RetroAssembly's own SQLite package
const Database = createRequire(`${folder}/package.json`)('better-sqlite3');
const db       = new Database(database, { fileMustExist: true, timeout: 10000 });
const user     = db.prepare('SELECT id FROM users WHERE username = ? AND status = 1').get(username);

if (!user) {
    console.error(`RetroAssembly has no account ${username}`);
    process.exit(1);
}

const hashed = await hash(password);
const now    = Date.now();

// The new password, and every sign-in with the old one ended (as RetroAssembly marks a deleted row)
db.transaction(() => {
    db.prepare('UPDATE users SET password_hash = ?, updated_at = ? WHERE id = ?').run(hashed, now, user.id);
    db.prepare('UPDATE sessions SET status = 0, updated_at = ? WHERE user_id = ? AND status = 1').run(now, user.id);
})();
db.close();
console.log(`New password set for ${username}`);
