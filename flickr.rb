#require 'flickraw'
require 'flickraw-cached'
require 'active_support'
require 'net/http'
require 'open-uri'

api_key       = ENV['FLICKR_API_KEY']
secret_key    = ENV['FLICKR_SEC_KEY']
access_token  = ENV['FLICKR_ACCESS_TOKEN']
access_secret = ENV['FLICKR_ACCESS_SECRET']

FlickRaw.api_key       = api_key
FlickRaw.shared_secret = secret_key

login = {}

unless access_token.nil?
  flickr.access_token  = access_token
  flickr.access_secret = access_secret

  # From here you are logged:
  login = flickr.test.login
  puts "You are now authenticated as #{login.username}"
else
  begin
    token = flickr.get_request_token
    auth_url = flickr.get_authorize_url(token['oauth_token'], :perms => 'delete')

    puts "Open this url in your process to complete the authication process : #{auth_url}"
    puts "Copy here the number given when you complete the process."
    verify = gets.strip

    flickr.get_access_token(token['oauth_token'], token['oauth_token_secret'], verify)
    login = flickr.test.login
    puts "You are now authenticated as #{login.username} with token #{flickr.access_token} and secret #{flickr.access_secret}"
  rescue FlickRaw::FailedResponse => e
    puts "Authentication failed : #{e.msg}"
  end
end

per_page = 3

count = 0
for page in 1..1 do
  photos = flickr.people.getPhotos(:user_id  => login.id,
                                   :extras   => 'tags,machine_tags,url_o',
                                   :page     => page,
                                   :per_page => per_page)
  break if photos.size == 0

  photos.each do |p|
    puts p.inspect

    File.open("tmp/#{p.id}.jpg", 'wb') do |saved_file|
      open(p.url_o, 'rb') do |read_file|
      saved_file.write(read_file.read)
    end
  end

  end
  count += photos.size
end
puts("Total: #{count}")
