Photo = Struct.new(:id, :url, :hash) do
  def to_h
    Hash[each_pair.to_a]
  end

  def hash_tag
    make_hash_tag(hash)
  end

  def store_metadata_in(db)    
    puts("Storing id(#{id}) and sha1(#{hash}) as #{to_h}")
    db["photo:id:#{id}"]     = to_h
    db["photo:sha1:#{hash}"] = to_h
  end
end
