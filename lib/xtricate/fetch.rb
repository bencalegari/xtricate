require "faraday"
require "json"
require "time"
require "cgi"

require_relative "models"

module Xtricate
  # Pulls recent tweets for each followed account from twitterapi.io and
  # normalizes them into Tweet structs. Stateless: a rolling window keyed off
  # each tweet's timestamp, so there's nothing to persist between runs.
  #
  # API: GET https://api.twitterapi.io/twitter/user/last_tweets
  #   auth header: x-api-key
  #   params: userName, cursor
  # Response is parsed defensively (field names vary), degrading gracefully.
  class Fetch
    BASE_URL = "https://api.twitterapi.io".freeze
    ENDPOINT = "/twitter/user/last_tweets".freeze

    def initialize(api_key:, since:, max_per_account: 100, conn: nil, logger: nil)
      @api_key = api_key
      @since = since
      @max_per_account = max_per_account
      @logger = logger
      @conn = conn || build_conn
    end

    # Returns Array<AccountActivity>, one per handle (empty ones included so
    # the summary can note who was quiet).
    def fetch_all(handles)
      handles.map { |h| AccountActivity.new(handle: h, tweets: fetch_account(h)) }
    end

    # Returns Array<Tweet> for one handle, within the lookback window.
    def fetch_account(handle)
      tweets = []
      cursor = nil
      pages = 0

      loop do
        body = request(handle, cursor)
        raw = extract_tweets(body)
        break if raw.empty?

        raw.each do |t|
          tweet = normalize(t, fallback_author: handle)
          next if tweet.nil?
          # Tweets come newest-first; stop the whole account once we cross the cutoff.
          return tweets if tweet.created_at && tweet.created_at < @since

          tweets << tweet
          return tweets if tweets.size >= @max_per_account
        end

        cursor = body["next_cursor"] || body.dig("data", "next_cursor")
        has_next = body["has_next_page"] || body.dig("data", "has_next_page")
        pages += 1
        break unless has_next && cursor && !cursor.to_s.empty?
        break if pages >= 20 # hard safety stop on pagination
      end

      tweets
    rescue Faraday::Error => e
      log "  ! fetch failed for @#{handle}: #{e.message}"
      []
    end

    private

    def build_conn
      Faraday.new(url: BASE_URL) do |f|
        f.headers["x-api-key"] = @api_key
        f.options.timeout = 30
        f.options.open_timeout = 10
        f.adapter Faraday.default_adapter
      end
    end

    def request(handle, cursor)
      params = { userName: handle }
      params[:cursor] = cursor if cursor && !cursor.to_s.empty?
      resp = @conn.get(ENDPOINT, params)
      unless resp.success?
        raise Faraday::Error, "HTTP #{resp.status}: #{resp.body.to_s[0, 200]}"
      end

      JSON.parse(resp.body)
    end

    def extract_tweets(body)
      tweets =
        body.dig("data", "tweets") ||
        body["tweets"] ||
        (body["data"].is_a?(Array) ? body["data"] : nil)
      Array(tweets)
    end

    # Map a raw twitterapi.io tweet object to a Tweet struct, or nil if unusable.
    def normalize(t, fallback_author:)
      return nil unless t.is_a?(Hash)

      retweeted = t["retweeted_tweet"] || t["retweet"]
      quoted    = t["quoted_tweet"] || t["quote"]

      kind =
        if retweeted then :retweet
        elsif quoted || t["isQuote"] then :quote
        else :original
        end

      author = dig_author(t) || fallback_author
      urls = extract_urls(kind == :retweet ? retweeted : t) + extract_urls(quoted)

      quoted_src = retweeted || quoted
      Tweet.new(
        id: t["id"] || t["tweet_id"] || t["id_str"],
        author: author,
        kind: kind,
        text: clean_text(t["text"] || t["full_text"] || ""),
        created_at: parse_time(t["createdAt"] || t["created_at"]),
        url: t["url"] || t["tweet_url"],
        urls: urls.uniq,
        like_count: int(t["likeCount"] || t["favorite_count"] || t["like_count"]),
        retweet_count: int(t["retweetCount"] || t["retweet_count"]),
        reply_count: int(t["replyCount"] || t["reply_count"]),
        quote_count: int(t["quoteCount"] || t["quote_count"]),
        quoted_id: quoted_src && (quoted_src["id"] || quoted_src["tweet_id"] || quoted_src["id_str"]),
        quoted_author: quoted_src && dig_author(quoted_src),
        quoted_text: quoted_src && clean_text(quoted_src["text"] || quoted_src["full_text"] || "")
      )
    end

    def dig_author(t)
      t.dig("author", "userName") ||
        t.dig("author", "screen_name") ||
        t.dig("user", "screen_name") ||
        t["author_username"] ||
        t["screen_name"]
    end

    def extract_urls(t)
      return [] unless t.is_a?(Hash)

      entries = t.dig("entities", "urls") || t["urls"] || []
      Array(entries).filter_map do |u|
        next u if u.is_a?(String)

        url = u["expanded_url"] || u["unwound_url"] || u["url"] || u["display_url"]
        url unless tco?(url)
      end
    end

    # t.co self-links and pic.twitter links aren't "articles"; drop them.
    def tco?(url)
      url.nil? || url.include?("t.co/") || url.include?("pic.twitter.com") ||
        url.include?("twitter.com") || url.include?("x.com/")
    end

    # Twitter's API returns tweet text with HTML entities (&amp;, &lt;, &gt;).
    # Decode them once here so downstream rendering (which re-escapes) doesn't
    # double-encode into &amp;amp;.
    def clean_text(str)
      CGI.unescapeHTML(str.to_s).gsub(/\s+/, " ").strip
    end

    def parse_time(val)
      return nil if val.nil? || val.to_s.empty?

      Time.parse(val.to_s)
    rescue ArgumentError
      begin
        # Twitter's classic format, just in case Time.parse is strict.
        Time.strptime(val.to_s, "%a %b %d %H:%M:%S %z %Y")
      rescue ArgumentError
        nil
      end
    end

    def int(val) = val.nil? ? 0 : val.to_i

    def log(msg)
      @logger&.puts(msg)
    end
  end
end
