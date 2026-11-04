# Ruby App

This app provides [Ruby](https://www.ruby-lang.org/) - `ruby`, `gem`, `bundle`, `irb`, `rake` and the other commands that come with it - to run and build Ruby programs directly on the WD NAS device.

- **Its standard library is complete**: OpenSSL *(`openssl`, `net/https`)*, YAML *(`psych`, with libyaml)*, `fiddle` *(libffi)* and `zlib` are built in, as are the gems that come with Ruby *(Bundler, Rake, Minitest, test-unit, RBS, TypeProf, debug, RDoc...)*. The NAS's own libraries aren't used, so nothing depends on their versions.
- **Gems you install are kept** when the app is updated or removed: they go in `Nas_Prog/_ruby/gems`, and their commands in `Nas_Prog/_ruby/bin`, linked into `/usr/bin` *(as root - never over a command that's already there; the app links them again at every boot)*. `bundle install` works the same way, and a project can still keep its gems in its own folder *(`bundle config set --local path vendor/bundle`)*.
- **No C compiler on the NAS**: gems that come ready-built for Linux install as usual *(e.g. `sqlite3`, `nokogiri`, `pg`, `ffi`, `google-protobuf`)*, and pure Ruby gems always do. A gem that has to compile C code needs a compiler - e.g. the [Entware app](../entware/README.md)'s *(`opkg install gcc make`)*. Ruby's own headers are included, for that.
- **HTTPS works** *(`gem install`, `Net::HTTP`)*: Ruby's OpenSSL trusts the app's own copy of Mozilla's certificate authorities *(`binaries/etc/cacert.pem`, as curl publishes it)*, unless `SSL_CERT_FILE` or `SSL_CERT_DIR` says otherwise.
- It's Ruby built from its source on the NAS's Debian version *(so it only needs the NAS's own glibc)*, relocatable, and pinned by SHA256 with its libraries in `static/ruby/build.sh`. The app's RubyGems settings are in `static/ruby/operating_system.rb`. Intel models only.

A small test server is started on port `30291` *(a page with Ruby's and its libraries' versions)*, with its output in `test_server.log` in the app's install directory.

The app's page in the NAS dashboard *(Apps → Ruby)* shows the versions of Ruby, RubyGems and Bundler, the gems installed, and the test server's status, with a link to it and a restart button. Only NAS admins can use the page *(see [Management pages](../README.md#management-pages))*.

## Building the Ruby app

From the project root directory:

```bash
./build.sh ruby
```

This first runs `static/ruby` *(once per version: it builds Ruby and its libraries from source)*. The WD bin files will be created in `packages/ruby/`.

If you don't have docker installed, see the [guide](../../docker/README.md) in the `docker` directory. If you're on Windows 10 or 11, see the [Windows guide](../../docker/WINDOWS.md) for WSL / docker installation.
