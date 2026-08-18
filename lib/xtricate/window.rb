require "time"

module Xtricate
  Window = Struct.new(:start_at, :end_at, keyword_init: true) do
    def days
      ((end_at - start_at) / 86_400.0).round
    end

    def covers?(time)
      return true if time.nil?

      time >= start_at && time < end_at
    end

    def label
      "#{start_at.strftime('%b %-d')} – #{end_at.strftime('%b %-d, %Y')}"
    end
  end

  class WindowError < StandardError; end

  module WindowParser
    module_function

    DATE_ONLY = /\A\d{4}-\d{1,2}-\d{1,2}\z/.freeze

    def parse(since: nil, until_at: nil)
      start_at = parse_bound(since, label: "--since", end_of_day: false)
      end_at = parse_bound(until_at, label: "--until", end_of_day: true)
      return nil if start_at.nil? && end_at.nil?

      if start_at && end_at && start_at >= end_at
        raise WindowError, "--since (#{start_at}) must be before --until (#{end_at})"
      end

      Window.new(start_at: start_at, end_at: end_at)
    end

    def parse_bound(raw, label:, end_of_day:)
      str = raw.to_s.strip
      return nil if str.empty?

      if str.match?(DATE_ONLY)
        date = Time.parse(str)
        return end_of_day ? date + 86_400 : date
      end

      Time.parse(str)
    rescue ArgumentError
      raise WindowError, "#{label} is not a date or timestamp: #{str.inspect}"
    end
  end
end
