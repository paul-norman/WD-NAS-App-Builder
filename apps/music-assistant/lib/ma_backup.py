"""Backs up Music Assistant's data (settings, library database, users) to a .tar.gz - while it's stopped, as it keeps its
databases locked while it runs.

Run as root by ma_ctl.sh with the app's own Python:
    python3 -I ma_backup.py <data folder> <backup folder> <number to keep>

Databases are copied with SQLite's backup (which includes anything still in their write-ahead logs); the cache, temporary
files and logs are left out. A database that's still locked makes it fail, rather than wait.
"""

import os
import sqlite3
import sys
import tarfile
import tempfile
import time

SKIPPED = {".cache", "tmp", "home"}


def backup(data, folder, keep):
    os.makedirs(folder, mode=0o700, exist_ok=True)
    name = os.path.join(folder, time.strftime("music-assistant-%Y%m%d-%H%M%S.tar.gz"))
    with tempfile.TemporaryDirectory(dir=folder) as work:
        for root, dirs, files in os.walk(data):
            dirs[:] = [d for d in dirs if not (root == data and d in SKIPPED)]
            for file in files:
                if file.endswith((".log", ".log.1", "-wal", "-shm", "-journal")):
                    continue
                source = os.path.join(root, file)
                target = os.path.join(work, os.path.relpath(source, data))
                os.makedirs(os.path.dirname(target), exist_ok=True)
                if file.endswith(".db"):
                    with sqlite3.connect(source, timeout=10) as db, sqlite3.connect(target) as copy:
                        # (raises "database is locked" after the timeout, where the backup would wait forever)
                        db.execute("SELECT count(*) FROM sqlite_master").fetchone()
                        db.backup(copy)
                else:
                    with open(source, "rb") as reader, open(target, "wb") as writer:
                        writer.write(reader.read())
        partial = name + ".partial"
        with tarfile.open(partial, "w:gz") as archive:
            archive.add(work, arcname="data")
        os.chmod(partial, 0o600)
        os.replace(partial, name)
    # Keep only the newest backups
    backups = sorted(f for f in os.listdir(folder) if f.startswith("music-assistant-") and f.endswith(".tar.gz"))
    for old in backups[:-keep]:
        os.remove(os.path.join(folder, old))
    print("backed up Music Assistant: %s (%d KB)" % (name, os.path.getsize(name) // 1024))


if __name__ == "__main__":
    if len(sys.argv) != 4 or not os.path.isdir(sys.argv[1]) or not sys.argv[3].isdigit():
        print(__doc__)
        sys.exit(2)
    backup(sys.argv[1], sys.argv[2], max(1, int(sys.argv[3])))
