require "erb"
require "cgi"

module Xtricate
  # Wraps the digest data in the HTML email shell. The template renders tweets
  # verbatim from the canonical Tweet objects (no Claude rewriting), with
  # permalinks to view each on X. Article cards show og:image thumbnails and a
  # classification badge (long-form / short-form / news bulletin / other).
  class Renderer
    TEMPLATE = File.expand_path("../../templates/digest.html.erb", __dir__)

    TYPE_LABELS = {
      "long_form"     => "Long-form",
      "short_form"    => "Short-form",
      "news_bulletin" => "News",
      "other"         => "Other"
    }.freeze

    TYPE_COLORS = {
      "long_form"     => "#7c3aed", # purple — sit down for this
      "short_form"    => "#0ea5e9", # blue — quick read
      "news_bulletin" => "#dc2626", # red — news
      "other"         => "#525252"  # gray — fallback
    }.freeze

    def initialize(template_path: TEMPLATE)
      @template = ERB.new(File.read(template_path, encoding: "UTF-8"), trim_mode: "-")
    end

    def render(result)
      @result = result
      @template.result(binding)
    end

    def subject(result)
      "Your X digest — #{result.period_label}"
    end

    # --- Template helpers below (invoked via ERB binding). ---

    def h(str)
      CGI.escapeHTML(str.to_s)
    end

    # Escape tweet text, then turn bare URLs into <a> tags. URLs are matched
    # *after* HTML escaping, so safety is preserved.
    def render_tweet_text(text)
      escaped = h(text)
      escaped.gsub(%r{(https?://[^\s<]+)}) do |u|
        # Trim trailing punctuation that's likely sentence-final.
        trailing = ""
        clean = u.dup
        while clean =~ /[)\].,!?;:]\z/
          trailing = clean[-1] + trailing
          clean = clean[0..-2]
        end
        %(<a href="#{clean}" style="color:#1d4ed8; text-decoration:none;">#{clean}</a>#{trailing})
      end
    end

    def author_link(handle)
      return "" if handle.nil? || handle.empty?

      %(<a href="https://x.com/#{h(handle)}" style="color:#1d4ed8; text-decoration:none; font-weight:600;">@#{h(handle)}</a>)
    end

    def type_label(type) = TYPE_LABELS.fetch(type, "Other")
    def type_color(type) = TYPE_COLORS.fetch(type, TYPE_COLORS["other"])

    # "View on X" or "View on Bluesky" depending on a tweet's source.
    def view_label(tweet)
      tweet&.source == :bluesky ? "View on Bluesky" : "View on X"
    end

    # Inline media thumbnails for tweet/post cards. Up to 4 per card, capped to
    # keep the email tight. Returns "" if there's no media.
    def render_media(items)
      return "" if items.nil? || items.empty?

      thumbs = items.first(4)
      cell_w = thumbs.size == 1 ? 360 : (thumbs.size == 2 ? 180 : 120)
      cell_h = thumbs.size == 1 ? 200 : (thumbs.size == 2 ? 180 : 120)

      cells = thumbs.map do |m|
        src = m.thumb || m.url
        next if src.nil? || src.empty?

        # Video indicator: small inline badge below the thumb instead of a
        # CSS-positioned overlay (negative-margin overlays break in most email
        # clients and leave a cell-height-tall gap below the image).
        badge = m.type == :video ? %(<div style="font-size:11px; color:#6b7280; margin-top:2px;">&#9658; Video</div>) : ""
        %(<td valign="top" style="padding:2px;"><img src="#{h(src)}" alt="#{h(m.alt || '')}" width="#{cell_w}" height="#{cell_h}" style="display:block; border-radius:8px; width:#{cell_w}px; height:#{cell_h}px; object-fit:cover; background:#f4f5f7;">#{badge}</td>)
      end.compact.join

      return "" if cells.empty?

      %(<table role="presentation" cellpadding="0" cellspacing="0" style="margin-top:8px;"><tr>#{cells}</tr></table>)
    end

    # Same idea for Discovery rows.
    def view_source_label(source)
      source == :bluesky ? "Bluesky" : "X"
    end

    # Time-of-day stamp for tweet cards (e.g. "11:45am"). The date is already
    # carried by the day divider above the unit, so we don't repeat it here.
    # Uses ENV["TZ"] (set from config.timezone in bin/digest) so the same tweet
    # displays consistently on Mac and on GitHub Actions (UTC by default).
    def format_time(t)
      return nil if t.nil?

      t.getlocal.strftime("%-l:%M%p").sub("AM", "am").sub("PM", "pm")
    rescue StandardError
      nil
    end

    # Collapse retweets of the same original tweet into a single render unit, so
    # we don't repeat the original text once per retweeter. Quote tweets are
    # never merged (their commentary makes each one unique). Then sort units
    # chronologically (oldest first) so the reader can follow how a story
    # evolved within the theme.
    #
    # Returns an array of hashes:
    #   { type: :single, tweet: Tweet, at: Time? }
    #   { type: :retweet_group, anchor: Tweet, retweeters: [handle, ...], at: Time? }
    # `at` is the earliest known timestamp (for retweet groups, the time of the
    # first retweet we saw of that original).
    def theme_units(theme)
      units = []
      rt_index_by_key = {}

      theme.tweets.each do |t|
        if t.kind == :retweet && t.quoted_id
          key = t.quoted_id.to_s
          if (i = rt_index_by_key[key])
            unit = units[i]
            unit[:retweeters] << t.author unless unit[:retweeters].include?(t.author)
            if t.created_at && (unit[:at].nil? || t.created_at < unit[:at])
              unit[:at] = t.created_at
            end
          else
            rt_index_by_key[key] = units.size
            units << { type: :retweet_group, anchor: t, retweeters: [t.author], at: t.created_at }
          end
        else
          units << { type: :single, tweet: t, at: t.created_at }
        end
      end

      # Sort chronologically (oldest first). Tweets without a timestamp sink
      # to the end so they don't distort the story.
      units.sort_by { |u| u[:at] || Time.at(2_147_483_647) }
    end
  end
end
