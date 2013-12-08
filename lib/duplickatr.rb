#!/usr/bin/env ruby
require 'flickraw'
require 'active_support'
require 'digest/sha1'
require 'work_queue'
require 'thread'
require 'leveldb'
require 'pathname'
require 'open-uri'
require 'find'
require 'filesize'
require 'ruby-progressbar'
require 'thor'

PER_PAGE = 500
jobs     = 0
queued   = 0

$db              = LevelDB::DB.new File.join(File.expand_path('~'), '.duplickatr.ldb')
SHA_TAG          = /hash:sha1=(\h{40})/
$min_upload_date = $db['meta:min_upload_date'] ||= Time.new(2004, 2, 1).to_i
STARTED_AT      = Time.now.to_i

api_key       = '077eac1e7e41542df52529f8b749aaf2'
secret_key    = '27eea421ceed4826'
access_token  = $db['meta:access_token']
access_secret = $db['meta:access_secret']

FlickRaw.api_key       = api_key
FlickRaw.shared_secret = secret_key


$login = {}

unless access_token.nil?
  flickr.access_token  = access_token
  flickr.access_secret = access_secret

  # From here you are logged:
  $login = flickr.test.login
  puts "You are now authenticated as #{$login.username}"
else
  begin
    token = flickr.get_request_token
    auth_url = flickr.get_authorize_url(token['oauth_token'], :perms => 'delete')

    puts "Open this url in your process to complete the authication process : #{auth_url}"
    puts "Copy here the number given when you complete the process."
    verify = gets.strip

    flickr.get_access_token(token['oauth_token'], token['oauth_token_secret'], verify)
    $login = flickr.test.login

    $db['meta:access_token']  = flickr.access_token
    $db['meta:access_secret'] = flickr.access_secret
    puts "You are now authenticated as #{login.username} with token " +
      "#{flickr.access_token} and secret #{flickr.access_secret}"
  rescue FlickRaw::FailedResponse => e
    puts "Authentication failed : #{e.msg}"
  end
end

def make_hash_tag(hash)
  raise 'Unknown SHA1' if hash.empty?
  "hash:sha1=#{hash}"
end

Photo = Struct.new(:id, :url, :hash) do
  def to_h
    Hash[each_pair.to_a]
  end

  def hash_tag
    make_hash_tag(hash)
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
      puts("#{queue.cur_tasks} jobs remain on queue. Done #{photo.url} as #{photo.hash}")
    rescue Exception => e
      puts(e)
    end
  end
end

UploadJob = Struct.new(:semaphore, :queue, :db, :photo, :hash) do
  def upload
    begin
      size = Filesize.new(File.stat(photo).size).pretty
      puts("Uploading #{photo} #{size} #{queue.cur_tasks} jobs still on the queue")
      flickr.upload_photo(photo,  :tags      => make_hash_tag(hash),
                                  :is_public => 0,
                                  :is_friend => 0,
                                  :is_family => 1)
      puts("#{photo} uploaded #{queue.cur_tasks} jobs remain on the queue")
    rescue => e
      puts("Error uploading")
      puts(e)
    end
    
  end
end



NUM_PHOTOS = flickr.people.getInfo(:user_id => $login.id).photos.count
NUM_PAGES  = (NUM_PHOTOS / PER_PAGE.to_f).ceil

puts("Starting downloads from #{Time.at($min_upload_date.to_i)} num pages: #{NUM_PAGES}")
puts("Downloading photo metadata")


class Duplickatr < Thor

  desc "hello NAME", "say hello to NAME"
  def download(time=nil)

    queue = WorkQueue.new(32)

    @semaphore = Mutex.new

    (1..NUM_PAGES).each do |page|

      photos = @semaphore.synchronize do
        flickr.people.getPhotos(:user_id         => $login.id,
                                :extras          => 'tags,machine_tags,url_o',
                                :page            => page,
                                :per_page        => PER_PAGE,
                                :min_upload_date => $min_upload_date)
      end
      break if photos.size == 0

      photos.each do |p|
        hashes = p.machine_tags.split.map { |tag| SHA_TAG.match(tag) }
        if hashes.empty?
          queued = queued + 1
          photo  = Photo.new(p.id, p.url_o, '')
          job    = DownloadJob.new(@semaphore, queue, db, photo)
          queue.enqueue_b { job.download }
        else
          begin
            photo = Photo.new(p.id, p.url_o, hashes.first[1])
            @semaphore.synchronize { photo.store_metadata_in($db) }
          rescue Exception => e
            puts("Something odd is up with this photo: #{e} #{p}")
         end
        end
      end
    end

    queue.join

    puts("Download Complete. Download will start at #{Time.at(STARTED_AT)} next time")

    queue           = WorkQueue.new(2)
    $db['meta:min_upload_date'] = STARTED_AT

    iphoto_masters = File.join(`defaults read com.apple.iPhoto RootDirectory`.strip, '/Masters/')

    puts("Scanning iPhoto directory")
    files = Find.find(iphoto_masters).reject {|f| FileTest.directory?(f) }.sort

    puts("Uploading photos")

    files.each do |path|

      hash = $db["file:#{path}"]
      if hash.nil?
        puts("Hashing local image file: #{path}")
        hash = sha1_digest_of(File.read(path))
        db["file:#{path}"] = hash
      end
          
      existing = $db["photo:sha1:#{hash}"]

      if existing.nil?
        job = UploadJob.new(@semaphore, queue, $db, path, hash)
        queue.enqueue_b { job.upload }
      end
      
    end

    queue.join

    puts("All photos uploaded.")

  end
end

Duplickatr.start(ARGV)
