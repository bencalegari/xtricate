require "json"
require "uri"
require "anthropic"

require_relative "models"
require_relative "og_fetch"

module Xtricate
  # Turns a week of raw account activity into a structured digest. Two steps:
  #
  #   1. Cluster tweets by the article URL they share (so one link discussed by
  #      several people becomes a single item with all the commentary).
  #   2. Hand the structured week to Claude, which returns *grouping decisions
  #      only* — theme names + tweet IDs, and an article shortlist with type
  #      classifications. Claude does NOT rewrite tweet text; we look up the
  #      canonical text from the fetched data and render it verbatim. This is
  #      deliberate: the reader wants original viewpoints, not summaries.
  #
  # The Result contains fully-prepared themes (with Tweet objects to render),
  # article entries enriched with og:image/og:title, and run-level counts.
  class Digest
    Theme = Struct.new(:name, :tweets, keyword_init: true)
    Article = Struct.new(
      :url, :type, :title, :image, :description, :site, :sharers,
      keyword_init: true
    )
    Discovery = Struct.new(:handle, :source, :mentions, :mentioned_by, keyword_init: true) do
      def profile_url
        case source
        when :bluesky then "https://bsky.app/profile/#{handle}"
        else "https://x.com/#{handle}"
        end
      end
    end
    Result = Struct.new(
      :overview, :themes, :articles, :discoveries,
      :period_label, :account_count, :active_count,
      :tweet_count, :article_count,
      keyword_init: true
    )

    ARTICLE_TYPES = %w[long_form short_form news_bulletin other].freeze
    MAX_ARTICLES = 10
    MAX_LONG_FORM = 3

    SYSTEM_PROMPT = <<~SYS.freeze
      You organize a weekly digest of X/Twitter activity. You are NOT a
      summarizer. The reader will see the original tweet text rendered under
      each theme — do NOT paraphrase, interpret, or characterize what people
      think. Your only job is to GROUP tweets and RANK shared links.

      You receive JSON with tweets (each has id, author, kind, text, urls) and
      articles (each has url, sharers, mentions). Return strict JSON in this
      exact shape — nothing else, no prose, no code fences:

      {
        "overview": "<2-3 plain, factual sentences naming the topics that came up this week. Neutral. No editorial.>",
        "themes": [
          {
            "name": "<short topical title, neutral, no opinion>",
            "tweet_ids": ["<id>", "<id>", ...]
          }
        ],
        "articles": [
          {
            "url": "<exact url from input>",
            "type": "long_form" | "short_form" | "news_bulletin" | "other"
          }
        ]
      }

      Theme rules:
      - 3 to 6 themes.
      - Each theme groups 2-8 tweets that discuss the same topic, the same
        article/link, or react to the same event. Group by topic OR by shared
        link OR by shared subject of conversation — whichever creates real
        connection, not contrived buckets.
      - Skip themes that would be a single isolated tweet about its own thing.
      - Theme names must be neutral descriptors (e.g. "Israel-Gaza ceasefire
        talks", "AI agent benchmarks", "Apple Vision Pro reviews") — NOT
        opinionated framings.

      Article rules:
      - Up to 10 articles total. AIM for 3 long_form articles when possible;
        never exceed 3 long_form.
      - For long_form selection, PRIORITIZE articles flagged `preferred: true`
        in the input. These come from outlets the reader specifically wants
        to read (Jacobin, The Baffler, New Left Review, n+1, Dissent, The
        Nation, Boston Review, etc.). They WIN the long_form slots EVEN IF
        they have low engagement or only one sharer. Fall back to
        non-preferred long_form candidates only if there aren't 3 preferred
        ones.
      - For short_form, news_bulletin, and other: rank by distinct sharers
        first, then total engagement.
      - If fewer than 3 long_form candidates exist in the input, include as
        many long_form as actually exist. Do not invent.
      - Classify type using these definitions:
          long_form     = magazine articles, news features, essays, deep
                          analysis, Substack essays, academic papers, books.
                          The preferred outlets above mostly publish long_form.
                          A short news blurb from one of those outlets is NOT
                          long_form — be honest about length and depth.
          short_form    = blog posts, brief opinion pieces, short Substack
                          notes, threads-as-articles, op-eds under ~1000 words.
          news_bulletin = breaking news items, wire stories (Reuters/AP/AFP),
                          short news reports, news-site articles primarily
                          reporting facts.
          other         = videos, podcasts, GitHub repos, products, tweets
                          quoted as links, anything not an article.

      Hard constraints:
      - Use ONLY tweet IDs and article URLs that appear in the input. Never
        invent IDs or URLs.
      - Output strict JSON. No code fences. No commentary outside the JSON.
    SYS

    def initialize(api_key:, model:, since:, lookback_days:,
                   preferred_outlets: [],
                   client: nil, og_fetcher: nil, logger: nil)
      @model = model
      @since = since
      @lookback_days = lookback_days
      @preferred_outlets = Array(preferred_outlets).map(&:downcase)
      @logger = logger
      @client = client || Anthropic::Client.new(api_key: api_key)
      @og_fetcher = og_fetcher || OgFetch.new(logger: logger)
    end

    # True when an article URL's host matches one of the configured preferred
    # outlets (exact host or any subdomain). Used to bias long_form picks.
    def preferred_outlet?(url)
      host = URI.parse(url.to_s).host.to_s.downcase
      return false if host.empty?

      @preferred_outlets.any? { |o| host == o || host.end_with?(".#{o}") }
    rescue URI::InvalidURIError
      false
    end

    # activities: Array<AccountActivity>
    def build(activities)
      all_tweets = activities.flat_map { |a| a.tweets || [] }
      tweet_index = index_tweets(all_tweets)
      clusters = cluster_articles(all_tweets)
      discoveries = discover_accounts(all_tweets, activities)

      payload = build_payload(activities, all_tweets, clusters)
      decision = call_claude(payload)

      themes = build_themes(decision["themes"] || [], tweet_index)
      articles = build_articles(decision["articles"] || [], clusters)

      Result.new(
        overview: decision["overview"].to_s.strip,
        themes: themes,
        articles: articles,
        discoveries: discoveries,
        period_label: period_label,
        account_count: activities.size,
        active_count: activities.count { |a| !a.empty? },
        tweet_count: all_tweets.size,
        article_count: clusters.size
      )
    end

    # Group tweets by the (normalized) external URLs they reference.
    def cluster_articles(tweets)
      by_url = Hash.new { |h, k| h[k] = [] }
      tweets.each do |t|
        Array(t.urls).each { |u| by_url[normalize_url(u)] << t }
      end
      by_url
        .map { |url, mentions| ArticleCluster.new(url: url, mentions: mentions.uniq) }
        .sort_by { |c| -c.total_engagement }
    end

    private

    def index_tweets(all_tweets)
      all_tweets.to_h { |t| [t.id.to_s, t] }
    end

    # Compact, ranked structure for the model. We surface preferred-outlet
    # articles regardless of engagement so a quiet Jacobin essay still reaches
    # the model and can win a long_form slot.
    #
    # Thread continuations are dropped: only the thread head is sent to Claude,
    # carrying the full concatenated thread text. That way Claude sees one
    # logical post per thread instead of N disjoint tweets.
    def build_payload(activities, all_tweets, clusters)
      payload_tweets = all_tweets.reject { |t| t.thread_member? && !t.thread_head? }
      top_tweets = payload_tweets.sort_by { |t| -t.engagement }.first(150)

      top_articles = clusters.first(60)
      preferred = clusters.select { |c| preferred_outlet?(c.url) }
      article_set = (top_articles + preferred).uniq { |c| c.url }

      {
        period: period_label,
        accounts_followed: activities.size,
        accounts_active: activities.count { |a| !a.empty? },
        tweets: top_tweets.map { |t| tweet_for_model(t) },
        articles: article_set.map do |c|
          {
            url: c.url,
            sharers: c.sharers,
            engagement: c.total_engagement,
            preferred: preferred_outlet?(c.url),
            mention_ids: c.mentions.map { |m| m.id.to_s }
          }
        end
      }
    end

    def tweet_for_model(t)
      # For thread heads, fold the rest of the thread into the text so Claude
      # judges relevance based on the whole thread, not just the opener.
      text =
        if t.thread_head? && t.thread_continuations && !t.thread_continuations.empty?
          ([t.text] + t.thread_continuations.map(&:text)).reject(&:empty?).join("\n\n")
        else
          t.text
        end

      h = {
        id: t.id.to_s,
        by: t.author,
        source: t.source,
        kind: t.kind,
        text: text
      }
      h[:thread] = true if t.thread_head?
      h[:urls] = t.urls if t.urls && !t.urls.empty?
      if t.quoted_author
        h[:quoted_by] = t.quoted_author
        h[:quoted_text] = t.quoted_text
        if t.quoted_inner_author
          h[:quoted_inner_by] = t.quoted_inner_author
          h[:quoted_inner_text] = t.quoted_inner_text
        end
      end
      h
    end

    # Tally non-followed accounts that the followed accounts engaged with this
    # week (retweeted, quoted). The reader uses this to grow their follow list
    # without ever opening X/Bluesky.
    def discover_accounts(all_tweets, activities)
      followed = activities.each_with_object({}) { |a, h| h[[(a.handle || "").downcase, a.source]] = true }
      tally = Hash.new { |h, k| h[k] = { count: 0, sources: [], by: {} } }

      all_tweets.each do |t|
        next unless t.quoted_author && !t.quoted_author.empty?

        key = [t.quoted_author.downcase, t.source]
        next if followed[key]

        entry = tally[key]
        entry[:count] += 1
        entry[:by][t.author] = true
      end

      tally
        .sort_by { |_, e| -e[:count] }
        .first(5)
        .map do |(handle, source), entry|
          Discovery.new(
            handle: handle,
            source: source,
            mentions: entry[:count],
            mentioned_by: entry[:by].keys
          )
        end
    end

    def call_claude(payload)
      log "  asking #{@model} to group #{payload[:tweets].size} tweets / #{payload[:articles].size} articles..."
      message = @client.messages.create(
        model: @model,
        max_tokens: 4096,
        system: [
          { type: "text", text: SYSTEM_PROMPT, cache_control: { type: "ephemeral" } }
        ],
        messages: [
          { role: "user", content: "Here is this week's activity as JSON:\n\n#{JSON.pretty_generate(payload)}\n\nReturn the grouping JSON now. Output JSON only, starting with { — no prose, no code fences." }
        ]
      )
      raw = extract_text(message)
      parse_json(raw)
    end

    def extract_text(message)
      blocks = message.respond_to?(:content) ? message.content : message["content"]
      Array(blocks).filter_map do |b|
        if b.respond_to?(:text) then b.text
        elsif b.is_a?(Hash) then b["text"]
        end
      end.join("\n").strip
    end

    def parse_json(raw)
      candidate = raw.to_s.strip
      # Strip code fences if the model snuck them in.
      candidate = candidate.sub(/\A```(?:json)?\s*/, "").sub(/\s*```\s*\z/, "")
      # If the model wrote any prose before/after the JSON, isolate the object.
      if (start = candidate.index("{")) && (finish = candidate.rindex("}"))
        candidate = candidate[start..finish]
      end
      JSON.parse(candidate)
    rescue JSON::ParserError => e
      log "  ! JSON parse failed: #{e.message}"
      log "    raw head: #{candidate[0, 200].inspect}"
      { "overview" => "", "themes" => [], "articles" => [] }
    end

    def build_themes(raw_themes, tweet_index)
      Array(raw_themes).filter_map do |t|
        ids = Array(t["tweet_ids"]).map(&:to_s)
        tweets = ids.filter_map { |id| tweet_index[id] }
        next if tweets.empty?

        name = t["name"].to_s.strip
        next if name.empty?

        Theme.new(name: name, tweets: tweets)
      end
    end

    # Enforce 10-total / 3-long_form cap server-side. Look up sharers from the
    # original cluster so we never trust the model with rendering data.
    def build_articles(raw_articles, clusters)
      cluster_by_url = clusters.to_h { |c| [normalize_url(c.url), c] }

      picks = []
      long_form_count = 0
      Array(raw_articles).each do |a|
        break if picks.size >= MAX_ARTICLES

        url = a["url"].to_s
        next if url.empty?

        type = a["type"].to_s
        type = "other" unless ARTICLE_TYPES.include?(type)
        if type == "long_form"
          next if long_form_count >= MAX_LONG_FORM

          long_form_count += 1
        end

        picks << { url: url, type: type }
      end

      return [] if picks.empty?

      log "  fetching og:image/title for #{picks.size} article(s)..."
      og_results = @og_fetcher.fetch_many(picks.map { |p| p[:url] })

      picks.zip(og_results).map do |pick, og|
        cluster = cluster_by_url[normalize_url(pick[:url])]
        sharers = cluster ? cluster.sharers : []

        Article.new(
          url: pick[:url],
          type: pick[:type],
          title: og.title,
          image: og.image,
          description: og.description,
          site: og.site,
          sharers: sharers
        )
      end
    end

    def normalize_url(url)
      u = url.to_s.strip.sub(%r{\?utm_[^#]*}, "").sub(%r{/\z}, "")
      u.empty? ? url.to_s : u
    end

    def period_label
      start = @since.strftime("%b %-d")
      finish = Time.now.strftime("%b %-d, %Y")
      "#{start} – #{finish}"
    end

    def log(msg) = @logger&.puts(msg)
  end
end
