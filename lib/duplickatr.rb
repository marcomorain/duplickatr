require 'thor'

$:.unshift File.dirname(__FILE__)

require 'duplickatr/flickr'

class Duplickatr < Thor
  option :reset, :type => :boolean, :default => false
  desc "synchronize", "Ensure that all local photos are uploaded to Flickr"
  def synchronize()

    client = Flickr.new

    client.reset if options[:reset]

    connected = client.reconnect

    if !connected
      client.login { |question| ask(question) }
    end

    client.download

  end

end

Duplickatr.start(ARGV)
