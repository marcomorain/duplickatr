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
