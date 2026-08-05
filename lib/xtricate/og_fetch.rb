require "faraday"
require "uri"
require_relative "entities"

module Xtricate
  # Lightweight Open Graph / Twitter Card scraper. For each article URL we want
  # to display, pull og:image, og:title, og:description so the digest can show a
  # thumbnail + a real title instead of just a bare URL. Fetches in parallel
  # (thread per URL) since this is IO-bound. Failures degrade gracefully.
  class OgFetch
    # resolved_url is the URL the redirect chain ended at, which differs from
    # url whenever a tweet shared a shortlink (reut.rs, trib.al, bit.ly, ...).
    # It's what we scrape and what the digest should link to.
    Result = Struct.new(:url, :resolved_url, :title, :image, :description, :site, keyword_init: true)

    # Hosts whose paths are opaque tokens, never readable slugs. If we can't
    # resolve past one of these there's no title to salvage from the URL.
    SHORTENER_HOSTS = %w[
      reut.rs trib.al bit.ly t.co buff.ly ow.ly tinyurl.com dlvr.it
      nyti.ms wapo.st on.wsj.com apne.ws cnn.it n.pr bbc.in econ.st
      hubs.ly lnkd.in fb.me ift.tt zpr.io shorturl.at is.gd
    ].freeze

    # Tracking params that shorteners and social referrers bolt on. Dropped from
    # resolved_url so the digest links to a clean article URL.
    TRACKING_PARAM = /\A(?:utm_\w+|fbclid|gclid|mc_[ce]id|igshid|ref|ref_src|s|smid|cmpid|CMP)\z/.freeze

    # Words that read wrong title-cased ("Us Contractor", "Ai Spending").
    ACRONYMS = %w[
      ai us usa uk eu un uae nato ceo cfo cto cia fbi ice irs nasa nhs
      gdp ipo llc suv gop dei doj dhs hhs sec fda epa nyc la sf dc
      api gpu cpu llm sms tv url vc ux ui roi
    ].freeze

    # Two UAs: the first is what we'd use normally (Chrome on macOS — many news
    # sites' anti-bot heuristics let this through). On failure we retry with the
    # second (mobile Safari), which often gets a server-rendered HTML page when
    # the desktop variant is blocked or returns a JS-only shell.
    UA_DESKTOP = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36".freeze
    UA_MOBILE  = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1".freeze

    # max_redirects is 8 because shortlinks chain: a shared reut.rs link hops
    # through trib.al and back through reut.rs before landing on reuters.com.
    def initialize(timeout: 10, open_timeout: 5, max_redirects: 8, logger: nil)
      @timeout = timeout
      @open_timeout = open_timeout
      @max_redirects = max_redirects
      @logger = logger
      @cache = {}
      @cache_lock = Mutex.new
    end

    def fetch_many(urls)
      urls.map { |u| Thread.new { fetch_cached(u) } }.map(&:value)
    end

    def fetch_cached(url)
      hit = @cache_lock.synchronize { @cache[url] }
      return hit if hit

      fetch(url).tap { |res| @cache_lock.synchronize { @cache[url] = res } }
    end

    def fetch(url)
      html, status, final_url = fetch_html_with_retry(url)
      # Even a failed fetch usually tells us something: the redirect chain ran
      # before the final page 401'd, so final_url is the real article URL and
      # its slug beats the shortlink token we were handed.
      if html.nil? || html.empty?
        @logger&.puts("    og: empty body for #{url} (#{status})")
        return fallback_result(url, final_url)
      end

      base = URI.parse(final_url) rescue nil
      title = meta(html, "og:title") || meta(html, "twitter:title") || html_title(html) ||
              url_to_title(final_url) || hostname(final_url)
      image = meta(html, "og:image:secure_url") || meta(html, "og:image") || meta(html, "twitter:image")
      desc  = meta(html, "og:description") || meta(html, "twitter:description") || meta(html, "description")
      site  = meta(html, "og:site_name") || hostname(final_url)

      Result.new(
        url: url,
        resolved_url: untrack(final_url),
        title: clip(title, 200),
        image: absolutize(image, base),
        description: clip(desc, 280),
        site: clip(site, 80)
      )
    rescue StandardError => e
      @logger&.puts("    og: parse error for #{url}: #{e.message}")
      fallback_result(url, final_url)
    end

    private

    # Try UA_DESKTOP first; on failure (network error, non-2xx, empty body)
    # retry once with UA_MOBILE. Returns [html_or_nil, status_string, final_url].
    # final_url is the furthest point the last attempt reached, so a failed
    # fetch still yields the resolved article URL.
    def fetch_html_with_retry(url)
      resolved = url
      [UA_DESKTOP, UA_MOBILE].each_with_index do |ua, i|
        html, status, final_url = fetch_html(url, ua: ua)
        resolved = final_url if final_url
        return [html, status, resolved] if html && !html.empty?

        @logger&.puts("    og: attempt #{i + 1} failed for #{url} (#{status})") if i.zero?
      end
      [nil, "all attempts failed", resolved]
    end

    def fetch_html(url, ua:, redirects_left: @max_redirects)
      uri = URI.parse(url)
      return [nil, "bad scheme", url] unless %w[http https].include?(uri.scheme)

      resp = conn.get(uri.to_s) do |req|
        req.headers["User-Agent"] = ua
        req.headers["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        req.headers["Accept-Language"] = "en-US,en;q=0.9"
        # Ask for uncompressed bytes — we scan the body with a regex, and Faraday
        # by default doesn't decompress gzip responses.
        req.headers["Accept-Encoding"] = "identity"
      end

      if redirect?(resp.status) && resp.headers["location"] && redirects_left.positive?
        nxt = URI.join(uri, resp.headers["location"]).to_s
        return fetch_html(nxt, ua: ua, redirects_left: redirects_left - 1)
      end

      return [nil, "http #{resp.status}", url] unless resp.success?

      body = resp.body.to_s
      return [nil, "empty body", url] if body.empty?

      [body[0, 200_000], "ok", url]
    rescue Faraday::Error => e
      [nil, e.class.name.split("::").last, url]
    rescue StandardError => e
      [nil, e.class.name, url]
    end

    def conn
      @conn ||= Faraday.new do |f|
        f.options.timeout = @timeout
        f.options.open_timeout = @open_timeout
        f.adapter Faraday.default_adapter
      end
    end

    def redirect?(status)
      [301, 302, 303, 307, 308].include?(status)
    end

    # Match both <meta property="..."> and <meta name="..."> regardless of attr order.
    def meta(html, key)
      pattern = Regexp.escape(key)
      m = html.match(/<meta[^>]+(?:property|name)=["']#{pattern}["'][^>]+content=["']([^"']+)["']/i) ||
          html.match(/<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name)=["']#{pattern}["']/i)
      m && Entities.decode(m[1])
    end

    def html_title(html)
      m = html.match(/<title[^>]*>([^<]+)<\/title>/im)
      m && Entities.decode(m[1])
    end

    def hostname(url)
      URI.parse(url).host&.sub(/\Awww\./, "") || url
    rescue URI::InvalidURIError
      url
    end

    def untrack(url)
      uri = URI.parse(url)
      return url if uri.query.nil? || uri.query.empty?

      kept = URI.decode_www_form(uri.query).reject { |k, _| k.match?(TRACKING_PARAM) }
      uri.query = kept.empty? ? nil : URI.encode_www_form(kept)
      uri.to_s
    rescue StandardError
      url
    end

    # When OG metadata is unreachable (anti-bot 403/401, timeout), build a usable
    # card from the URL itself: titleized slug + hostname as site. Prefers the
    # resolved URL — "reut.rs/4pk1Got" has no title in it, the reuters.com URL
    # it redirects to does.
    def fallback_result(url, resolved_url = nil)
      best = resolved_url || url
      Result.new(
        url: url,
        resolved_url: untrack(best),
        title: url_to_title(best) || url_to_title(url) || hostname(best),
        site: hostname(best)
      )
    end

    # Turn the article's URL slug into a readable title:
    #   /2026/05/28/ai-spending-roi-enterprise-costs  -> "AI Spending ROI Enterprise Costs"
    # Returns nil when the path has no usable slug (shortener token, bare id),
    # so callers can fall back to the hostname instead of printing gibberish.
    def url_to_title(url)
      segments = usable_path_segments(url)
      return nil if segments.empty?

      # Wordiest segment wins, not the last one: news CMS paths often end in a
      # generic ".../article_<uuid>" while the headline sits one level up.
      # Ties go to the deepest segment.
      words = segments
              .map { |s| s.split(/[-_]+/).reject(&:empty?) }
              .each_with_index.max_by { |w, i| [w.size, i] }
              &.first
      return nil if words.nil? || words.empty?

      titleized = words.map { |w| ACRONYMS.include?(w.downcase) ? w.upcase : w.capitalize }
      titleized.join(" ")
    rescue URI::InvalidURIError
      nil
    end

    # Path segments with the noise stripped: file extensions, trailing date
    # parts (/2026-07-15, /2026/07/15) and the opaque ids CMSes append
    # (article_a8f0cc6c-29d3-..., -idUSKBN2K). Empty when nothing is readable.
    def usable_path_segments(url)
      uri = URI.parse(url)
      return [] if SHORTENER_HOSTS.include?(uri.host.to_s.downcase.sub(/\Awww\./, ""))

      segments = uri.path.to_s.split("/").reject(&:empty?)
      segments = segments.map { |s| s.sub(/\.[a-z]{2,5}\z/i, "") }
      # Strip trailing all-numeric segments (dates, ids) then drop segments that
      # hold no letters at all.
      segments.pop while segments.any? && segments.last.match?(/\A\d+\z/)
      segments = segments.map { |s| strip_trailing_noise(s) }
      segments.reject { |s| s.length < 3 || !s.match?(/[a-z]/i) || opaque_token?(s) }
    end

    # "us-contractor-...-supply-routes-2026-07-15" -> "us-contractor-...-supply-routes"
    # "article_a8f0cc6c-29d3-41f7-8668-8a855f760efb" -> "article"
    def strip_trailing_noise(segment)
      s = segment.sub(/(?:[-_](?:19|20)\d{2}(?:[-_]\d{1,2}){0,2})\z/, "")
      s = s.sub(/(?:[-_][0-9a-f]{8}(?:[-_][0-9a-f]{4}){3}[-_][0-9a-f]{12})\z/i, "") # uuid
      s.sub(/[-_](?:id[A-Z0-9]{6,}|\h{12,})\z/, "")
    end

    # Shortener tokens and hashes: no word separators, mixes digits with letters
    # or cases. "4pk1Got", "vDu5OtN", "a8f0cc6c" — never a headline.
    def opaque_token?(segment)
      return false if segment.match?(/[-_]/)
      return false if segment.length > 24

      segment.match?(/\d/) || segment.match?(/[a-z][A-Z]/) || segment.match?(/\A\h{8,}\z/)
    end

    def absolutize(maybe_url, base)
      return nil if maybe_url.nil? || maybe_url.empty?
      return maybe_url if base.nil?

      URI.join(base, maybe_url).to_s
    rescue URI::InvalidURIError
      maybe_url
    end

    def clip(str, n)
      return nil if str.nil?

      s = str.to_s.gsub(/\s+/, " ").strip
      s.empty? ? nil : s[0, n]
    end
  end
end
