module Xtricate
  # A media attachment on a tweet/post: photo, video preview, or animated gif.
  # `thumb` is the small preview URL (used in the digest); `url` is the
  # full-size click-through (for the future "open in browser" path).
  MediaItem = Struct.new(:type, :url, :thumb, :alt, keyword_init: true)

  # A single post from a followed account, normalized from twitterapi.io OR
  # Bluesky's getAuthorFeed. `source` distinguishes them so the renderer can
  # build the right permalinks and badges. The shared model lets the rest of
  # the pipeline (clustering, themes, articles) treat both identically.
  #
  # For :retweet  -> quoted/* holds the original author + text we're amplifying.
  # For :quote    -> text is the author's commentary; quoted/* holds the quoted post.
  #
  # Thread fields (for self-threads only):
  #   conversation_id    — id of the root post in a multi-post conversation
  #   thread_root_id     — id of the first post in this author's self-thread
  #                        (== id when this post IS the head)
  #   thread_position    — 0-based index in the thread (head = 0)
  #   thread_continuations — for the head only: ordered Tweet objects for
  #                          positions 1..N, attached during assembly so the
  #                          renderer can show the whole thread as one card.
  Tweet = Struct.new(
    :id, :author, :kind, :text, :created_at, :url, :urls,
    :like_count, :retweet_count, :reply_count, :quote_count,
    :quoted_id, :quoted_author, :quoted_text,
    :source, :media,
    :conversation_id, :thread_root_id, :thread_position, :thread_continuations,
    keyword_init: true
  ) do
    def retweet? = kind == :retweet
    def quote?   = kind == :quote
    def thread_head? = thread_root_id && thread_root_id == id
    def thread_member? = thread_root_id && thread_root_id != id

    def engagement
      (like_count.to_i) + (retweet_count.to_i * 2) + (quote_count.to_i * 2)
    end

    # Permalink to this post.
    def permalink
      return url if url

      case source
      when :bluesky then id && author ? "https://bsky.app/profile/#{author}/post/#{id}" : nil
      else id && author ? "https://x.com/#{author}/status/#{id}" : nil
      end
    end

    def quoted_permalink
      return nil unless quoted_id && quoted_author

      case source
      when :bluesky then "https://bsky.app/profile/#{quoted_author}/post/#{quoted_id}"
      else "https://x.com/#{quoted_author}/status/#{quoted_id}"
      end
    end

    # Profile URL for the author of this post.
    def author_profile_url
      return nil if author.nil? || author.empty?

      case source
      when :bluesky then "https://bsky.app/profile/#{author}"
      else "https://x.com/#{author}"
      end
    end

    def quoted_profile_url
      return nil if quoted_author.nil? || quoted_author.empty?

      case source
      when :bluesky then "https://bsky.app/profile/#{quoted_author}"
      else "https://x.com/#{quoted_author}"
      end
    end
  end

  AccountActivity = Struct.new(:handle, :tweets, :source, keyword_init: true) do
    def empty? = tweets.nil? || tweets.empty?
  end

  ArticleCluster = Struct.new(:url, :mentions, keyword_init: true) do
    def total_engagement = mentions.sum(&:engagement)
    def sharers = mentions.map(&:author).uniq
  end
end
