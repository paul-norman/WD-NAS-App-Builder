#!/bin/sh
# Ruby from its package (tests/common/nas.sh): its commands linked into /usr/bin, its standard extensions (OpenSSL,
# YAML, Fiddle, zlib...), HTTPS with its own certificate authorities, the test server, gems installed in its data folder
# with their commands linked (never over a command already there) - a pure Ruby one, a ready-built native one and a
# Bundler project - kept across a reinstall, the page, removal
. /t/common/nas.sh ruby
G=$D/gems/4.0.0
rb() { /usr/bin/ruby "$@" 2>&1; }

echo '== installed'
install_app
[ "$(readlink /usr/bin/ruby)" = "$P/ruby/binaries/bin/ruby" ] && [ -L /usr/bin/gem ] && [ -L /usr/bin/bundle ] && [ -L /usr/bin/irb ] && [ -L /usr/bin/rake ] \
    && pass "its commands linked into /usr/bin: $(ls -l /usr/bin | grep -c "$P/ruby/") (ruby, gem, bundle, irb, rake...)" || fail "links: $(ls -l /usr/bin | grep ruby)"
V=$(rb -v); echo "$V" | grep -q '^ruby 4\.0\.9 ' && pass "$V" || fail "ruby -v: $V"
R=$(gem --version 2>&1) && B=$(bundle --version 2>&1) && pass "gem $R, $B (through their links)" || fail "gem / bundle: $R $B"

