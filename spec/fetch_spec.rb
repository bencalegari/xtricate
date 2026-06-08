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
end
