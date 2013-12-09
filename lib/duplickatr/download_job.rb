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
