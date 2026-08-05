require "time"

RSpec.describe Xtricate::Renderer do
  subject(:renderer) { described_class.new }

  # Minimal stand-in for a Theme: the renderer only reads #name and #tweets.
  def theme(*tweets) = OpenStruct.new(name: "AI", tweets: tweets)

  def tweet(**attrs)
    Xtricate::Tweet.new(source: :x, **attrs)
  end

  def original(id:, author:, text: "the take", at: nil)
    tweet(id: id, author: author, kind: :original, text: text, created_at: at)
  end

  def retweet(id:, by:, of:, from:, text: "the take", at: nil)
    tweet(id: id, author: by, kind: :retweet, quoted_id: of, quoted_author: from,
          quoted_text: text, created_at: at)
  end

  describe "#theme_units" do
    it "renders a lone original as a single unit with no retweeters" do
      units = renderer.theme_units(theme(original(id: "1", author: "alice")))

      expect(units.size).to eq(1)
      expect(units.first).to include(type: :single, retweeters: [])
      expect(units.first[:tweet].author).to eq("alice")
    end

    it "merges an original with a retweet of it into one single unit" do
      orig = original(id: "100", author: "seth")
      rt   = retweet(id: "200", by: "will", of: "100", from: "seth")

      units = renderer.theme_units(theme(orig, rt))

      expect(units.size).to eq(1)
      unit = units.first
      expect(unit[:type]).to eq(:single)
      expect(unit[:tweet].author).to eq("seth")
      expect(unit[:retweeters]).to eq(["will"])
    end

    it "merges regardless of arrival order (retweet seen before original)" do
      orig = original(id: "100", author: "seth")
      rt   = retweet(id: "200", by: "will", of: "100", from: "seth")

      units = renderer.theme_units(theme(rt, orig))

      expect(units.size).to eq(1)
      expect(units.first[:type]).to eq(:single)
      expect(units.first[:tweet].author).to eq("seth")
      expect(units.first[:retweeters]).to eq(["will"])
    end

    it "accumulates multiple distinct retweeters and de-dupes repeats" do
      orig = original(id: "100", author: "seth")
      rts = [
        retweet(id: "201", by: "will", of: "100", from: "seth"),
        retweet(id: "202", by: "bob",  of: "100", from: "seth"),
        retweet(id: "203", by: "will", of: "100", from: "seth")
      ]

      units = renderer.theme_units(theme(orig, *rts))

      expect(units.size).to eq(1)
      expect(units.first[:retweeters]).to eq(%w[will bob])
    end

    it "falls back to a retweet_group when the source tweet is absent" do
      rt = retweet(id: "200", by: "will", of: "100", from: "seth")

      units = renderer.theme_units(theme(rt))

      expect(units.size).to eq(1)
      unit = units.first
      expect(unit[:type]).to eq(:retweet_group)
      expect(unit[:anchor].quoted_author).to eq("seth")
      expect(unit[:retweeters]).to eq(["will"])
    end

    it "keeps quote tweets as separate single units (commentary is unique)" do
      q1 = tweet(id: "1", author: "a", kind: :quote, quoted_id: "100",
                 quoted_author: "seth", text: "thoughts one")
      q2 = tweet(id: "2", author: "b", kind: :quote, quoted_id: "100",
                 quoted_author: "seth", text: "thoughts two")

      units = renderer.theme_units(theme(q1, q2))

      expect(units.map { |u| u[:type] }).to eq(%i[single single])
    end

    it "sorts units chronologically, oldest first" do
      late  = original(id: "1", author: "a", at: Time.parse("2026-06-08 12:00"))
      early = original(id: "2", author: "b", at: Time.parse("2026-06-08 09:00"))

      units = renderer.theme_units(theme(late, early))

      expect(units.map { |u| u[:tweet].author }).to eq(%w[b a])
    end

    it "anchors a merged unit on the original's own timestamp" do
      orig = original(id: "100", author: "seth", at: Time.parse("2026-06-08 10:05"))
      rt   = retweet(id: "200", by: "will", of: "100", from: "seth",
                     at: Time.parse("2026-06-08 10:10"))

      units = renderer.theme_units(theme(orig, rt))

      expect(units.first[:at]).to eq(Time.parse("2026-06-08 10:05"))
    end
  end

  describe "#render_tweet_text" do
    def with_links(text, map)
      renderer.render_tweet_text(text, tweet(id: "1", author: "ken", kind: :original,
                                             text: text, link_map: map))
    end

    it "points a t.co that expands to a post at the viewer, keeping the t.co as the text" do
      html = with_links(
        "these are positions https://t.co/oDs4KGFv8e",
        "https://t.co/oDs4KGFv8e" => "https://x.com/RealVanJackson/status/2082569821955539065?s=20"
      )

      expect(html).to include(
        %(<a href="https://twitterwebviewer.com/?tweet=2082569821955539065" ) +
        %(style="color:#1d4ed8; text-decoration:none;">https://t.co/oDs4KGFv8e</a>)
      )
    end

    it "uses the viewer for a t.co that expands to a post's photo" do
      html = with_links(
        "look https://t.co/zqbtf8c6gy",
        "https://t.co/zqbtf8c6gy" => "https://x.com/_waleedshahid/status/2084456651588055410/photo/1"
      )

      expect(html).to include(%(href="https://twitterwebviewer.com/?tweet=2084456651588055410"))
    end

    it "leaves a t.co that expands to an article pointing at the t.co" do
      html = with_links(
        "scoop https://t.co/j7Tgt5fQ9f",
        "https://t.co/j7Tgt5fQ9f" => "https://www.kenklippenstein.com/p/exclusive-francesca-hong"
      )

      expect(html).to include(%(href="https://t.co/j7Tgt5fQ9f" style="color:#1d4ed8; text-decoration:none;">https://t.co/j7Tgt5fQ9f</a>))
    end

    it "leaves an unmapped t.co pointing at the t.co" do
      html = with_links("mystery https://t.co/unknown", {})

      expect(html).to include(%(href="https://t.co/unknown" style="color:#1d4ed8; text-decoration:none;">https://t.co/unknown</a>))
    end

    it "sends a bare x.com post link to the viewer" do
      html = renderer.render_tweet_text("see https://x.com/RealVanJackson/status/2082569821955539065")

      expect(html).to include(
        %(href="https://twitterwebviewer.com/?tweet=2082569821955539065" ) +
        %(style="color:#1d4ed8; text-decoration:none;">) +
        "https://x.com/RealVanJackson/status/2082569821955539065</a>"
      )
    end

    it "keeps trailing sentence punctuation outside the link" do
      html = with_links(
        "read this (https://t.co/abc).",
        "https://t.co/abc" => "https://x.com/carol/status/50"
      )

      expect(html).to include(">https://t.co/abc</a>).")
    end

    it "escapes the surrounding text" do
      expect(renderer.render_tweet_text("<script>alert(1)</script>")).not_to include("<script>")
    end
  end

  describe "timezone handling" do
    let(:at) { Time.parse("2026-06-08 17:30 UTC") }

    def in_zone(zone) = described_class.new(timezone: zone)

    it "stamps a post in the subscriber's own timezone, not the process's" do
      expect(in_zone("America/Los_Angeles").format_time(at)).to eq("10:30am")
      expect(in_zone("America/New_York").format_time(at)).to eq("1:30pm")
    end

    it "dates the day divider in the subscriber's own timezone" do
      midnight_utc = Time.parse("2026-06-09 03:00 UTC")

      expect(in_zone("America/Los_Angeles").format_day(midnight_utc)).to eq("Mon, Jun 8")
      expect(in_zone("America/New_York").format_day(midnight_utc)).to eq("Mon, Jun 8")
      expect(in_zone("UTC").format_day(midnight_utc)).to eq("Tue, Jun 9")
    end

    it "restores the process timezone afterward" do
      original = ENV.fetch("TZ", nil)
      ENV["TZ"] = "America/Chicago"

      in_zone("Asia/Tokyo").format_time(at)

      expect(ENV.fetch("TZ", nil)).to eq("America/Chicago")
    ensure
      original.nil? ? ENV.delete("TZ") : ENV["TZ"] = original
    end

    it "leaves the process timezone unset if it started unset" do
      original = ENV.fetch("TZ", nil)
      ENV.delete("TZ")

      in_zone("Asia/Tokyo").format_time(at)

      expect(ENV).not_to have_key("TZ")
    ensure
      ENV["TZ"] = original unless original.nil?
    end

    it "returns nil for a missing timestamp" do
      expect(in_zone("UTC").format_time(nil)).to be_nil
      expect(in_zone("UTC").format_day(nil)).to be_nil
    end
  end
end
