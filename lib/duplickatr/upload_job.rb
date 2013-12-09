
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
