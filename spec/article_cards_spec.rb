require "xtricate/digest"

RSpec.describe Xtricate::Digest do
  WSJ_URL = "https://www.wsj.com/finance/leopold-aschenbrenner-597633d3".freeze

  subject(:digest) do
    described_class.new(api_key: "k", model: "m", since: Time.now - 604_800,
                        lookback_days: 7, client: :unused, og_fetcher: og_fetcher)
  end

  let(:og_fetcher) { instance_double(Xtricate::OgFetch, fetch_many: [og_result]) }

  def og(**attrs)
    Xtricate::OgFetch::Result.new(url: WSJ_URL, resolved_url: WSJ_URL, site: "wsj.com", **attrs)
  end

  def card(url: WSJ_URL, title: "His Wedding Guests Were Arriving", **attrs)
    Xtricate::LinkPreview.new(url: url, title: title, **attrs)
  end

  def tweet_with(preview)
    Xtricate::Tweet.new(id: "1", author: "AntonJaegermm", kind: :original, text: "wild",
                        urls: [WSJ_URL], source: :twitter, card: preview)
  end

  def build_article(preview)
    clusters = digest.cluster_articles([tweet_with(preview)])
    digest.send(:build_articles, [{ "url" => WSJ_URL, "type" => "news_bulletin" }],
                clusters, digest.send(:card_index, [tweet_with(preview)]))
      .first
  end

  describe "#build_articles with a blocked paywall" do
    let(:og_result) { og(title: "Leopold Aschenbrenner 597633d3", fallback: true) }

    it "prefers Twitter's headline over the slug guess" do
      expect(build_article(card).title).to eq("His Wedding Guests Were Arriving")
    end

    it "takes the card's image and description too" do
      article = build_article(card(image: "https://pbs.twimg.com/card_img/a.jpg",
                                   description: "Nostradamus of AI"))

      expect(article.image).to eq("https://pbs.twimg.com/card_img/a.jpg")
      expect(article.description).to eq("Nostradamus of AI")
    end

    it "matches a card whose URL carries the outlet's referral params" do
      preview = card(url: "#{WSJ_URL}?reflink=e2twmkts")

      expect(build_article(preview).title).to eq("His Wedding Guests Were Arriving")
    end

    it "keeps the slug guess when no tweet carried a card" do
      expect(build_article(nil).title).to eq("Leopold Aschenbrenner 597633d3")
    end
  end

  describe "#build_payload" do
    let(:og_result) { og(title: "unused", fallback: true) }

    def payload_articles(preview)
      tweets = [tweet_with(preview)]
      digest.send(:build_payload, [], tweets, digest.cluster_articles(tweets),
                  digest.send(:card_index, tweets))[:articles]
    end

    it "hands Claude the headline, blurb, and outlet so it can judge depth" do
      entry = payload_articles(card(description: "Nostradamus of AI", site: "wsj.com")).first

      expect(entry[:title]).to eq("His Wedding Guests Were Arriving")
      expect(entry[:description]).to eq("Nostradamus of AI")
      expect(entry[:outlet]).to eq("wsj.com")
    end

    it "clips a long blurb rather than spending tokens on it" do
      entry = payload_articles(card(description: "x" * 900)).first

      expect(entry[:description].length).to eq(300)
    end

    it "omits the preview keys entirely for a link no card covered" do
      entry = payload_articles(nil).first

      expect(entry.keys).to eq(%i[url sharers sharer_count engagement preferred])
    end
  end

  describe "#build_articles when the scrape succeeded" do
    let(:og_result) do
      og(title: "The outlet's own og:title", image: "https://wsj.com/img.jpg",
         description: "og description")
    end

    it "keeps the scraped metadata rather than the card" do
      article = build_article(card(image: "https://pbs.twimg.com/card_img/a.jpg",
                                   description: "card description"))

      expect(article.title).to eq("The outlet's own og:title")
      expect(article.image).to eq("https://wsj.com/img.jpg")
      expect(article.description).to eq("og description")
    end
  end
end
