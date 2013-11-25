#require 'flickraw'
require 'flickraw-cached'
require 'active_support'
require 'net/http'
require 'open-uri'
require 'digest/sha1'

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

per_page = 100
count = 0

all_photos = []
for page in 1..500 do
  photos = flickr.people.getPhotos(:user_id  => login.id,
                                   :extras   => 'tags,machine_tags,url_o',
                                   :page     => page,
                                   :per_page => per_page)
  break if photos.size == 0

  puts("Downloaded data for #{photos.size} photos")

  photos.each do |p|
    #puts p.inspect
    hashes = p.machine_tags.split.select { |tag| tag.start_with? 'hash:sha1' }

    if hashes.empty?
      all_photos << p
    else
      puts(hashes)
    end
  end
  count += photos.size
end
puts("Total: #{count} To process: #{all_photos.count}")

all_photos.each do |p|
  puts("Downloading #{p.url_o}")
  open(p.url_o, 'rb') do |read_file|
    hash = Digest::SHA1.hexdigest(read_file.read)
    flickr.photos.addTags(:photo_id => p.id, :tags => "hash:sha1=#{hash}")
    puts("Setting hash tag to #{p.id} as #{hash}")
  end
end

