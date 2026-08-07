require "yaml"

module Xtricate
  # Loads non-secret global knobs from config.yml and shared secrets from ENV
  # (populated by dotenv locally, or GitHub Actions secrets in CI).
  class Config
    attr_reader :lookback_days, :model, :max_tweets_per_account,
                :sender_name, :timezone,
                :preferred_long_form_outlets,
                :include_replies, :max_solo_picks,
                :max_payload_tweets, :payload_tweets_per_account,
                :max_discoveries, :fetch_qps,
                :twitterapi_key, :anthropic_key,
                :gmail_address, :gmail_app_password,
                :subscribers_raw

    def self.load(root: Dir.pwd)
      yml = YAML.safe_load_file(File.join(root, "config.yml")) || {}
      new(yml)
    end

    def initialize(yml)
      @lookback_days          = Integer(yml.fetch("lookback_days", 7))
      @model                  = yml.fetch("model", "claude-sonnet-4-6")
      @max_tweets_per_account = Integer(yml.fetch("max_tweets_per_account", 100))
      @sender_name            = yml.fetch("sender_name", "Xtricate Digest")
      @timezone               = yml.fetch("timezone", "America/New_York")
      @preferred_long_form_outlets = Array(yml["preferred_long_form_outlets"]).map { |h| h.to_s.downcase.strip }.reject(&:empty?)

      @include_replies = yml.key?("include_replies") ? !!yml["include_replies"] : false
      @max_solo_picks                 = Integer(yml.fetch("max_solo_picks", 25))
      @max_payload_tweets             = Integer(yml.fetch("max_payload_tweets", 150))
      @payload_tweets_per_account = Integer(yml.fetch("payload_tweets_per_account", 3))
      @max_discoveries                = Integer(yml.fetch("max_discoveries", 5))
      @fetch_qps                      = Integer(yml.fetch("fetch_qps", 4))

      @twitterapi_key    = ENV["TWITTERAPI_IO_KEY"]
      @anthropic_key     = ENV["ANTHROPIC_API_KEY"]
      @gmail_address     = ENV["GMAIL_ADDRESS"]
      @gmail_app_password = ENV["GMAIL_APP_PASSWORD"]
      @subscribers_raw   = ENV["XTRICATE_SUBSCRIBERS"]
    end

    def since
      Time.now - (lookback_days * 24 * 60 * 60)
    end

    # mode: :fetch_only, :dry_run, or :full
    def validate!(mode:, needs_twitter: true)
      errs = []
      errs << "TWITTERAPI_IO_KEY is not set" if needs_twitter && blank?(twitterapi_key)

      if %i[dry_run full].include?(mode)
        errs << "ANTHROPIC_API_KEY is not set" if blank?(anthropic_key)
      end

      if mode == :full
        errs << "GMAIL_ADDRESS is not set" if blank?(gmail_address)
        errs << "GMAIL_APP_PASSWORD is not set" if blank?(gmail_app_password)
      end

      raise ConfigError, errs.join("\n  - ").prepend("Config problems:\n  - ") if errs.any?

      self
    end

    def self.parse_accounts(raw)
      entries =
        case raw
        when nil then []
        when Array then raw
        else raw.to_s.split(/[,\n]/)
        end

      entries.filter_map do |entry|
        entry = entry.to_s.strip
        next if entry.empty? || entry.start_with?("#")

        entry.delete_prefix("@")
      end.uniq
    end

    private

    def blank?(str)
      str.nil? || str.strip.empty?
    end
  end

  class ConfigError < StandardError; end
end
