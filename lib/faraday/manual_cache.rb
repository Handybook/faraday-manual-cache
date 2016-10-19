require 'faraday'

module Faraday
  # Middleware for caching Faraday responses based on a specified expiry.
  #
  # As with faraday-http-cache, it's recommended that this middleware be added
  # fairly low in the middleware stack.
  #
  # Currently accepts four arguments:
  #
  #   :expires_in    - Cache expiry, in seconds (default: 30).
  #   :logger        - A logger object to send cache hit/miss/write messages.
  #   :store         - An object (or lookup symbol) for an
  #                    ActiveSupport::Cache::Store instance. (default:
  #                    MemoryStore).
  #   :store_options - Options to pass to the store when generated based on a
  #                    lookup symvol (default: {}).
  class ManualCache < Faraday::Middleware
    def initialize(app, *args)
      super(app)
      options = args.first || {}
      @expires_in             = options.fetch(:expires_in, 30)
      @logger                 = options.fetch(:logger, nil)
      @namespace              = options.fetch(:namespace, 'faraday-manual-cache')
      @store                  = options.fetch(:store, :memory_store)
      @store_options          = options.fetch(:store_options, {})
      @ignore_http_statuses   = options.fetch(:ignore_http_statuses, [])

      @store_options[:namespace] ||= @namespace

      initialize_store
    end

    def call(env)
      dup.call!(env)
    end

    protected

    def call!(env)
      response_env = cached_response(env)

      if response_env
        response_env.response_headers['x-faraday-manual-cache'] = 'HIT'
        to_response(cached_response(env))
      else
        @app.call(env).on_complete do |response_env|
          response_env.response_headers['x-faraday-manual-cache'] = 'MISS'
          cache_response(response_env)
        end
      end
    end

    def cache_response(env)
      return unless cacheable?(env) && !env.request_headers['x-faraday-manual-cache']

      info "Cache WRITE: #{key(env)}"
      @store.write(key(env), env, expires_in: @expires_in)
    end

    def cacheable?(env)
      valid_http_method?(env.method) && valid_http_status?(env.status)
    end

    def valid_http_method?(method)
      method == :get || method == :head
    end

    def valid_http_status?(status)
      !@ignore_http_statuses.include?(status)
    end

    def cached_response(env)
      response_env = @store.fetch(key(env)) if cacheable?(env) && !env.request_headers['x-faraday-manual-cache']
      if response_env
        info "Cache HIT: #{key(env)}"
      else
        info "Cache MISS: #{key(env)}"
      end
      response_env
    end

    def info(message)
      @logger.info(message) unless @logger.nil?
    end

    def key(env)
      env.url
    end

    def initialize_store
      return unless @store.is_a? Symbol

      require 'active_support/cache'
      @store = ActiveSupport::Cache.lookup_store(@store, @store_options)
    end

    def to_response(env)
      env = env.dup
      env.response_headers['x-faraday-manual-cache'] = 'HIT'
      response = Response.new
      response.finish(env) unless env.parallel?
      env.response = response
    end
  end
end
