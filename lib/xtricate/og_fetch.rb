require "faraday"
require "uri"
require "cgi"

module Xtricate
  # Lightweight Open Graph / Twitter Card scraper. For each article URL we want
  # to display, pull og:image, og:title, og:description so the digest can show a
  # thumbnail + a real title instead of just a bare URL. Fetches in parallel
  # (thread per URL) since this is IO-bound. Failures degrade gracefully.
  class OgFetch
    Result = Struct.new(:url, :title, :image, :description, :site, keyword_init: true)

    # Two UAs: the first is what we'd use normally (Chrome on macOS — many news
    # sites' anti-bot heuristics let this through). On failure we retry with the
    # second (mobile Safari), which often gets a server-rendered HTML page when
    # the desktop variant is blocked or returns a JS-only shell.
    UA_DESKTOP = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36".freeze
    UA_MOBILE  = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1".freeze

    def initialize(timeout: 10, open_timeout: 5, max_redirects: 4, logger: nil)
      @timeout = timeout
      @open_timeout = open_timeout
      @max_redirects = max_redirects
      @logger = logger
    end

    # Returns Array<Result> in the same order as urls.
    def fetch_many(urls)
      urls.map { |u| Thread.new { fetch(u) } }.map(&:value)
    end

    def fetch(url)
      html, status = fetch_html_with_retry(url)
      if html.nil? || html.empty?
        @logger&.puts("    og: empty body for #{url} (#{status})")
        return fallback_result(url)
      end

      base = URI.parse(url) rescue nil
      title = meta(html, "og:title") || meta(html, "twitter:title") || html_title(html) || url_to_title(url)
      image = meta(html, "og:image:secure_url") || meta(html, "og:image") || meta(html, "twitter:image")
      desc  = meta(html, "og:description") || meta(html, "twitter:description") || meta(html, "description")
      site  = meta(html, "og:site_name") || hostname(url)

      Result.new(
        url: url,
        title: clip(title, 200),
        image: absolutize(image, base),
        description: clip(desc, 280),
        site: clip(site, 80)
      )
    rescue StandardError => e
      @logger&.puts("    og: parse error for #{url}: #{e.message}")
      fallback_result(url)
    end

    private

    # Try UA_DESKTOP first; on failure (network error, non-2xx, empty body)
    # retry once with UA_MOBILE. Returns [html_or_nil, status_string].
    def fetch_html_with_retry(url)
      [UA_DESKTOP, UA_MOBILE].each_with_index do |ua, i|
        html, status = fetch_html(url, ua: ua)
        return [html, status] if html && !html.empty?

        @logger&.puts("    og: attempt #{i + 1} failed for #{url} (#{status})") if i.zero?
      end
      [nil, "all attempts failed"]
    end

    def fetch_html(url, ua:, redirects_left: @max_redirects)
      uri = URI.parse(url)
      return [nil, "bad scheme"] unless %w[http https].include?(uri.scheme)

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

      return [nil, "http #{resp.status}"] unless resp.success?

      body = resp.body.to_s
      return [nil, "empty body"] if body.empty?

      [body[0, 200_000], "ok"]
    rescue Faraday::Error => e
      [nil, e.class.name.split("::").last]
    rescue StandardError => e
      [nil, e.class.name]
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
      m && CGI.unescapeHTML(m[1])
    end

    def html_title(html)
      m = html.match(/<title[^>]*>([^<]+)<\/title>/im)
      m && CGI.unescapeHTML(m[1])
    end

    def hostname(url)
      URI.parse(url).host || url
    rescue URI::InvalidURIError
      url
    end

    # When OG metadata is unreachable (anti-bot 403, timeout), build a usable
    # card from the URL itself: titleized slug + hostname as site.
    def fallback_result(url)
      Result.new(url: url, title: url_to_title(url), site: hostname(url))
    end

    # Turn the article's URL slug into a readable title:
    #   /2026/05/28/ai-spending-roi-enterprise-costs  -> "Ai Spending Roi Enterprise Costs"
    # Falls back to the hostname when the path has no usable slug.
    def url_to_title(url)
      uri = URI.parse(url)
      segment = uri.path.to_s.split("/").reject(&:empty?).last
      return hostname(url) if segment.nil?

      segment = segment.sub(/\.[a-z]{2,5}\z/i, "")
      return hostname(url) if segment.empty? || segment.match?(/\A\d+\z/) || segment.length < 3

      words = segment.split(/[-_]+/).reject(&:empty?).map(&:capitalize)
      words.empty? ? hostname(url) : words.join(" ")
    rescue URI::InvalidURIError
      hostname(url)
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
