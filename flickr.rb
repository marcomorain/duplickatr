require 'flickraw'

api_key    = '077eac1e7e41542df52529f8b749aaf2'
secret_key = '27eea421ceed4826'

access_token  = '72157638015506525-8e3b1e31d58969c9'
access_secret = '58af0996c4ea7798'

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

puts flickr.people.getPhotos(:user_id => login.id, :api_key => api_key).first