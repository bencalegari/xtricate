require "xtricate/digest"

RSpec.describe Xtricate::Digest do
  subject(:digest) do
    described_class.new(api_key: "k", model: "m", window: week_window, client: :unused, og_fetcher: :unused)
  end

  def post(id:, author:, likes: 0, kind: :original, at: nil, quoted_id: nil, source: :twitter)
    Xtricate::Tweet.new(id: id, author: author, kind: kind, text: "post #{id}",
                        urls: [], like_count: likes, created_at: at,
                        quoted_id: quoted_id, source: source)
  end

  def activity(handle, tweets, source: :twitter)
    Xtricate::AccountActivity.new(handle: handle, tweets: tweets, source: source)
  end

  def theme(*tweets) = Xtricate::Digest::Theme.new(name: "AI", tweets: tweets)

  def article(*sharers)
    Xtricate::Digest::Article.new(url: "https://ex.com/a", type: "other", sharers: sharers)
  end

  describe "#build_solo_picks" do
    it "gives an account with no theme and no article its best post" do
      quiet = activity("dril", [post(id: "1", author: "dril", likes: 5),
                                post(id: "2", author: "dril", likes: 90)])

      picks = digest.build_solo_picks([quiet], [], [])

      expect(picks.map(&:handle)).to eq(%w[dril])
      expect(picks.first.tweet.id).to eq("2")
    end

    it "skips an account whose post already appears in a theme" do
      shown = post(id: "1", author: "dril", likes: 5)

      picks = digest.build_solo_picks([activity("dril", [shown])], [theme(shown)], [])

      expect(picks).to be_empty
    end

    it "skips an account that only got in via a retweet inside a theme" do
      rt = post(id: "9", author: "dril", kind: :retweet, quoted_id: "1")

      picks = digest.build_solo_picks([activity("dril", [rt])], [theme(rt)], [])

      expect(picks).to be_empty
    end

    it "skips an account credited as a sharer on a picked article" do
      picks = digest.build_solo_picks(
        [activity("dril", [post(id: "1", author: "dril")])], [], [article("dril")]
      )

      expect(picks).to be_empty
    end

    it "matches followed handles against theme authors case-insensitively" do
      shown = post(id: "1", author: "DRIL")

      picks = digest.build_solo_picks([activity("dril", [shown])], [theme(shown)], [])

      expect(picks).to be_empty
    end

    it "skips accounts that posted nothing this week" do
      expect(digest.build_solo_picks([activity("dril", [])], [], [])).to be_empty
    end

    it "prefers the account's own post over a higher-engagement retweet" do
      tweets = [post(id: "1", author: "dril", likes: 3),
                post(id: "2", author: "dril", likes: 900, kind: :retweet, quoted_id: "x")]

      picks = digest.build_solo_picks([activity("dril", tweets)], [], [])

      expect(picks.first.tweet.id).to eq("1")
    end

    it "falls back to a retweet when the account only retweeted" do
      rt = post(id: "2", author: "dril", likes: 900, kind: :retweet, quoted_id: "x")

      picks = digest.build_solo_picks([activity("dril", [rt])], [], [])

      expect(picks.first.tweet.id).to eq("2")
    end

    it "picks the thread head, not a continuation, when a thread wins" do
      head = post(id: "1", author: "dril", likes: 10)
      cont = post(id: "2", author: "dril", likes: 40)
      head.thread_root_id = "1"
      head.thread_continuations = [cont]
      cont.thread_root_id = "1"

      picks = digest.build_solo_picks([activity("dril", [head, cont])], [], [])

      expect(picks.first.tweet.id).to eq("1")
    end

    it "breaks an engagement tie with the newer post" do
      older = post(id: "1", author: "dril", likes: 10, at: Time.at(1_000))
      newer = post(id: "2", author: "dril", likes: 10, at: Time.at(2_000))

      picks = digest.build_solo_picks([activity("dril", [older, newer])], [], [])

      expect(picks.first.tweet.id).to eq("2")
    end

    it "orders picks by engagement, loudest first" do
      activities = [activity("a", [post(id: "1", author: "a", likes: 2)]),
                    activity("b", [post(id: "2", author: "b", likes: 50)])]

      picks = digest.build_solo_picks(activities, [], [])

      expect(picks.map(&:handle)).to eq(%w[b a])
    end

    context "with a cap" do
      subject(:digest) do
        described_class.new(api_key: "k", model: "m", window: week_window, max_solo_picks: 2,
                            client: :unused, og_fetcher: :unused)
      end

      let(:activities) do
        (1..5).map { |i| activity("a#{i}", [post(id: i.to_s, author: "a#{i}", likes: i * 10)]) }
      end

      it "keeps the loudest accounts and drops the quiet tail" do
        picks = digest.build_solo_picks(activities, [], [])

        expect(picks.map(&:handle)).to eq(%w[a5 a4])
      end

      it "drops the section entirely at a cap of zero" do
        capped = described_class.new(api_key: "k", model: "m", window: week_window, max_solo_picks: 0,
                                     client: :unused, og_fetcher: :unused)

        expect(capped.build_solo_picks(activities, [], [])).to be_empty
      end

      it "returns everyone when there are fewer accounts than the cap" do
        picks = digest.build_solo_picks(activities.first(1), [], [])

        expect(picks.map(&:handle)).to eq(%w[a1])
      end
    end

    it "carries the account's source so bluesky picks link to bsky.app" do
      pick = digest.build_solo_picks(
        [activity("dril.bsky.social", [post(id: "1", author: "dril.bsky.social", source: :bluesky)],
                  source: :bluesky)], [], []
      ).first

      expect(pick.profile_url).to eq("https://bsky.app/profile/dril.bsky.social")
    end
  end
end
