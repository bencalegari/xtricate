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
end
