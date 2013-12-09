require 'thor'

$:.unshift File.dirname(__FILE__)

require 'duplickatr/flickr'

class Duplickatr < Thor

  desc "synchronize", "Ensure that all local photos are uploaded to Flickr"

  def synchronize()

    client = Flickr.new

    connected = client.reconnect

    if !connected
      client.login
    end

    client.download

  end

end

Duplickatr.start(ARGV)
