require "xtricate/bluesky_fetch"

RSpec.describe Xtricate::BlueskyFetch do
  subject(:fetcher) { described_class.new(since: Time.at(0)) }

  def normalize(item, follower: "follower.bsky.social")
    fetcher.send(:normalize, item, follower: follower)
  end

  def post(text:, embed: nil, handle: "dril.bsky.social")
    p = { "uri" => "at://did:plc:abc/app.bsky.feed.post/xyz",
          "author" => { "handle" => handle },
          "record" => { "text" => text, "createdAt" => "2026-07-31T20:12:43Z" } }
    p["embed"] = embed if embed
    p
  end

  describe "#normalize" do
    it "keeps a post with text" do
      expect(normalize({ "post" => post(text: "a thought") }).text).to eq("a thought")
    end

    it "drops a post with no text, no media, and no link" do
      expect(normalize({ "post" => post(text: "") })).to be_nil
    end

    it "keeps a text-free post that carries an image" do
      embed = { "$type" => "app.bsky.embed.images#view",
                "images" => [{ "thumb" => "https://cdn.bsky.app/t.jpg", "alt" => "" }] }

      expect(normalize({ "post" => post(text: "", embed: embed) }).media.size).to eq(1)
    end

    it "drops a repost whose original post has nothing to show" do
      item = { "post" => post(text: ""),
               "reason" => { "$type" => "app.bsky.feed.defs#reasonRepost",
                             "indexedAt" => "2026-07-31T20:30:00Z" } }

      expect(normalize(item)).to be_nil
    end

    it "keeps a repost whose original post has text" do
      item = { "post" => post(text: "the original take"),
               "reason" => { "$type" => "app.bsky.feed.defs#reasonRepost",
                             "indexedAt" => "2026-07-31T20:30:00Z" } }

      tweet = normalize(item)

      expect(tweet.kind).to eq(:retweet)
      expect(tweet.amplified_text).to eq("the original take")
    end
  end

  describe "window bounds" do
    Response = Struct.new(:status, :body, :headers, keyword_init: true) do
      def success? = status.between?(200, 299)
    end

    class FeedConn
      def initialize(feed) = @feed = feed

      def get(_endpoint, _params)
        Response.new(status: 200, body: JSON.generate("feed" => @feed), headers: {})
      end
    end

    def item_at(text, time)
      { "post" => { "uri" => "at://did:plc:abc/app.bsky.feed.post/#{text}",
                    "author" => { "handle" => "dril.bsky.social" },
                    "record" => { "text" => text, "createdAt" => time.utc.iso8601 } } }
    end

    def fetcher_for(feed, since:, until_at: nil)
      described_class.new(
        since: since, until_at: until_at, conn: FeedConn.new(feed),
        throttle: instance_double(Xtricate::Throttle, acquire: nil)
      )
    end

    it "stops the account at the first post older than since" do
      feed = [item_at("new", Time.new(2026, 8, 5)), item_at("old", Time.new(2026, 7, 1))]

      tweets = fetcher_for(feed, since: Time.new(2026, 8, 1)).fetch_account("dril.bsky.social")

      expect(tweets.map(&:text)).to eq(%w[new])
    end

    it "skips posts newer than until_at and keeps the in-window ones underneath them" do
      feed = [item_at("newest", Time.new(2026, 8, 20)),
              item_at("inwindow", Time.new(2026, 8, 5)),
              item_at("old", Time.new(2026, 7, 1))]

      tweets = fetcher_for(feed, since: Time.new(2026, 8, 1),
                                 until_at: Time.new(2026, 8, 8)).fetch_account("dril.bsky.social")

      expect(tweets.map(&:text)).to eq(%w[inwindow])
    end
  end
end
