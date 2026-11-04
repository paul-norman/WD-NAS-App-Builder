# The Ruby app's settings for RubyGems (rubygems/defaults/operating_system.rb, which RubyGems loads whenever Ruby
# starts - see apps/ruby/README.md):
#  - Gems are installed in the app's data folder (Nas_Prog/_ruby/gems - kept when the app is updated or removed), and
#    their commands in Nas_Prog/_ruby/bin, linked into /usr/bin (as root, never over a command that's already there).
#    The app's init.sh links them again at every boot (the NAS's /usr/bin is rebuilt then). The gems that come with
#    Ruby stay in the app's own folder, and are found there too.
#  - Ruby's OpenSSL trusts the app's bundle of certificate authorities (Mozilla's, as curl publishes it), unless
#    SSL_CERT_FILE or SSL_CERT_DIR says otherwise.

module Gem
  # The app's own folder (Nas_Prog/ruby/binaries), and its data folder (Nas_Prog/_ruby)
  RUBY_APP_HOME = RbConfig::TOPDIR
  RUBY_APP_DATA = File.expand_path('../../_ruby', RUBY_APP_HOME)
  # The gems that come with Ruby
  RUBY_APP_GEMS = File.join(RUBY_APP_HOME, 'lib', 'ruby', 'gems', RbConfig::CONFIG['ruby_version'])
  # Where gems' commands are linked, for every shell
  RUBY_APP_LINKS = '/usr/bin'

  class << self
    # Where gems are installed: the app's data folder
    def default_dir
      File.join(RUBY_APP_DATA, 'gems', RbConfig::CONFIG['ruby_version'])
    end

    # Where gems are looked for: a user's own, the installed ones, and those that come with Ruby
    def default_path
      [user_dir, default_dir, RUBY_APP_GEMS]
    end

    # Where gems' commands are installed
    def default_bindir
      File.join(RUBY_APP_DATA, 'bin')
    end

    # The specifications of Ruby's default gems (bundler, json...), which come with it
    def default_specifications_dir
      File.join(RUBY_APP_GEMS, 'specifications', 'default')
    end

    # Links a gem's commands into /usr/bin - or, for a gem being uninstalled, removes the links of those that went.
    # Only as root, and only links of the app's own: a command that's already there (e.g. the NAS's) is left alone.
    def ruby_app_link(spec, bindir, remove)
      return unless Process.uid.zero? && File.directory?(RUBY_APP_LINKS)

      spec.executables.each do |name|
        link   = File.join(RUBY_APP_LINKS, name)
        target = File.join(bindir, name)
        ours   = File.symlink?(link) && File.readlink(link).start_with?(RUBY_APP_DATA + '/', RUBY_APP_HOME + '/')

        if remove
          File.delete(link) if ours && File.readlink(link) == target && !File.exist?(target)
        elsif File.exist?(target) && (ours || !(File.exist?(link) || File.symlink?(link)))
          File.delete(link) if ours
          File.symlink(target, link)
        end
      rescue SystemCallError
        next
      end
    end
  end
end

Gem.post_install { |installer| Gem.ruby_app_link(installer.spec, installer.bin_dir, false) }
# (An uninstaller's bin_dir is only set when one was given: otherwise RubyGems uses the gem's home's)
Gem.post_uninstall do |uninstaller|
  Gem.ruby_app_link(uninstaller.spec, uninstaller.bin_dir || Gem.bindir(uninstaller.spec.base_dir), true)
end

unless ENV['SSL_CERT_FILE'] || ENV['SSL_CERT_DIR']
  bundle = File.join(Gem::RUBY_APP_HOME, 'etc', 'cacert.pem')
  ENV['SSL_CERT_FILE'] = bundle if File.file?(bundle)
end
