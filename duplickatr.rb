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


per_page = 100
jobs     = 0
queued   = 0

class SafeProgressBar
  def initialize()
    @lock = Mutex.new
    @bar  = ProgressBar.create(:format => '%a %B %p%% %t')

    Thread.new do
      while true do
        @log.synchronize { @bar.refresh }
        sleep 1
      end
    end
  end

  def increment
    @lock.synchronize { @bar.increment }
  end

  def title=(title)
    @lock.synchronize { @bar.title = title }
  end

  def total=(total)
    @lock.synchronize { @bar.total = total }
  end

  def log(s)
    @lock.synchronize { @bar.log(s) }
  end

  def progress_mark=(p)
    @lock.synchronize { @bar.progress_mark = p }
  end
end

semaphore       = Mutex.new
queue           = WorkQueue.new(32)
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
    puts "You are now authenticated as #{login.username} with token " +
      "#{flickr.access_token} and secret #{flickr.access_secret}"
  rescue FlickRaw::FailedResponse => e
    puts "Authentication failed : #{e.msg}"
  end
end

$progress = SafeProgressBar.new

$progress.log("Starting downloads from #{Time.at(min_upload_date.to_i)}")

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
      $progress.log("#{queue.cur_tasks} jobs remain on queue. Done #{photo.url} as #{photo.hash}")
      $progress.increment
    rescue Exception => e
      $progress.log(e)
    end
  end
end

UploadJob = Struct.new(:semaphore, :queue, :db, :photo, :hash) do
  def upload
    size = Filesize.new(File.stat(photo).size).pretty
    $progress.log("Uploading #{photo} #{size}")
    $progress.increment
    flickr.upload_photo(photo,  :tags      => make_hash_tag(hash),
                                :is_public => 0,
                                :is_friend => 0,
                                :is_family => 1)
    #$progress.log("#{photo} uploaded #{queue.cur_tasks} jobs remain on the queue")
    
  end
end
count = 0
$progress.title = "Downloading photos"
for page in 1..500 do

  $progress.log("Downloading photo metadata from #{per_page * (page-1)} to #{page * per_page}")

  photos = semaphore.synchronize do
    flickr.people.getPhotos(:user_id         => login.id,
                            :extras          => 'tags,machine_tags,url_o',
                            :page            => page,
                            :per_page        => per_page,
                            :min_upload_date => min_upload_date)
  end
  break if photos.size == 0

  $progress.log("Downloaded data for #{photos.size} photos")

  photos.each do |p|
    hashes = p.machine_tags.split.map { |tag| sha_tag.match(tag) }
    if hashes.empty?
      queued = queued + 1
      photo  = Photo.new(p.id, p.url_o, '')
      job    = DownloadJob.new(semaphore, queue, db, photo)
      queue.enqueue_b { job.download }
    else
      begin
        photo = Photo.new(p.id, p.url_o, hashes.first[1])
        semaphore.synchronize { photo.store_metadata_in(db) }
     rescue Exception => e
        $progress.log("Something odd is up with this photo: #{e} #{p}")
     end
    end
  end
  count += photos.size
end
$progress.total = queued
$progress.log("Total: #{count} to process: #{queued}")

queue.join
queue           = WorkQueue.new(32)
db['meta:min_upload_date'] = started_at
$progress = SafeProgressBar.new
$progress.log("Download Complete. Download will start at #{Time.at(started_at)} next time")

iphoto_masters = File.join(`defaults read com.apple.iPhoto RootDirectory`.strip, '/Masters/')
count = 0

$progress.log("Scanning iPhoto directory")
files = Find.find(iphoto_masters).reject {|f| FileTest.directory?(f) }.sort
$progress.total = files.size


files.each do |path|

  hash = db["file:#{path}"]
  if hash.nil?
    $progress.log("Hashing local image file: #{path}")
    hash = sha1_digest_of(File.read(path))
    db["file:#{path}"] = hash
  end
      
  existing = db["photo:sha1:#{hash}"]

  if existing.nil?
    job = UploadJob.new(semaphore, queue, db, path, hash)
    queue.enqueue_b { job.upload }
    count = count + 1
  else
    #puts("Found exiting tag for #{hash} - not uploading")
    $progress.increment
  end
  
end

queue.join

