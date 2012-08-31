require "uservoice/version"
require 'uservoice/uri_parameters'
require 'rubygems'
require 'ezcrypto'
require 'json'
require 'cgi'
require 'base64'
require 'oauth'

module UserVoice
  EMAIL_FORMAT = %r{^(\w[-+.\w!\#\$%&'\*\+\-/=\?\^_`\{\|\}~]*@([-\w]*\.)+[a-zA-Z]{2,9})$}

  class Unauthorized < RuntimeError; end
 
  def self.generate_sso_token(subdomain_key, sso_key, user_hash, valid_for = 5 * 60)
    user_hash[:expires] ||= (Time.now.utc + valid_for).to_s unless valid_for.nil?
    unless user_hash[:email].to_s.match(EMAIL_FORMAT)
      raise Unauthorized.new("'#{user_hash[:email]}' is not a valid email address")
    end
    unless sso_key.to_s.length > 1
      raise Unauthorized.new("Please specify your SSO key")
    end

    key = EzCrypto::Key.with_password(subdomain_key, sso_key)
    encrypted = key.encrypt(user_hash.to_json)
    encoded = Base64.encode64(encrypted).gsub(/\n/,'')

    return CGI.escape(encoded)
  end

  class Client
    def initialize(subdomain_name, api_key, api_secret, attrs={})
      @subdomain_name = subdomain_name
      @callback = attrs[:callback]
      @consumer = OAuth::Consumer.new(api_key, api_secret, { 
        :site => "#{attrs[:protocol] || 'https'}://#{@subdomain_name}.#{attrs[:uservoice_domain] || 'uservoice.com'}"
      })
      @consumer_token = OAuth::AccessToken.new(@consumer)
      self.access_token_attributes = attrs[:access_token] if attrs[:access_token]
    end

    def request_token
      @request_token ||= @consumer.get_request_token(:oauth_callback => @callback)
    end

    def authorize_url
      request_token.authorize_url
    end

    def access_token_attributes=(attrs)
      access_token = OAuth::AccessToken.new(@consumer)
      access_token.token = attrs[:oauth_token] || attrs['oauth_token']
      access_token.secret = attrs[:oauth_token_secret] || attrs['oauth_token_secret']
      @access_token = access_token
    end

    def access_token
      @access_token
    end

    def access_token_attributes
      {
       :oauth_token => @access_token.token,
       :oauth_token_secret => @access_token.secret
      } if @access_token
    end

    def login_verified_user(oauth_verifier)
      @access_token = request_token.get_access_token(:oauth_verifier => oauth_verifier)
    end

    def logout
      @request_token = @access_token = nil
    end

    def login_as_owner
      logout
      authorize_response = JSON.parse(post('/api/v1/users/login_as_owner.json', {
        'request_token' => request_token.token
      }).body)
      if authorize_response['token']
        self.access_token_attributes = authorize_response['token']
      else
        raise Unauthorized.new("Could not get Access Token: #{authorize_response}")
      end
    end

    def login_as(email)
      unless email.to_s.match(EMAIL_FORMAT)
        raise Unauthorized.new("'#{email}' is not a valid email address")
      end
      logout
      authorize_response = JSON.parse(post('/api/v1/users/login_as.json', {
        'user[email]' => email,
        'request_token' => request_token.token
      }).body)
      if authorize_response['token']
        self.access_token_attributes = authorize_response['token']
      else
        raise Unauthorized.new("Could not get Access Token: #{authorize_response}")
      end
    end

    def logged_in?
      !!@access_token
    end

    def request(method, uri, params={}, *args)
      flatten_params = UriParameters.concat_keys_to_params(params)
      (@access_token || @consumer_token).request(method, uri, flatten_params, *args)
    end

    %w(get post delete put).each do |method|
      define_method(method) do |*args|
        request(method, *args)
      end
    end
  end
end
