# MongoDB App

[MongoDB](https://www.mongodb.com/) is a document database: it keeps JSON-like documents in collections, with indexes, aggregations, transactions and full-text search. This app runs MongoDB 8.0 natively on the NAS *(no Docker)*, with its shell `mongosh` and its database tools *(`mongodump`, `mongorestore`, `mongoexport`, `mongoimport`, `bsondump`)*. The [Compass Web app](../compass-web/README.md) gives it a web interface.

- **Built for the NAS's processors.** MongoDB's own builds *(5.0 and later)* need AVX instructions, which the NAS's Intel Pentium / Celeron / Atom processors don't have: they'd stop at once with "Illegal instruction". This one is built from MongoDB's source for them *(`static/mongodb`)*, the way MongoDB builds its releases but targeting x86-64-v2 *(SSE4.2, no AVX)*, with its JavaScript engine's AVX2 code left out - as FreeBSD's, Gentoo's and others' builds for older processors do. Each build is checked on an emulated processor without AVX *(storing and querying documents, JavaScript included)*. MongoDB doesn't support builds like this itself.
- It listens on port 27017 and **always asks for a login**. By default only programs on the NAS itself reach it *(127.0.0.1)*; a switch on the page makes it reachable from the local network too. Its connections aren't encrypted *(no TLS)*: keep it to your own network.
- **Its administrator** is `admin` *(the `root` role: everything, on every database)*, with a password the app generates on its first start - shown on the management page, which can also change it *(the Compass Web app follows)*. Connect with `mongodb://admin:<password>@127.0.0.1:27017/?authSource=admin`.
- **Databases for your apps**: the page makes a database with a login of its own *(same name; read, write and indexes on that database only)* and a generated password, shown once.
- **Its memory**: MongoDB's cache would otherwise take half the NAS's memory, less 1GB - the app gives it 512MB *(256MB to 4GB on the page)*.
- **The shell**: `/mnt/HD/HD_a2/Nas_Prog/mongodb/binaries/bin/mongosh` over SSH *(see the [OpenSSH app](../openssh/README.md))*. The app's own use of mongosh sends no usage data to MongoDB.
- **Backups**: every day at 03:15, every database with `mongodump` *(while MongoDB runs)*, in one compressed archive, into `Nas_Prog/_mongodb/backups` *(or a folder chosen on the page)*, keeping the newest 7. To restore one *(over what's there)*:

  ```sh
  cd /mnt/HD/HD_a2/Nas_Prog/mongodb/binaries/bin
  ./mongorestore --host 127.0.0.1 --username admin --authenticationDatabase admin --gzip --drop \
      --archive=/mnt/HD/HD_a2/Nas_Prog/_mongodb/backups/mongodb-<date>.archive.gz
  ```

  *(it asks for the administrator's password)*.
- It runs as its own user *(`mongodb`, ID 67)*. Its data is kept in `Nas_Prog/_mongodb`, across reinstalls and removal: `db/` and `log/` are MongoDB's own; its configuration *(`conf/mongod.conf`, written by the app at every start)*, password, settings and backups are root's.
- A new major version *(9.0)* is a separate step - MongoDB's data is upgraded one major version at a time. The app checks weekly for a new 8.0 release *(a NAS alert)*.
- MongoDB's server is licensed under the SSPL *(Server Side Public License)*; mongosh and the database tools under Apache-2.0 *(their licences come with the package)*. OpenSSL 3.5 *(for MongoDB's TLS support)* is bundled. Intel models only.

## Building the MongoDB app

From the project root directory:

```bash
./build.sh mongodb
```

This first runs `static/mongodb` *(once per version - it builds MongoDB from source: about 40 minutes on a 24-thread machine, a few hours on GitHub's runners)*. The WD bin files will be created in `packages/mongodb/`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
