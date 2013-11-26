#!/usr/bin/env ruby
require 'flickraw'
require 'active_support'
require 'digest/sha1'
require 'work_queue'
require 'thread'
require 'leveldb'
require 'pathname'
require 'open-uri'

per_page = 100
count    = 0
queued   = 0

semaphore       = Mutex.new
queue           = WorkQueue.new(64)
db              = LevelDB::DB.new File.join(File.expand_path('~'), '.duplickatr.ldb')
sha_tag         = /hash:sha1=(\h{40})/
min_upload_date = db['meta:min_upload_date'] ||= Time.new(2004, 2, 1).to_i
started_at      = Time.now.to_i

api_key       = '077eac1e7e41542df52529f8b749aaf2'
secret_key    = '27eea421ceed4826'
access_token  = db['meta:access_token']
access_secret = db['meta:access_secret']

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

    db['meta:access_token']  = flickr.access_token
    db['meta:access_secret'] = flickr.access_secret
    puts "You are now authenticated as #{login.username} with token #{flickr.access_token} and secret #{flickr.access_secret}"
  rescue FlickRaw::FailedResponse => e
    puts "Authentication failed : #{e.msg}"
  end
end

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


def sha1_digest_of(content)
  Digest::SHA1.hexdigest(content)
end

DownloadJob = Struct.new(:semaphore, :queue, :db, :photo) do
  def download
    begin
      photo.hash = sha1_digest_of(open(photo.url).read)
      semaphore.synchronize do
        flickr.photos.addTags(:photo_id => photo.id,
                              :tags     => photo.hash_tag)
        photo.store_metadata_in(db)
      end
      print("#{queue.cur_tasks} jobs remain on queue. Done #{photo.url} as #{photo.hash}\r")
    rescue Exception => e
      puts(e)
      puts(e.backtrace.join("\n"))
    end
  end
end

UploadJob = Struct.new(:semaphore, :queue, :db, :photo) do
  def upload
    print("Upload job for #{photo}\r")
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
      puts(p.id)
      queued = queued + 1
      photo  = Photo.new(p.id, p.url_o, '')
      job    = DownloadJob.new(semaphore, queue, db, photo)
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


count = 0
File.open('/Users/marc/photo_list.txt', 'r').each_line do |line|
  line = line.strip
  hash = sha1_digest_of(File.read(line))

  existing = db["photo:sha1:#{hash}"]

  if existing.nil?
    job = UploadJob.new(semaphore, queue, db, line)
    queue.enqueue_b { job.upload }
    count = count + 1
  end

end


puts("#{count} upload jobs pending")
queue.join




