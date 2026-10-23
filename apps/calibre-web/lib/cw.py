"""The Calibre-Web app's helper, run by root with the app's Python (cw_ctl.sh and the management page):

    cw.py configure <app.db> <library> <calibre folder> <kepubify>  - Calibre-Web's settings the app looks after
    cw.py backup <database> <copy>                                  - a consistent copy of an SQLite database
    cw.py count <metadata.db>                                       - the number of books in a library
"""
import os
import sqlite3
import sys


def configure(app_db, library, calibre, kepubify):
    """The library, Calibre's programs and kepubify (the app's own: the only ones that run here), and uploads on (books
    added through the browser). Only while Calibre-Web is stopped: it reads its settings when it starts"""
    with sqlite3.connect(app_db) as db:
        db.execute("UPDATE settings SET config_calibre_dir = ?, config_binariesdir = ?, config_converterpath = ?, "
                   "config_kepubifypath = ?, config_uploading = 1",
                   (library, calibre, os.path.join(calibre, "ebook-convert"), kepubify))
    return 0


def backup(source, copy):
    """SQLite's online backup: a consistent copy even while the database is in use"""
    if not os.path.isfile(source):
        return 0
    with sqlite3.connect("file:%s?mode=ro" % source, uri=True) as src, sqlite3.connect(copy + ".tmp") as dst:
        src.backup(dst)
    os.replace(copy + ".tmp", copy)
    os.chmod(copy, 0o600)
    return 0


def count(metadata_db):
    if not os.path.isfile(metadata_db):
        print(0)
        return 0
    with sqlite3.connect("file:%s?mode=ro" % metadata_db, uri=True) as db:
        print(db.execute("SELECT count(*) FROM books").fetchone()[0])
    return 0


if __name__ == "__main__":
    commands = {"configure": (configure, 4), "backup": (backup, 2), "count": (count, 1)}
    if len(sys.argv) < 2 or sys.argv[1] not in commands or len(sys.argv) != commands[sys.argv[1]][1] + 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(commands[sys.argv[1]][0](*sys.argv[2:]))
