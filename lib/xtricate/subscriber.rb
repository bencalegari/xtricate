require_relative "config"

module Xtricate
  Subscriber = Struct.new(
    :id, :email, :accounts, :bluesky_accounts, :timezone, :lookback_days,
    keyword_init: true
  ) do
    def since
      Time.now - (lookback_days * 24 * 60 * 60)
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
        lookback_days: lookback.nil? ? defaults.lookback_days : Integer(lookback)
      )
    end

    def presence(str)
      s = str.to_s.strip
      s.empty? ? nil : s
    end
  end
end
