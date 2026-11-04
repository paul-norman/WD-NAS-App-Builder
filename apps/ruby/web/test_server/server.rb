# The Ruby app's test server: a page showing that Ruby works on the NAS, with its version and those of the libraries
# its standard extensions use. Started by the app's start.sh, on port 30291 (any address):
#     ruby server.rb
require 'socket'
require 'openssl'
require 'psych'
require 'zlib'

PORT = 30_291

page = File.read(File.join(__dir__, 'static', 'index.html'))
         .sub('{ruby}', RUBY_DESCRIPTION)
         .sub('{openssl}', OpenSSL::OPENSSL_LIBRARY_VERSION)
         .sub('{libyaml}', Psych::LIBYAML_VERSION)
         .sub('{zlib}', Zlib::ZLIB_VERSION)
         .b
server = TCPServer.new('0.0.0.0', PORT)

loop do
  client = server.accept

  Thread.new(client) do |connection|
    # The request line and headers are read, and every request gets the page
    while (line = connection.gets) && line != "\r\n"
    end

    connection.write("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: #{page.bytesize}\r\n" \
                     "Connection: close\r\n\r\n#{page}")
  rescue SystemCallError, IOError
    nil
  ensure
    connection.close
  end
end
