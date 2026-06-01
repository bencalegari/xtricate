module Xtricate
  # A single tweet from a followed account, already normalized from the
  # twitterapi.io payload. `kind` is :original, :retweet, or :quote.
  #
  # For :retweet  -> quoted/* holds the retweeted author + text.
  # For :quote    -> text is the author's commentary; quoted/* holds the
  #                  quoted tweet's author + text.
  Tweet = Struct.new(
    :id, :author, :kind, :text, :created_at, :url, :urls,
    :like_count, :retweet_count, :reply_count, :quote_count,
    :quoted_id, :quoted_author, :quoted_text,
    keyword_init: true
  ) do
    def retweet? = kind == :retweet
    def quote?   = kind == :quote

    # Engagement score used to rank what matters in a noisy week.
    def engagement
      (like_count.to_i) + (retweet_count.to_i * 2) + (quote_count.to_i * 2)
    end

    # Canonical x.com permalink for the tweet itself.
    def permalink
      url || (id && author ? "https://x.com/#{author}/status/#{id}" : nil)
    end

    # Permalink to the quoted/retweeted tweet, if known.
    def quoted_permalink
      return nil unless quoted_id && quoted_author

      "https://x.com/#{quoted_author}/status/#{quoted_id}"
    end
  end

  # All tweets pulled for one account in the lookback window.
  AccountActivity = Struct.new(:handle, :tweets, keyword_init: true) do
    def empty? = tweets.nil? || tweets.empty?
  end

  # A URL/article that one or more followed accounts shared this week,
  # grouped with every mention so commentary can be summarized together.
  ArticleCluster = Struct.new(:url, :mentions, keyword_init: true) do
    # mentions: array of Tweet that reference this url
    def total_engagement = mentions.sum(&:engagement)
    def sharers = mentions.map(&:author).uniq
  end
end
