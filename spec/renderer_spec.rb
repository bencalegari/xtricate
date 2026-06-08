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
end
