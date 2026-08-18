require_relative "config"
require_relative "window"

module Xtricate
  Subscriber = Struct.new(
    :id, :email, :accounts, :bluesky_accounts, :timezone, :lookback_days,
    :include_replies, :max_solo_picks, :max_payload_tweets,
    :payload_tweets_per_account, :max_discoveries,
    keyword_init: true
  ) do
    def window(override = nil, now: Time.now)
      end_at = override&.end_at || now
      start_at = override&.start_at || (end_at - (lookback_days * 24 * 60 * 60))
      Window.new(start_at: start_at, end_at: end_at)
    end

    def since
      window.start_at
    end

    def handles
      accounts + bluesky_accounts
    end

    def empty?
      handles.empty?
    end

    def follows?(handle, source)
      list = source == :bluesky ? bluesky_accounts : accounts
      list.any? { |h| h.casecmp?(handle.to_s) }
    end
  end

  class SubscriberError < StandardError; end

  module SubscriberBuilder
    module_function

    def build(yml, id:, email:, defaults:)
      yml = {} if yml.nil?
      raise SubscriberError, "config is not a YAML mapping" unless yml.is_a?(Hash)

      email = (email || yml["email"]).to_s.strip
      raise SubscriberError, "no email" if email.empty?

      lookback = yml["lookback_days"]
      accounts = Config.parse_accounts(yml["accounts"])
      bluesky  = Config.parse_accounts(yml["bluesky_accounts"] || yml["bluesky"])

      raise SubscriberError, "no accounts or bluesky_accounts" if accounts.empty? && bluesky.empty?

      Subscriber.new(
        id: id,
        email: email,
        accounts: accounts,
        bluesky_accounts: bluesky,
        timezone: presence(yml["timezone"]) || defaults.timezone,
        lookback_days: lookback.nil? ? defaults.lookback_days : Integer(lookback),
        include_replies: flag(yml, "include_replies", defaults.include_replies),
        max_solo_picks: count(yml, "max_solo_picks", defaults.max_solo_picks),
        max_payload_tweets: count(yml, "max_payload_tweets", defaults.max_payload_tweets),
        payload_tweets_per_account:
          count(yml, "payload_tweets_per_account", defaults.payload_tweets_per_account),
        max_discoveries: count(yml, "max_discoveries", defaults.max_discoveries)
      )
    end

    def presence(str)
      s = str.to_s.strip
      s.empty? ? nil : s
    end

    def flag(yml, key, default)
      yml.key?(key) ? !!yml[key] : default
    end

    def count(yml, key, default)
      yml[key].nil? ? default : Integer(yml[key])
    end
  end
end
