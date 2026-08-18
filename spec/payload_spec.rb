require "xtricate/digest"

RSpec.describe Xtricate::Digest do
  def digest(**overrides)
    described_class.new(
      **{ api_key: "k", model: "m", window: week_window,
          client: :unused, og_fetcher: :unused }.merge(overrides)
    )
  end

  def post(id:, author:, likes: 0, urls: [], text: "post #{id}")
    Xtricate::Tweet.new(id: id, author: author, kind: :original, text: text,
                        urls: urls, like_count: likes, source: :twitter)
  end

  def payload(built, tweets)
    built.send(:build_payload, [], tweets, built.cluster_articles(tweets), {})
  end

  describe "#build_payload tweet selection" do
    let(:one_loud_account_and_five_quiet_ones) do
      loud = (1..10).map { |i| post(id: "loud#{i}", author: "megaphone", likes: 1_000 + i) }
      quiet = (1..5).map { |i| post(id: "quiet#{i}", author: "small#{i}", likes: i) }
      loud + quiet
    end

    it "reserves payload_tweets_per_account for every account before ranking the rest" do
      entries = payload(digest(payload_tweets_per_account: 2, max_payload_tweets: 7),
                        one_loud_account_and_five_quiet_ones)[:tweets]

      expect(entries.count { |t| t[:by] == "megaphone" }).to eq(2)
    end

    it "fills leftover budget by engagement rather than sending a short payload" do
      entries = payload(digest(payload_tweets_per_account: 2, max_payload_tweets: 12),
                        one_loud_account_and_five_quiet_ones)[:tweets]

      expect(entries.size).to eq(12)
      expect(entries.count { |t| t[:by] == "megaphone" }).to eq(7)
    end

    it "still gives every account its reserved share when the budget is tight" do
      entries = payload(digest(payload_tweets_per_account: 1, max_payload_tweets: 6),
                        one_loud_account_and_five_quiet_ones)[:tweets]

      expect(entries.map { |t| t[:by] }.uniq.size).to eq(6)
    end

    it "leaves room for quiet accounts a pure engagement ranking would crowd out" do
      entries = payload(digest(payload_tweets_per_account: 2, max_payload_tweets: 7),
                        one_loud_account_and_five_quiet_ones)[:tweets]

      expect(entries.map { |t| t[:by] }.uniq).to include("small1", "small5")
    end

    it "would crowd them out without the per-account cap" do
      entries = payload(digest(payload_tweets_per_account: 100, max_payload_tweets: 7),
                        one_loud_account_and_five_quiet_ones)[:tweets]

      expect(entries.map { |t| t[:by] }.uniq).to eq(%w[megaphone])
    end

    it "still honours the overall budget" do
      entries = payload(digest(payload_tweets_per_account: 3, max_payload_tweets: 4),
                        one_loud_account_and_five_quiet_ones)[:tweets]

      expect(entries.size).to eq(4)
    end

    it "ranks what survives the per-account cap by engagement" do
      entries = payload(digest(payload_tweets_per_account: 1),
                        one_loud_account_and_five_quiet_ones)[:tweets]

      expect(entries.first[:by]).to eq("megaphone")
    end

    it "sends a thread head once, not each of its continuations" do
      head = post(id: "1", author: "dril")
      cont = post(id: "2", author: "dril")
      head.thread_root_id = "1"
      head.thread_continuations = [cont]
      cont.thread_root_id = "1"

      entries = payload(digest, [head, cont])[:tweets]

      expect(entries.map { |t| t[:id] }).to eq(%w[1])
    end

    it "clips a very long thread rather than spending the whole prompt on it" do
      head = post(id: "1", author: "dril", text: "opener")
      head.thread_root_id = "1"
      head.thread_continuations = (1..50).map { |i| post(id: "c#{i}", author: "dril", text: "x" * 200) }

      entries = payload(digest, [head])[:tweets]

      expect(entries.first[:text].length).to eq(described_class::MAX_MODEL_TEXT_CHARS)
    end
  end

  describe "#build_payload article selection" do
    def article_posts(count, host:, likes: 1)
      (1..count).map do |i|
        post(id: "#{host}#{i}", author: "a#{i}", likes: likes,
             urls: ["https://#{host}/piece-#{i}"])
      end
    end

    it "does not let preferred outlets past the cap grow the payload without limit" do
      built = digest(preferred_outlets: %w[jacobin.com])
      tweets = article_posts(200, host: "jacobin.com")

      entries = payload(built, tweets)[:articles]

      expect(entries.size)
        .to be <= described_class::MAX_PAYLOAD_ARTICLES + described_class::MAX_PREFERRED_IN_PAYLOAD
    end

    it "still reaches for a quiet preferred essay a plain ranking would drop" do
      built = digest(preferred_outlets: %w[jacobin.com])
      loud = article_posts(described_class::MAX_PAYLOAD_ARTICLES, host: "reuters.com", likes: 500)
      quiet = article_posts(1, host: "jacobin.com", likes: 0)

      urls = payload(built, loud + quiet)[:articles].map { |a| a[:url] }

      expect(urls).to include("https://jacobin.com/piece-1")
    end

    it "sends a sample of sharers plus the full count, not every sharer" do
      sharers = (1..30).map { |i| post(id: i.to_s, author: "sharer#{i}", urls: ["https://ex.com/a"]) }

      entry = payload(digest, sharers)[:articles].first

      expect(entry[:sharers].size).to eq(described_class::MAX_PAYLOAD_SHARERS)
      expect(entry[:sharer_count]).to eq(30)
    end
  end

  describe "#cluster_articles" do
    it "counts a repeated post once without deep-comparing every tweet field" do
      tweet = post(id: "1", author: "dril", urls: %w[https://ex.com/a https://ex.com/a])

      cluster = digest.cluster_articles([tweet]).first

      expect(cluster.mentions.size).to eq(1)
    end

    it "keeps distinct posts sharing one link" do
      tweets = [post(id: "1", author: "dril", urls: %w[https://ex.com/a]),
                post(id: "2", author: "wint", urls: %w[https://ex.com/a])]

      cluster = digest.cluster_articles(tweets).first

      expect(cluster.sharers).to eq(%w[dril wint])
    end
  end
end
