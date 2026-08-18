require "xtricate/fetch"

RSpec.describe Xtricate::Fetch do
  subject(:fetcher) { described_class.new(api_key: "test", since: Time.at(0)) }

  # normalize is private; exercise it directly with raw API-shaped hashes.
  def normalize(raw, author: "follower")
    fetcher.send(:normalize, raw, fallback_author: author)
  end

  describe "#normalize" do
    it "captures the nested quote when a retweet amplifies a quote tweet" do
      raw = {
        "id" => "200",
        "author" => { "userName" => "DanielDenvir" },
        "text" => "",
        "retweeted_tweet" => {
          "id" => "100",
          "author" => { "userName" => "infinite_jaz" },
          "text" => "We regret suggesting that international law is a matter of opinion",
          "quoted_tweet" => {
            "id" => "50",
            "author" => { "userName" => "Reuters" },
            "text" => "CORRECTION: Israel plans major settlement push across occupied West Bank"
          }
        }
      }

      t = normalize(raw)

      expect(t.kind).to eq(:retweet)
      expect(t.quoted_author).to eq("infinite_jaz")
      expect(t.quoted_text).to eq("We regret suggesting that international law is a matter of opinion")
      expect(t.quoted_inner_author).to eq("Reuters")
      expect(t.quoted_inner_text).to start_with("CORRECTION: Israel plans")
    end

    it "captures the nested quote on a plain quote-of-a-quote" do
      raw = {
        "id" => "300",
        "author" => { "userName" => "alice" },
        "text" => "my take",
        "quoted_tweet" => {
          "id" => "100",
          "author" => { "userName" => "bob" },
          "text" => "bob's take",
          "quote" => {
            "id" => "50",
            "author" => { "userName" => "carol" },
            "text" => "carol's original"
          }
        }
      }

      t = normalize(raw)

      expect(t.kind).to eq(:quote)
      expect(t.quoted_author).to eq("bob")
      expect(t.quoted_inner_author).to eq("carol")
      expect(t.quoted_inner_text).to eq("carol's original")
    end

    it "leaves inner-quote fields nil for a plain retweet" do
      raw = {
        "id" => "200",
        "author" => { "userName" => "DanielDenvir" },
        "text" => "",
        "retweeted_tweet" => {
          "id" => "100",
          "author" => { "userName" => "seth" },
          "text" => "just a take, no quote"
        }
      }

      t = normalize(raw)

      expect(t.quoted_author).to eq("seth")
      expect(t.quoted_inner_author).to be_nil
      expect(t.quoted_inner_text).to be_nil
    end
  end

  describe "#normalize on a stubbed retweet" do
    def stub_retweet(outer_text, stub = { "id" => "", "text" => "" })
      normalize({ "id" => "200", "author" => { "userName" => "willmenaker" },
                  "text" => outer_text, "retweeted_tweet" => stub })
    end

    it "recovers the amplified author and text from the RT prefix" do
      t = stub_retweet("RT @MacaesBruno: Analysts at Israel-funded think tanks argue otherwise")

      expect(t.quoted_author).to eq("MacaesBruno")
      expect(t.quoted_text).to eq("Analysts at Israel-funded think tanks argue otherwise")
    end

    it "leaves an empty amplified id nil rather than linking to a bare viewer URL" do
      t = stub_retweet("RT @MacaesBruno: something")

      expect(t.quoted_id).to be_nil
      expect(t.quoted_permalink).to be_nil
      expect(t.permalink).to eq("https://twitterwebviewer.com/?tweet=200")
    end

    it "drops a post with nothing to show at all" do
      expect(stub_retweet("")).to be_nil
    end

    it "keeps a post that has no text but does have media" do
      raw = { "id" => "300", "author" => { "userName" => "alice" }, "text" => "",
              "extendedEntities" => { "media" => [{ "type" => "photo",
                                                    "media_url_https" => "https://pbs.twimg.com/media/a.jpg" }] } }

      expect(normalize(raw).media.size).to eq(1)
    end

    it "prefers the amplified post's own text when the API supplies it" do
      t = stub_retweet("RT @seth: truncated ver…",
                       { "id" => "100", "author" => { "userName" => "seth" },
                         "text" => "the whole thing, untruncated" })

      expect(t.quoted_text).to eq("the whole thing, untruncated")
      expect(t.quoted_id).to eq("100")
    end
  end

  describe "#normalize card" do
    def card_tweet(card, entities: nil)
      raw = { "id" => "300", "author" => { "userName" => "AntonJaegermm" },
              "text" => "wild story https://t.co/V1llVgJkHt", "card" => card }
      raw["entities"] = entities if entities
      normalize(raw)
    end

    def wsj_card
      { "url" => "https://t.co/V1llVgJkHt",
        "binding_values" => [
          { "key" => "title",
            "value" => { "string_value" => "His Wedding Guests Were Arriving—Just as His $45 Billion Fund Was Falling Apart " } },
          { "key" => "description", "value" => { "string_value" => "Hailed as the &lsquo;Nostradamus of AI.&rsquo;" } },
          { "key" => "vanity_url", "value" => { "string_value" => "wsj.com" } },
          { "key" => "thumbnail_image", "value" => { "image_value" => { "url" => "https://pbs.twimg.com/card_img/small.jpg" } } },
          { "key" => "photo_image_full_size_large", "value" => { "image_value" => { "url" => "https://pbs.twimg.com/card_img/large.jpg" } } }
        ] }
    end

    let(:entities) do
      { "urls" => [{ "url" => "https://t.co/V1llVgJkHt",
                     "expanded_url" => "https://www.wsj.com/finance/leopold-aschenbrenner-597633d3?reflink=e2twmkts" }] }
    end

    it "keeps the headline, description, and largest image Twitter scraped" do
      card = card_tweet(wsj_card, entities: entities).card

      expect(card.title).to eq("His Wedding Guests Were Arriving—Just as His $45 Billion Fund Was Falling Apart")
      expect(card.description).to eq("Hailed as the ‘Nostradamus of AI.’")
      expect(card.image).to eq("https://pbs.twimg.com/card_img/large.jpg")
      expect(card.site).to eq("wsj.com")
    end

    it "trims the non-breaking space Twitter pads card titles with" do
      card = { "url" => "https://t.co/V1llVgJkHt",
               "binding_values" => [{ "key" => "title",
                                      "value" => { "string_value" => "A headline\u00a0" } }] }

      expect(card_tweet(card, entities: entities).card.title).to eq("A headline")
    end

    it "expands the card's t.co into the article URL the digest clusters on" do
      card = card_tweet(wsj_card, entities: entities).card

      expect(card.url).to eq("https://www.wsj.com/finance/leopold-aschenbrenner-597633d3?reflink=e2twmkts")
    end

    it "ignores a card whose link never resolves past t.co" do
      expect(card_tweet(wsj_card).card).to be_nil
    end

    it "reads binding_values handed over as a hash instead of a list" do
      card = { "url" => "https://t.co/V1llVgJkHt",
               "binding_values" => { "title" => { "string_value" => "A headline" } } }

      expect(card_tweet(card, entities: entities).card.title).to eq("A headline")
    end

    it "is nil when the tweet shared no link" do
      raw = { "id" => "400", "author" => { "userName" => "alice" }, "text" => "no card here" }

      expect(normalize(raw).card).to be_nil
    end

    it "takes the card off the retweeted post when the follower only retweeted" do
      raw = { "id" => "500", "author" => { "userName" => "willmenaker" },
              "text" => "RT @AntonJaegermm: wild story https://t.co/V1llVgJkHt",
              "retweeted_tweet" => { "id" => "300", "author" => { "userName" => "AntonJaegermm" },
                                     "text" => "wild story https://t.co/V1llVgJkHt",
                                     "card" => wsj_card, "entities" => entities } }

      expect(normalize(raw).card.title).to start_with("His Wedding Guests")
    end
  end

  describe "#normalize link_map" do
    it "maps t.co shortlinks to their expansions from url and media entities" do
      raw = {
        "id" => "300",
        "author" => { "userName" => "kenklippenstein" },
        "text" => "worth a read https://t.co/article https://t.co/photo",
        "entities" => {
          "urls" => [
            { "url" => "https://t.co/article", "expanded_url" => "https://www.example.com/p/story" }
          ]
        },
        "extendedEntities" => {
          "media" => [
            { "type" => "photo", "url" => "https://t.co/photo",
              "expanded_url" => "https://x.com/kenklippenstein/status/300/photo/1",
              "media_url_https" => "https://pbs.twimg.com/media/abc.jpg" }
          ]
        }
      }

      expect(normalize(raw).link_map).to eq(
        "https://t.co/article" => "https://www.example.com/p/story",
        "https://t.co/photo"   => "https://x.com/kenklippenstein/status/300/photo/1"
      )
    end

    it "collects expansions from the retweeted and quoted posts too" do
      raw = {
        "id" => "400",
        "author" => { "userName" => "DanielDenvir" },
        "text" => "",
        "retweeted_tweet" => {
          "id" => "100",
          "author" => { "userName" => "bob" },
          "text" => "these are positions https://t.co/outer",
          "entities" => {
            "urls" => [
              { "url" => "https://t.co/outer", "expanded_url" => "https://x.com/carol/status/50?s=20" }
            ]
          },
          "quoted_tweet" => {
            "id" => "50",
            "author" => { "userName" => "carol" },
            "text" => "carol's original https://t.co/inner",
            "entities" => {
              "urls" => [
                { "url" => "https://t.co/inner", "expanded_url" => "https://www.example.com/inner" }
              ]
            }
          }
        }
      }

      expect(normalize(raw).link_map).to eq(
        "https://t.co/outer" => "https://x.com/carol/status/50?s=20",
        "https://t.co/inner" => "https://www.example.com/inner"
      )
    end

    it "is empty when the payload carries no entities" do
      raw = { "id" => "500", "author" => { "userName" => "alice" }, "text" => "no links here" }

      expect(normalize(raw).link_map).to eq({})
    end
  end

  describe "requests" do
    Response = Struct.new(:status, :body, :headers, keyword_init: true) do
      def success? = status.between?(200, 299)
    end

    def ok(tweets = [])
      Response.new(status: 200, body: JSON.generate("tweets" => tweets), headers: {})
    end

    def error(status, headers: {})
      Response.new(status: status, body: "upstream said no", headers: headers)
    end

    class RecordingConn
      attr_reader :calls

      def initialize(responses)
        @responses = responses
        @calls = []
      end

      def get(_endpoint, params)
        @calls << params
        @responses.shift || raise("no response queued for call #{@calls.size}")
      end
    end

    def fetcher_for(conn, reply_handles: [], max_retries: 3, slept: [], since: Time.at(0), until_at: nil)
      described_class.new(
        api_key: "test", since: since, until_at: until_at, conn: conn,
        reply_handles: reply_handles, max_retries: max_retries,
        throttle: instance_double(Xtricate::Throttle, acquire: nil),
        sleeper: ->(seconds) { slept << seconds }
      )
    end

    describe "window bounds" do
      def tweet_at(id, time)
        { "id" => id, "author" => { "userName" => "dril" }, "text" => "post #{id}",
          "createdAt" => time.iso8601 }
      end

      it "stops the account at the first post older than since, since posts arrive newest-first" do
        conn = RecordingConn.new([ok([tweet_at("2", Time.new(2026, 8, 5)),
                                      tweet_at("1", Time.new(2026, 7, 1))])])

        tweets = fetcher_for(conn, since: Time.new(2026, 8, 1)).fetch_account("dril")

        expect(tweets.map(&:id)).to eq(%w[2])
      end

      it "skips posts newer than until_at and keeps the in-window ones underneath them" do
        conn = RecordingConn.new([ok([tweet_at("3", Time.new(2026, 8, 20)),
                                      tweet_at("2", Time.new(2026, 8, 5)),
                                      tweet_at("1", Time.new(2026, 7, 1))])])

        tweets = fetcher_for(conn, since: Time.new(2026, 8, 1),
                                   until_at: Time.new(2026, 8, 8)).fetch_account("dril")

        expect(tweets.map(&:id)).to eq(%w[2])
      end

      it "keeps every recent post when no until_at is given" do
        conn = RecordingConn.new([ok([tweet_at("2", Time.new(2026, 8, 20)),
                                      tweet_at("1", Time.new(2026, 8, 5))])])

        tweets = fetcher_for(conn, since: Time.new(2026, 8, 1)).fetch_account("dril")

        expect(tweets.map(&:id)).to eq(%w[2 1])
      end
    end

    describe "includeReplies" do
      it "asks for replies for a handle whose subscriber opted in" do
        conn = RecordingConn.new([ok])

        fetcher_for(conn, reply_handles: %w[dril]).fetch_account("dril")

        expect(conn.calls.first[:includeReplies]).to be(true)
      end

      it "omits replies for a handle nobody opted into, so they are not billed for" do
        conn = RecordingConn.new([ok])

        fetcher_for(conn, reply_handles: %w[someoneelse]).fetch_account("dril")

        expect(conn.calls.first[:includeReplies]).to be(false)
      end

      it "matches the opted-in handle regardless of case" do
        conn = RecordingConn.new([ok])

        fetcher_for(conn, reply_handles: %w[DRIL]).fetch_account("dril")

        expect(conn.calls.first[:includeReplies]).to be(true)
      end

      it "omits replies when no subscriber opted in at all" do
        conn = RecordingConn.new([ok])

        fetcher_for(conn).fetch_account("dril")

        expect(conn.calls.first[:includeReplies]).to be(false)
      end
    end

    describe "retries" do
      it "retries a rate-limited request and keeps the tweets from the retry" do
        raw = { "id" => "1", "author" => { "userName" => "dril" }, "text" => "hello",
                "createdAt" => "Mon Jan 06 12:00:00 +0000 2025" }
        conn = RecordingConn.new([error(429), ok([raw])])

        tweets = fetcher_for(conn).fetch_account("dril")

        expect(conn.calls.size).to eq(2)
        expect(tweets.map(&:id)).to eq(%w[1])
      end

      it "waits the number of seconds the server asked for" do
        slept = []
        conn = RecordingConn.new([error(429, headers: { "retry-after" => "7" }), ok])

        fetcher_for(conn, slept: slept).fetch_account("dril")

        expect(slept).to eq([7])
      end

      it "caps an implausible Retry-After so one account cannot stall the run" do
        slept = []
        conn = RecordingConn.new([error(429, headers: { "retry-after" => "3600" }), ok])

        fetcher_for(conn, slept: slept).fetch_account("dril")

        expect(slept).to eq([Xtricate::Http::MAX_RETRY_AFTER])
      end

      it "backs off further on each successive attempt" do
        slept = []
        conn = RecordingConn.new([error(500), error(500), ok])

        fetcher_for(conn, slept: slept).fetch_account("dril")

        expect(slept.first).to be < slept.last
      end

      it "keeps the jitter too small for one attempt's wait to reach the next one's" do
        slept = []
        20.times do
          fetcher_for(RecordingConn.new([error(500), error(500), ok]), slept: slept)
            .fetch_account("dril")
        end
        pairs = slept.each_slice(2)

        expect(pairs.map(&:first).max).to be < pairs.map(&:last).min
      end

      it "gives up after max_retries and records the account as unfetched" do
        conn = RecordingConn.new(Array.new(5) { error(503) })
        fetcher = fetcher_for(conn, max_retries: 2)

        expect(fetcher.fetch_account("dril")).to eq([])
        expect(conn.calls.size).to eq(3)
        expect(fetcher.failures).to eq(%w[dril])
      end

      it "does not retry a handle that no longer exists" do
        conn = RecordingConn.new([error(404)])
        fetcher = fetcher_for(conn)

        expect(fetcher.fetch_account("deleted")).to eq([])
        expect(conn.calls.size).to eq(1)
        expect(fetcher.failures).to eq(%w[deleted])
      end

      it "retries a response that is not JSON at all" do
        conn = RecordingConn.new(
          [Response.new(status: 200, body: "<html>gateway</html>", headers: {}), ok]
        )

        expect { fetcher_for(conn).fetch_account("dril") }.not_to raise_error
        expect(conn.calls.size).to eq(2)
      end

      it "leaves a successful account out of failures" do
        fetcher = fetcher_for(RecordingConn.new([ok]))
        fetcher.fetch_account("dril")

        expect(fetcher.failures).to be_empty
      end
    end

    describe "#fetch_all" do
      it "returns one activity per handle, in the order given" do
        conn = RecordingConn.new(Array.new(3) { ok })

        activities = fetcher_for(conn).fetch_all(%w[alice bob carol])

        expect(activities.map(&:handle)).to eq(%w[alice bob carol])
        expect(activities.map(&:source).uniq).to eq(%i[twitter])
      end
    end
  end
end
