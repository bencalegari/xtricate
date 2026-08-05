require "faraday"
require "json"
require "uri"
require "yaml"

require_relative "config"
require_relative "subscriber"

module Xtricate
  class SubscriberSource
    LOCAL_FILE = "subscribers.local.yml".freeze
    ALLOWED_HOSTS = %w[gist.github.com gist.githubusercontent.com].freeze
    API_HOST = "https://api.github.com".freeze
    PREFERRED_FILES = %w[xtricate.yml xtricate.yaml].freeze
    GIST_ID = /\A[0-9a-f]{8,}\z/i.freeze

    Resolution = Struct.new(:subscribers, :origin, :failures, keyword_init: true) do
      def gists? = origin == :gists
    end

    def self.resolve(config:, root: Dir.pwd, path: nil, logger: nil, conn: nil)
      new(config: config, root: root, logger: logger, conn: conn).resolve(path: path)
    end

    def initialize(config:, root: Dir.pwd, logger: nil, conn: nil)
      @config = config
      @root = root
      @logger = logger
      @conn = conn
    end

    def resolve(path: nil)
      local = File.join(@root, LOCAL_FILE)

      if path
        from_file(path, origin: :file)
      elsif File.exist?(local)
        from_file(local, origin: :local)
      elsif presence(@config.subscribers_raw)
        from_gists(@config.subscribers_raw)
      else
        raise ConfigError, <<~MSG
          No subscribers. Either create #{LOCAL_FILE} (see subscribers.example.yml)
          or set XTRICATE_SUBSCRIBERS to "email|gist_url" entries, one per line.
        MSG
      end
    end

    def self.parse_entries(raw)
      pairs = []
      problems = []
      position = 0

      raw.to_s.split("\n").each do |line|
        line = line.strip
        next if line.empty? || line.start_with?("#")

        line.split(",").each do |entry|
          entry = entry.strip
          next if entry.empty?

          position += 1
          email, url = entry.split("|", 2).map { |s| s.to_s.strip }
          if email.empty? || url.to_s.empty? || !email.include?("@")
            problems << position
            next
          end

          pairs << [email, url]
        end
      end

      [pairs, problems]
    end

    private

    def from_file(path, origin:)
      raise ConfigError, "subscribers file not found: #{path}" unless File.exist?(path)

      raw = YAML.safe_load_file(path)
      entries = raw.is_a?(Array) ? raw : [raw]
      failures = []

      subscribers = entries.each_with_index.filter_map do |entry, i|
        id = label(i)
        begin
          SubscriberBuilder.build(entry, id: id, email: nil, defaults: @config)
        rescue StandardError => e
          failures << [id, e.message]
          nil
        end
      end

      raise ConfigError, "#{path} defines no usable subscribers" if subscribers.empty?

      log "Subscribers: #{subscribers.size} from #{File.basename(path)}."
      Resolution.new(subscribers: subscribers, origin: origin, failures: failures)
    end

    def from_gists(raw)
      pairs, problems = self.class.parse_entries(raw)
      failures = problems.map { |n| ["entry-#{n}", "malformed XTRICATE_SUBSCRIBERS entry"] }
      raise ConfigError, "XTRICATE_SUBSCRIBERS has no usable entries" if pairs.empty?

      subscribers = pairs.each_with_index.filter_map do |(email, url), i|
        id = label(i)
        mask(url)
        begin
          SubscriberBuilder.build(fetch_gist_config(url), id: id, email: email, defaults: @config)
        rescue StandardError => e
          failures << [id, e.message]
          nil
        end
      end

      raise ConfigError, "no subscriber gists could be loaded" if subscribers.empty?

      log "Subscribers: #{subscribers.size} of #{pairs.size} gist config(s) loaded."
      Resolution.new(subscribers: subscribers, origin: :gists, failures: failures)
    end

    def fetch_gist_config(url)
      uri = parse_allowed(url)

      if uri.host == "gist.githubusercontent.com"
        YAML.safe_load(get!(uri.to_s))
      else
        gist = JSON.parse(get!("#{API_HOST}/gists/#{gist_id(uri)}"))
        name, file = pick_file(gist["files"])
        body = file["truncated"] ? get!(file["raw_url"]) : file["content"]
        raise SubscriberError, "#{name} is empty" if body.to_s.strip.empty?

        YAML.safe_load(body)
      end
    end

    def parse_allowed(url)
      uri = URI.parse(url.to_s)
      unless uri.is_a?(URI::HTTPS) && ALLOWED_HOSTS.include?(uri.host)
        raise SubscriberError, "config URL must be an https gist on #{ALLOWED_HOSTS.join(' or ')}"
      end

      uri
    rescue URI::InvalidURIError
      raise SubscriberError, "config URL is not a valid URL"
    end

    def gist_id(uri)
      id = uri.path.split("/").reverse.find { |seg| seg.match?(GIST_ID) }
      raise SubscriberError, "no gist id in URL" if id.nil?

      id
    end

    def pick_file(files)
      raise SubscriberError, "gist has no files" if files.nil? || files.empty?

      name = PREFERRED_FILES.find { |f| files.key?(f) } ||
             files.keys.find { |f| f.match?(/\.ya?ml\z/i) } ||
             (files.size == 1 ? files.keys.first : nil)
      raise SubscriberError, "gist has no .yml file" if name.nil?

      [name, files[name]]
    end

    def get!(url)
      res = conn.get(url)
      raise SubscriberError, "gist request failed (HTTP #{res.status})" unless res.status == 200

      res.body
    end

    def conn
      @conn ||= Faraday.new do |f|
        f.headers["Accept"] = "application/vnd.github+json"
        f.headers["User-Agent"] = "xtricate"
        token = presence(ENV["GITHUB_TOKEN"])
        f.headers["Authorization"] = "Bearer #{token}" if token
        f.options.timeout = 15
        f.options.open_timeout = 8
      end
    end

    def mask(url)
      return unless ENV["GITHUB_ACTIONS"]

      $stdout.puts "::add-mask::#{url}"
    end

    def label(index) = "subscriber-#{index + 1}"

    def presence(str)
      s = str.to_s.strip
      s.empty? ? nil : s
    end

    def log(msg) = @logger&.puts(msg)
  end
end
