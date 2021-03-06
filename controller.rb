class Controller < Sinatra::Base
  before do 
    if request.path != "/session" # don't set sessions for JSON api requests
      session[:null] = true   # weird hack to make the session object populate???
    end
    @site = Site.first_or_create :domain => request.host
  end

  get '/?' do
    title "IndieAuth - Sign in with your domain name"
    erb :index
  end

  get '/setup/?' do
    title "IndieAuth Documentation - Sign in with your domain name"
    erb :setup_instructions
  end

  get '/auth' do 
    session.clear
    session[:redirect_uri] = params[:redirect_uri]

    if params[:me].nil?
      title "Error"
      @message = "Parameter 'me' should be set to your domain name"
      erb :error
    else
      # Parse the incoming "me" link looking for all rel=me URLs
      me = params[:me]
      me = "http://#{me}" unless me.start_with?('http')

      # Normalize the URI to ensure it has a "/" at the end
      meURI = URI.parse me
      if meURI.path == ""
        meURI.path = "/" 
        me = meURI.to_s
      end

      session[:attempted_uri] = me

      user = User.first_or_create :href => me

      # Check if the entered URL is a known OAuth provider
      @provider = Provider.provider_for_url me

      # If not, find all rel=me links and look for known providers
      if @provider.nil?
        begin
          parser = RelParser.new me
          links = parser.rel_me_links
        rescue SocketError
          @message = "Host name not found: #{me}"
          title 'Error'
          return erb :error
        end

        # Save the complete list of links to the user object
        user.me_links = links.to_json
        user.save

        if links.length == 0
          @link = false
        else
          # Filter only the links we support, and save unverified "profile" records for them
          links = parser.get_supported_links
          puts "Supported links: #{links}"
          links.each do |link|
            provider = Provider.provider_for_url(link)
            profile = Profile.first_or_create({ 
              :user => user, 
              :provider => provider 
            }, 
            { 
              :href => link 
            })
          end
          # Find a provider that has a rel="me" link back to the user's profile
          links.each do |link|
            provider = Provider.provider_for_url(link)
            verified = parser.verify_link link
            if verified
              @profile = Profile.first :user => user, :provider => provider
              @profile.verified = true
              @profile.save
              @provider = provider
              @link = link
              break
            end
          end

          if @provider.nil?
            @message = "No valid authentication providers were found at #{me}"
            title "Error"
            return erb :error
          end
          puts "Found valid provider: #{@provider['code']}"
        end
      else
        # If "me" is one of our OAuth providers, use it directly
        @link = me
        @profile = Profile.first_or_create({
          :user => user,
          :provider => @provider
        }, 
        {
          :href => me,
          :verified => true
        })
      end

      if !@link
        @message = 'No rel="me" links were found on your website'
        title "Error"
        erb :error
      else
        puts "Provider: #{@provider}"
        puts "Profile: #{@profile}"
        puts "User: #{user}"

        login = Login.create :user => user, 
          :provider => @provider, 
          :profile => @profile, 
          :complete => false,
          :token => Login.generate_token,
          :redirect_uri => params[:redirect_uri]

        session[:attempted_token] = login[:token]
        session[:attempted_username] = @provider.username_for_url @link
        session[:attempted_provider_uri] = @link
        puts "Attempting authentication for #{session[:attempted_username]} via #{@provider['code']}"
        redirect "/auth/#{@provider['code']}"
      end
    end
  end

  get '/auth/:name/callback' do
    auth = request.env['omniauth.auth']
    puts "Auth complete!"
    puts "Provider: #{auth['provider']}"
    puts "UID: #{auth['uid']}"
    puts "Username: #{auth['info']['nickname']}"
    puts session

    if session[:attempted_username] != auth['info']['nickname']
      attempted_username = session[:attempted_provider_uri]
      actual_username = auth['info']['nickname']
      @message = "Your website linked to #{attempted_username}, but you were signed in as #{actual_username}"
      title "Error"
      erb :error
    else
      session[params[:name]] = auth['info']['nickname']
      session[:domain] = session[:attempted_domain]
      session[:attempted_username] = nil
      session[:attempted_domain] = nil
      session[:logged_in] = 1

      token = session[:attempted_token]
      login = Login.first :token => token

      if login.nil?
        @message = "Something went horribly wrong!"
        title "Error"
        erb :error
      else
        login.complete = true
        login.save
        if session[:redirect_uri]
          redirect_uri = URI.parse session[:redirect_uri]
          params = Rack::Utils.parse_query redirect_uri.query
          params['token'] = token
          redirect_uri.query = Rack::Utils.build_query params
          redirect redirect_uri.to_s
        else
          redirect "/success?token=#{token}"
        end
      end
    end
  end

  get '/auth/failure' do
    @message = params['message']
    title "Error"
    erb :error
  end

  get '/success' do
    if params[:token].nil?
      @message = "Missing 'token' parameter"
      title "Error"
      return erb :error
    end

    login = Login.first :token => params[:token]

    if login.nil?
      @message = "The token provided was not found"
      title "Error"
      return erb :error
    end

    @domain = login.user['href']
    title "Successfully Signed In!"
    erb :success
  end

  get '/session' do
    if params[:token].nil?
      return json_error 400, {:error => "invalid_request", :error_description => "Missing 'token' parameter"}
    end

    login = Login.first :token => params[:token]
    if login.nil?
      return json_error 404, {:error => "invalid_token", :error_description => "The token provided was not found"}
    end

    login.last_used_at = Time.now
    login.used_count = login.used_count + 1
    login.save

    json_response 200, {:me => login.user['href']}
  end

  # get '/test' do
  #   if params[:me].nil?
  #     @error = "Parameter 'me' is required"
  #     title "Error"
  #     erb :error
  #   else
  #     # Parse the incoming "me" link looking for all rel=me URLs
  #     me = params[:me]
  #     me = "http://#{me}" unless me.start_with?('http')

  #     parser = RelParser.new me
  #     @links = parser.get_supported_links
  #     puts @links

  #     title "Test"
  #     erb :results
  #   end
  # end

  get '/reset' do
    session.clear
    title "Session"
    erb :session
  end

  # get '/session' do 
  #   @session = session
  #   puts session
  #   title "Session"
  #   erb :session
  # end

  def json_error(code, data)
    return [code, {
        'Content-Type' => 'application/json;charset=UTF-8',
        'Cache-Control' => 'no-store'
      }, 
      data.to_json]
  end

  def json_response(code, data)
    return [code, {
        'Content-Type' => 'application/json;charset=UTF-8',
        'Cache-Control' => 'no-store'
      }, 
      data.to_json]
  end

end