echo '== its standard library'
R=$(rb -e 'require "openssl"; require "yaml"; require "fiddle"; require "zlib"; require "json"; require "bigdecimal"; require "io/console"
    y = YAML.load(YAML.dump({ "a" => [1, 2] })); z = Zlib::Inflate.inflate(Zlib::Deflate.deflate("x" * 1000)).size
    strlen = Fiddle::Function.new(Fiddle.dlopen(nil)["strlen"], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_SIZE_T).call("hello")
    print [OpenSSL::Digest::SHA256.hexdigest("abc")[0, 8], y["a"].sum, z, strlen, (BigDecimal("0.1") * 3).to_s].join(" ")')
[ "$R" = 'ba7816bf 3 1000 5 0.3e0' ] && pass "OpenSSL, YAML, zlib, Fiddle (strlen from the C library), BigDecimal all work: $R" || fail "extensions: $R"

echo '== HTTPS'
R=$(rb -rnet/http -e 'print ENV["SSL_CERT_FILE"], " ", Net::HTTP.get_response(URI("https://rubygems.org/")).code')
echo "$R" | grep -q "^$P/ruby/binaries/etc/cacert.pem [23]0[0-9]$" && pass "HTTPS to rubygems.org, trusting its own certificate authorities: $R" || fail "https: $R"

echo '== the test server'
wait_port 30291 30 && curl -s -m 5 http://127.0.0.1:30291/ | grep -q 'ruby 4.0.9.*' && curl -s -m 5 http://127.0.0.1:30291/ | grep -q 'OpenSSL 3' \
    && pass 'answering on 30291, with its versions' || fail "test server: $(cat $P/ruby/test_server.log)"

echo '== gems'
R=$(gem install thor --no-document 2>&1 | tail -n 1)
[ -d "$(ls -d $G/gems/thor-* 2>/dev/null | head -n 1)" ] && [ "$(readlink /usr/bin/thor)" = "$D/bin/thor" ] && thor version | grep -q '^Thor ' && $D/bin/thor version | grep -q '^Thor ' \
    && pass "a pure Ruby gem in its data folder, its command linked: $(thor version) ($R)" || fail "thor: $R $(ls -l /usr/bin/thor 2>&1)"
R=$(gem install sqlite3 --no-document 2>&1 | tail -n 1)
S=$(rb -rsqlite3 -e 'print SQLite3::Database.new(":memory:").execute("SELECT 6 * 7")[0][0], " ", Gem.loaded_specs["sqlite3"].platform')
echo "$S" | grep -q '^42 x86_64-linux' && pass "a ready-built native gem (no compiler needed): sqlite3 answers $S" || fail "sqlite3: $R $S"
mkdir -p /tmp/proj && cd /tmp/proj && printf 'source "https://rubygems.org"\ngem "rainbow"\n' > Gemfile
R=$(bundle install 2>&1 | tail -n 1); S=$(bundle exec ruby -e 'require "rainbow"; print Gem.loaded_specs["rainbow"].version, " ", Rainbow("x").red' 2>&1); cd /
[ -d "$(ls -d $G/gems/rainbow-* 2>/dev/null | head -n 1)" ] && echo "$S" | grep -q '^[0-9.]* .*x' && pass "a Bundler project: its gems installed with the others, rainbow $S ($R)" || fail "bundle: $R $S"

echo "== a gem's commands never replace one already there"
mkdir -p /tmp/nasdemo/exe && cd /tmp/nasdemo && printf '#!/usr/bin/env ruby\nputs "demo"\n' > exe/nasdemo && cp exe/nasdemo exe/nasdemo-taken
printf 'Gem::Specification.new do |s|\n  s.name = "nasdemo"\n  s.version = "0.1"\n  s.summary = "Test"\n  s.authors = ["Suite"]\n  s.files = ["exe/nasdemo", "exe/nasdemo-taken"]\n  s.bindir = "exe"\n  s.executables = ["nasdemo", "nasdemo-taken"]\n  s.license = "MIT"\nend\n' > nasdemo.gemspec
gem build nasdemo.gemspec > /dev/null 2>&1; printf '#!/bin/sh\necho the NAS own\n' > /usr/bin/nasdemo-taken; chmod 755 /usr/bin/nasdemo-taken
gem install ./nasdemo-0.1.gem --local --no-document > /dev/null 2>&1; cd /
[ "$(nasdemo)" = demo ] && [ ! -L /usr/bin/nasdemo-taken ] && [ "$(/usr/bin/nasdemo-taken)" = 'the NAS own' ] \
    && pass "its free command linked; the one already in /usr/bin left alone" || fail "taken: $(ls -l /usr/bin/nasdemo*)"
gem uninstall nasdemo -x > /dev/null 2>&1
[ ! -e /usr/bin/nasdemo ] && [ ! -L /usr/bin/nasdemo ] && [ -f /usr/bin/nasdemo-taken ] && pass "uninstalled: its link gone, the NAS's command still there" || fail "uninstall: $(ls -l /usr/bin/nasdemo*)"

echo '== kept across a reinstall (as the Store updates it)'
sh $P/ruby/stop.sh $P/ruby > /dev/null 2>&1; sh $P/ruby/clean.sh $P/ruby > /dev/null 2>&1; sh $P/ruby/remove.sh $P/ruby > /dev/null 2>&1
[ ! -e /usr/bin/ruby ] && [ ! -e /usr/bin/thor ] && [ -d $G/gems ] && pass "removed: its links gone, the gems kept in $D" || fail "removed: $(ls -l /usr/bin/ruby /usr/bin/thor 2>&1)"
install_app
[ "$(readlink /usr/bin/thor)" = "$D/bin/thor" ] && thor version | grep -q '^Thor ' && rb -rsqlite3 -e 'print 1' | grep -q '^1$' \
    && pass "installed again: its gems still there, their commands linked again at its start (as at boot)" || fail "reinstalled: $(ls -l /usr/bin/thor 2>&1)"

echo '== its page'
page_up ruby
ST=$(get status)
[ "$(echo "$ST" | j '$d["ruby"]')" = '"4.0.9"' ] && echo "$ST" | j '$d["gems"]' | grep -q 'thor-' && echo "$ST" | j '$d["gems"]' | grep -q 'sqlite3-' \
    && [ "$(echo "$ST" | j '$d["test_server"]')" = '"running"' ] && pass "the page: Ruby $(echo "$ST" | j '$d["ruby"]'), RubyGems $(echo "$ST" | j '$d["rubygems"]'), the gems installed, the test server running" \
    || fail "status: $(echo "$ST" | head -c 300)"

echo '== removal'
finish_app
[ ! -e /usr/bin/ruby ] && [ ! -e /usr/bin/gem ] && [ ! -e /usr/bin/thor ] && pass 'its links all gone' || fail "links left: $(ls -l /usr/bin | grep -E "$P/ruby|$D")"
