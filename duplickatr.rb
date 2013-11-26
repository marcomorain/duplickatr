#require 'flickraw'
require 'flickraw-cached'
require 'active_support'
require 'net/http'
require 'open-uri'
require 'digest/sha1'
require 'work_queue'
require 'thread'
require 'leveldb'


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
count    = 0
queued   = 0

semaphore       = Mutex.new
queue           = WorkQueue.new(64)
db              = LevelDB::DB.new File.join(File.expand_path('~'), '.duplickatr.ldb')
sha_tag         = /hash:sha1=(\h{40})/
min_upload_date = db['meta:min_upload_date'] ||= Time.new(2004, 2, 1).to_i
started_at      = Time.now.to_i

puts("Starting downloads from #{Time.at(min_upload_date.to_i)}")


Photo = Struct.new(:id, :url, :hash) do
  def to_h
    Hash[each_pair.to_a]
  end

  def hash_tag
    raise 'Unknown SHA1' if hash.empty?
    "hash:sha1=#{hash}"
  end

  def store_metadata_in(db)
    db["photo:sha1:#{hash}"] = db["photo:id:#{id}"] = to_h
  end
end

DownloadJob = Struct.new(:semaphore, :queue, :db, :photo) do
  def download
    open(photo.url, 'rb') do |read_file|
      photo.hash = Digest::SHA1.hexdigest(read_file.read)
      semaphore.synchronize do
        flickr.photos.addTags(:photo_id => photo.id,
                              :tags     => photo.hash_tag)
        photo.store_metadata_in(db)
      end
      print("#{queue.cur_tasks} jobs remain on queue. Done #{photo.url} as #{photo.hash}\r")
    end
  end
end

for page in 1..500 do

  puts("Downloading photo metadata from #{per_page * (page-1)} to #{page * per_page}")

  photos = semaphore.synchronize do
    flickr.people.getPhotos(:user_id         => login.id,
                            :extras          => 'tags,machine_tags,url_o',
                            :page            => page,
                            :per_page        => per_page,
                            :min_upload_date => min_upload_date)
  end
  break if photos.size == 0

  puts("Downloaded data for #{photos.size} photos")

  photos.each do |p|
    hashes = p.machine_tags.split.map { |tag| sha_tag.match(tag) }
    if hashes.empty?
      queued = queued + 1
      photo  = Photo.new(p.id, p.url_o, '')
      job    = DownloadJob.new(semaphore, queue, photo)
      queue.enqueue_b { job.download }
    else
      photo = Photo.new(p.id, p.url_o, hashes.first[1] )
      semaphore.synchronize { photo.store_metadata_in(db) }
    end
  end
  count += photos.size
end
puts("Total: #{count} to process: #{queued}")

queue.join
db['meta:min_upload_date'] = started_at
puts("Complete. Download will start at #{Time.at(started_at)} next time")


