require "yaml"

module Xtricate
  # Loads non-secret knobs from config.yml and secrets from ENV (populated by
  # dotenv locally, or GitHub Actions secrets in CI). Validates what's needed
  # for the requested mode so failures are loud and early.
  class Config
    attr_reader :lookback_days, :model, :max_tweets_per_account,
                :recipient, :sender_name, :timezone,
                :preferred_long_form_outlets, :accounts,
                :twitterapi_key, :anthropic_key,
                :gmail_address, :gmail_app_password

    def self.load(root: Dir.pwd)
      yml = YAML.safe_load_file(File.join(root, "config.yml")) || {}
      new(yml)
    end

    def initialize(yml)
      @lookback_days          = Integer(yml.fetch("lookback_days", 7))
      @model                  = yml.fetch("model", "claude-sonnet-4-6")
      @max_tweets_per_account = Integer(yml.fetch("max_tweets_per_account", 100))
      @sender_name            = yml.fetch("sender_name", "Xtricate Digest")
      @recipient              = ENV["XTRICATE_RECIPIENT"]
      @timezone               = yml.fetch("timezone", "America/New_York")
      @preferred_long_form_outlets = Array(yml["preferred_long_form_outlets"]).map { |h| h.to_s.downcase.strip }.reject(&:empty?)

      @twitterapi_key    = ENV["TWITTERAPI_IO_KEY"]
      @anthropic_key     = ENV["ANTHROPIC_API_KEY"]
      @gmail_address     = ENV["GMAIL_ADDRESS"]
      @gmail_app_password = ENV["GMAIL_APP_PASSWORD"]
      @accounts          = self.class.parse_accounts(ENV["XTRICATE_ACCOUNTS"])
    end

    # The cutoff time; tweets older than this are ignored.
    def since
      Time.now - (lookback_days * 24 * 60 * 60)
    end

    # Validate the credentials/config required for a given run mode.
    # mode: :fetch_only, :dry_run, or :full
    def validate!(mode:)
      errs = []
      errs << "XTRICATE_ACCOUNTS is empty — set it in .env (or as a GitHub secret) to a comma- or newline-separated list of handles" if accounts.empty?
      errs << "TWITTERAPI_IO_KEY is not set" if blank?(twitterapi_key)

      if %i[dry_run full].include?(mode)
        errs << "ANTHROPIC_API_KEY is not set" if blank?(anthropic_key)
      end

      if mode == :full
        errs << "XTRICATE_RECIPIENT is not set" if blank?(recipient)
        errs << "GMAIL_ADDRESS is not set" if blank?(gmail_address)
        errs << "GMAIL_APP_PASSWORD is not set" if blank?(gmail_app_password)
      end

      raise ConfigError, errs.join("\n  - ").prepend("Config problems:\n  - ") if errs.any?

      self
    end

    # Parse XTRICATE_ACCOUNTS — accepts comma- and/or newline-separated handles,
    # tolerates leading "@", ignores blank lines and lines starting with "#".
    def self.parse_accounts(raw)
      return [] if raw.nil? || raw.to_s.strip.empty?

      raw.split(/[,\n]/).filter_map do |entry|
        entry = entry.strip
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
