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
require 'duplickatr/upload_job'
require 'duplickatr/download_job'
require 'duplickatr/photo'

PER_PAGE = 500
jobs     = 0

SHA_TAG          = /hash:sha1=(\h{40})/
STARTED_AT      = Time.now.to_i

def make_hash_tag(hash)
  raise 'Unknown SHA1' if hash.empty?
  "hash:sha1=#{hash}"
end

def sha1_digest_of(content)
  Digest::SHA1.hexdigest(content)
end


class Flickr

  API_KEY    = '077eac1e7e41542df52529f8b749aaf2'
  SECRET_KEY = '27eea421ceed4826'

  def initialize()
    @db = LevelDB::DB.new(database_path)
    @semaphore = Mutex.new
    @min_upload_date = @db['meta:min_upload_date'] ||= Time.new(2004, 2, 1).to_i
  end

  def reconnect
    access_token  = @db['meta:access_token']
    access_secret = @db['meta:access_secret']

    FlickRaw.api_key       = API_KEY
    FlickRaw.shared_secret = SECRET_KEY

    flickr.access_token  = access_token
    flickr.access_secret = access_secret

    # From here you are logged:
    @login = flickr.test.login

    puts "You are now authenticated as #{@login.username}" unless @login.nil?

    return !@login.nil?

  end

  def login
    begin
      token = flickr.get_request_token
      auth_url = flickr.get_authorize_url(token['oauth_token'], :perms => 'delete')

      puts "Open this url in your process to complete the authication process : #{auth_url}"
      puts "Copy here the number given when you complete the process."
      verify = gets.strip

      flickr.get_access_token(token['oauth_token'], token['oauth_token_secret'], verify)
      @login = flickr.test.login

      unless @login.nil?
        @db['meta:access_token']  = flickr.access_token
        @db['meta:access_secret'] = flickr.access_secret
        puts "You are now authenticated as #{@login.username} with token " +
             "#{flickr.access_token} and secret #{flickr.access_secret}"
      end
      true
    rescue FlickRaw::FailedResponse => e
      puts "Authentication failed : #{e.msg}"
      false
    end
  end

  def download()

    num_photos = flickr.people.getInfo(:user_id => @login.id).photos.count
    num_pages  = (num_photos / PER_PAGE.to_f).ceil

    puts("Starting metadata download of #{num_photos} files uploaded since #{Time.at(@min_upload_date.to_i)} (in #{num_pages} batches)")
    puts("Downloading photo metadata")

    queue = WorkQueue.new(32)

    (1..num_pages).each do |page|

      photos = @semaphore.synchronize do
        flickr.people.getPhotos(:user_id         => @login.id,
                                :extras          => 'tags,machine_tags,url_o',
                                :page            => page,
                                :per_page        => PER_PAGE,
                                :min_upload_date => @min_upload_date)
      end
      break if photos.size == 0

      photos.each do |p|
        hashes = p.machine_tags.split.map { |tag| SHA_TAG.match(tag) }
        if hashes.empty?
          photo  = Photo.new(p.id, p.url_o, '')
          job    = DownloadJob.new(@semaphore, queue, @db, photo)
          queue.enqueue_b { job.download }
        else
          begin
            photo = Photo.new(p.id, p.url_o, hashes.first[1])
            @semaphore.synchronize { photo.store_metadata_in(@db) }
          rescue Exception => e
            puts("Something odd is up with this photo: #{e} #{p}")
         end
        end
      end
    end

    queue.join

    puts("Download Complete. Download will start at #{Time.at(STARTED_AT)} next time")

    queue           = WorkQueue.new(2)
    @db['meta:min_upload_date'] = STARTED_AT

    iphoto_masters = File.join(`defaults read com.apple.iPhoto RootDirectory`.strip, '/Masters/')

    puts("Scanning iPhoto directory")
    files = Find.find(iphoto_masters).reject {|f| FileTest.directory?(f) }.sort

    puts("Uploading photos")

    files.each do |path|

      hash = @db["file:#{path}"]
      if hash.nil?
        puts("Hashing local image file: #{path}")
        hash = sha1_digest_of(File.read(path))
        @db["file:#{path}"] = hash
      end

      existing = @db["photo:sha1:#{hash}"]

      if existing.nil?
        job = UploadJob.new(@semaphore, queue, @db, path, hash)
        queue.enqueue_b { job.upload }
      end

    end

    queue.join

    puts("All photos uploaded.")

  end

  private

  def database_path
    File.join(File.expand_path('~'), '.duplickatr.ldb')
  end

end

