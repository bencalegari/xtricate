require "faraday"
require "json"

module Xtricate
  module Http
    MAX_RETRY_AFTER = 60

    class Error < StandardError
      attr_reader :status, :retry_after

      def initialize(status:, body:, retry_after: nil)
        @status = status
        @retry_after = retry_after
        super("HTTP #{status}: #{body.to_s[0, 200]}")
      end

      def retryable?
        status == 429 || status >= 500
      end
    end

    RETRYABLE = [Error, Faraday::Error, JSON::ParserError].freeze

    def raise_unless_ok(resp)
      return if resp.success?

      raise Error.new(status: resp.status, body: resp.body, retry_after: retry_after_for(resp))
    end

    private

    def with_retries(label)
      attempt = 0
      loop do
        attempt += 1
        @throttle.acquire
        begin
          return yield
        rescue *RETRYABLE => e
          raise e if attempt > @max_retries || !retryable_error?(e)

          delay = backoff(attempt, e)
          log "  … #{label} retry #{attempt}/#{@max_retries} in #{delay.round(1)}s: #{e.message[0, 80]}"
          @sleeper.call(delay)
        end
      end
    end

    def retryable_error?(error)
      return error.retryable? if error.is_a?(Error)

      true
    end

    def backoff(attempt, error)
      wait = error.is_a?(Error) ? error.retry_after : nil
      wait || ((2**(attempt - 1)) * 0.5) + (rand * 0.25)
    end

    def retry_after_for(resp)
      raw = resp.respond_to?(:headers) ? resp.headers&.[]("retry-after") : nil
      return nil if raw.nil? || raw.to_s.strip.empty?

      seconds = Integer(raw.to_s.strip, exception: false)
      seconds&.clamp(0, MAX_RETRY_AFTER)
    end
  end
end
