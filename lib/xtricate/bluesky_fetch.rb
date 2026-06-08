require "faraday"
require "json"
require "time"
require "cgi"

require_relative "models"

module Xtricate
  # Pulls recent posts for each followed Bluesky account using the unauthenticated
  # public API (public.api.bsky.app). Normalizes to the same Tweet/AccountActivity
  # types the Twitter fetcher emits so the rest of the pipeline doesn't know the
  # difference. No auth required.
  #
  # Endpoint: GET /xrpc/app.bsky.feed.getAuthorFeed?actor=<handle>&limit=100&cursor=<...>
  #
  # Bluesky concepts mapped here:
  #   - Repost (reason.reasonRepost on feed item)  -> kind: :retweet
  #     * follower is the reposter; post.author is the original author
  #   - Quote post (embed app.bsky.embed.record#view) -> kind: :quote
  #   - External link embed (embed app.bsky.embed.external#view) -> url + thumbnail
  #   - Images embed (embed app.bsky.embed.images#view)          -> photo media
  #
  # Bluesky URIs look like at://did:plc:.../app.bsky.feed.post/<recordKey>. We
  # store the bare recordKey as id and reconstruct permalinks using author handle.
  class BlueskyFetch
    BASE_URL = "https://public.api.bsky.app".freeze
    ENDPOINT = "/xrpc/app.bsky.feed.getAuthorFeed".freeze

    def initialize(since:, max_per_account: 100, conn: nil, logger: nil)
      @since = since
      @max_per_account = max_per_account
      @logger = logger
      @conn = conn || build_conn
    end

    def fetch_all(handles)
      handles.map do |h|
        AccountActivity.new(handle: h, tweets: fetch_account(h), source: :bluesky)
      end
    end

    def fetch_account(handle)
      tweets = []
      cursor = nil
      pages = 0

      loop do
        body = request(handle, cursor)
        feed = Array(body["feed"])
        break if feed.empty?

        feed.each do |item|
          tweet = normalize(item, follower: handle)
          next if tweet.nil?
          return tweets if tweet.created_at && tweet.created_at < @since

          tweets << tweet
          return tweets if tweets.size >= @max_per_account
        end

        cursor = body["cursor"]
        pages += 1
        break if cursor.nil? || cursor.empty?
        break if pages >= 10
      end

      tweets
    rescue Faraday::Error => e
      log "  ! bluesky fetch failed for @#{handle}: #{e.message}"
      []
    end

    private

    def build_conn
      Faraday.new(url: BASE_URL) do |f|
        f.options.timeout = 30
        f.options.open_timeout = 10
        f.adapter Faraday.default_adapter
      end
    end

    def request(handle, cursor)
      params = { actor: handle, limit: 100 }
      params[:cursor] = cursor if cursor && !cursor.empty?
      resp = @conn.get(ENDPOINT, params)
      raise Faraday::Error, "HTTP #{resp.status}: #{resp.body.to_s[0, 200]}" unless resp.success?

      JSON.parse(resp.body)
    end

    def normalize(item, follower:)
      post = item["post"] or return nil
      reason = item["reason"]

      is_repost = reason && reason["$type"].to_s.include?("reasonRepost")

      if is_repost
        normalize_repost(post, reason, follower: follower)
      else
        normalize_native(post, follower: follower)
      end
    end

    # The follower reposted someone else's post (no commentary). Mirror
    # Twitter-style retweets: author = follower, quoted_* = original.
    def normalize_repost(post, reason, follower:)
      record = post["record"] || {}
      record_key = post_record_key(post["uri"])
      original_author = post.dig("author", "handle")
      reposted_at = parse_time(reason["indexedAt"]) || parse_time(record["createdAt"])

      external = external_embed(post["embed"])

      # If the reposted post is itself a quote post, capture its nested quote so
      # the innermost source survives into the digest.
      _, _, inner_author, inner_text = parse_quote_or_kind(post["embed"])

      Tweet.new(
        id: record_key, # use the original post's record key; pairs with quoted_id for dedup
        author: follower,
        kind: :retweet,
        text: "", # pure repost — no commentary
        created_at: reposted_at,
        url: nil,
        urls: external ? [external] : [],
        like_count: int(post["likeCount"]),
        retweet_count: int(post["repostCount"]),
        reply_count: int(post["replyCount"]),
        quote_count: int(post["quoteCount"]),
        quoted_id: record_key,
        quoted_author: original_author,
        quoted_text: clean_text(record["text"]),
        quoted_inner_author: inner_author,
        quoted_inner_text: inner_text,
        source: :bluesky,
        media: image_media(post["embed"]),
        conversation_id: nil,
        thread_root_id: nil
      )
    end

    def normalize_native(post, follower:)
      record = post["record"] || {}
      record_key = post_record_key(post["uri"])
      author = post.dig("author", "handle")
      kind, quoted_id, quoted_author, quoted_text = parse_quote_or_kind(post["embed"])

      reply_root_uri = record.dig("reply", "root", "uri")
      conv_id = reply_root_uri ? post_record_key(reply_root_uri) : record_key

      external = external_embed(post["embed"])

      Tweet.new(
        id: record_key,
        author: author,
        kind: kind,
        text: clean_text(record["text"]),
        created_at: parse_time(record["createdAt"]),
        url: nil,
        urls: external ? [external] : [],
        like_count: int(post["likeCount"]),
        retweet_count: int(post["repostCount"]),
        reply_count: int(post["replyCount"]),
        quote_count: int(post["quoteCount"]),
        quoted_id: quoted_id,
        quoted_author: quoted_author,
        quoted_text: quoted_text,
        source: :bluesky,
        media: image_media(post["embed"]),
        conversation_id: conv_id,
        thread_root_id: nil
      )
    end

    # Returns [kind, quoted_id, quoted_author, quoted_text]
    def parse_quote_or_kind(embed)
      return [:original, nil, nil, nil] unless embed.is_a?(Hash)

      type = embed["$type"].to_s
      record =
        if type.include?("recordWithMedia")
          embed.dig("record", "record")
        elsif type.include?("embed.record")
          embed["record"]
        end
      return [:original, nil, nil, nil] unless record

      quoted_id = post_record_key(record["uri"])
      quoted_author = record.dig("author", "handle")
      quoted_text = clean_text(record.dig("value", "text") || record.dig("record", "text") || record["text"])

      [:quote, quoted_id, quoted_author, quoted_text]
    end

    def image_media(embed)
      return [] unless embed.is_a?(Hash)

      type = embed["$type"].to_s
      images =
        if type.include?("images")
          embed["images"]
        elsif type.include?("recordWithMedia")
          embed.dig("media", "images")
        end
      Array(images).filter_map do |img|
        next unless img.is_a?(Hash)

        thumb = img["thumb"] || img["fullsize"]
        full  = img["fullsize"] || img["thumb"]
        next unless thumb || full

        MediaItem.new(type: :photo, url: full, thumb: thumb, alt: img["alt"])
      end
    end

    def external_embed(embed)
      return nil unless embed.is_a?(Hash)

      type = embed["$type"].to_s
      ext =
        if type.include?("external")
          embed["external"]
        elsif type.include?("recordWithMedia")
          embed.dig("media", "external")
        end
      ext && ext["uri"]
    end

    # at://did:plc:.../app.bsky.feed.post/<recordKey>  -> recordKey
    def post_record_key(uri)
      return nil unless uri.is_a?(String) && !uri.empty?

      uri.split("/").last
    end

    def clean_text(str)
      CGI.unescapeHTML(str.to_s).gsub(/\s+/, " ").strip
    end

    def parse_time(val)
      return nil if val.nil? || val.to_s.empty?

      Time.parse(val.to_s)
    rescue ArgumentError
      nil
    end

    def int(val) = val.nil? ? 0 : val.to_i

    def log(msg) = @logger&.puts(msg)
  end
end
