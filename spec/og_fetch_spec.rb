require "xtricate/og_fetch"

RSpec.describe Xtricate::OgFetch do
  subject(:og) { described_class.new }

  # Exercise the private URL-derivation helpers directly: they're the whole
  # fallback path when a site blocks us, and they need no network.
  def title_for(url) = og.send(:url_to_title, url)
  def site_for(url) = og.send(:hostname, url)
  def untrack(url) = og.send(:untrack, url)

  describe "deriving a title from a URL" do
    it "titleizes a slug and uppercases known acronyms" do
      expect(title_for("https://example.com/2026/05/28/ai-spending-roi-enterprise-costs"))
        .to eq("AI Spending ROI Enterprise Costs")
    end

    it "strips a trailing date from a Reuters-style slug" do
      url = "https://www.reuters.com/investigations/us-contractor-mystery-boeings-operating-sudan-paramilitary-supply-routes-2026-07-15/"
      expect(title_for(url)).to eq("US Contractor Mystery Boeings Operating Sudan Paramilitary Supply Routes")
    end

    it "skips a trailing CMS id segment and uses the readable slug" do
      url = "https://www.appenmedia.com/opinion/letter-to-the-editor-creepiest-sales-demo/article_a8f0cc6c-29d3-41f7-8668-8a855f760efb.html"
      expect(title_for(url)).to eq("Letter To The Editor Creepiest Sales Demo")
    end

    it "returns nil for a shortener token rather than inventing a title" do
      expect(title_for("https://reut.rs/4pk1Got")).to be_nil
      expect(title_for("https://trib.al/vDu5OtN")).to be_nil
      expect(title_for("https://bit.ly/3xYzAbc")).to be_nil
    end

    it "returns nil for an opaque token on a non-shortener host" do
      expect(title_for("https://example.com/p/4pk1Got")).to be_nil
    end

    it "returns nil for a bare numeric id path" do
      expect(title_for("https://example.com/1234567")).to be_nil
    end

    it "returns nil when there is no path at all" do
      expect(title_for("https://example.com/")).to be_nil
    end

    it "returns nil for a malformed URL" do
      expect(title_for("http://[bad")).to be_nil
    end
  end

  describe "#hostname" do
    it "drops the www prefix" do
      expect(site_for("https://www.reuters.com/x/y")).to eq("reuters.com")
    end
  end

  describe "#untrack" do
    it "drops tracking params and keeps the rest" do
      expect(untrack("https://ex.com/a?utm_source=twitter&id=7&fbclid=xy"))
        .to eq("https://ex.com/a?id=7")
    end

    it "drops the query entirely when only tracking params are present" do
      expect(untrack("https://ex.com/a?utm_medium=Social&utm_source=twitter"))
        .to eq("https://ex.com/a")
    end

    it "leaves a query-less URL untouched" do
      expect(untrack("https://ex.com/a")).to eq("https://ex.com/a")
    end
  end

  describe "#fetch when the article blocks us" do
    # Simulates the reut.rs case: the redirect chain resolves, then the final
    # page 401s. The card should still show the real outlet and headline.
    it "falls back to the resolved URL's slug, not the shortlink's" do
      allow(og).to receive(:fetch_html_with_retry).and_return(
        [nil, "http 401",
         "https://www.reuters.com/investigations/us-contractor-boeings-sudan-supply-routes-2026-07-15/?utm_source=twitter"]
      )

      result = og.fetch("https://reut.rs/4pk1Got")

      expect(result.url).to eq("https://reut.rs/4pk1Got")
      expect(result.resolved_url)
        .to eq("https://www.reuters.com/investigations/us-contractor-boeings-sudan-supply-routes-2026-07-15/")
      expect(result.title).to eq("US Contractor Boeings Sudan Supply Routes")
      expect(result.site).to eq("reuters.com")
    end

    it "falls back to the hostname when nothing resolves" do
      allow(og).to receive(:fetch_html_with_retry)
        .and_return([nil, "all attempts failed", "https://reut.rs/4pk1Got"])

      result = og.fetch("https://reut.rs/4pk1Got")

      expect(result.title).to eq("reut.rs")
      expect(result.site).to eq("reut.rs")
    end
  end

  describe "#fetch when OG tags are present" do
    it "decodes named entities in the title and prefers og:site_name" do
      html = <<~HTML
        <html><head>
        <meta property="og:title" content="The creepiest &lsquo;sales demo&rsquo; of all time" />
        <meta property="og:site_name" content="Appen Media" />
        <meta property="og:image" content="/img/hero.jpg" />
        <meta property="og:description" content="A letter to the editor." />
        </head></html>
      HTML
      allow(og).to receive(:fetch_html_with_retry)
        .and_return([html, "ok", "https://www.appenmedia.com/opinion/creepy-demo/"])

      result = og.fetch("https://www.appenmedia.com/opinion/creepy-demo/")

      expect(result.title).to eq("The creepiest ‘sales demo’ of all time")
      expect(result.site).to eq("Appen Media")
      expect(result.image).to eq("https://www.appenmedia.com/img/hero.jpg")
    end

    it "resolves relative og:image against the resolved URL, not the shortlink" do
      html = %(<meta property="og:image" content="/hero.jpg">)
      allow(og).to receive(:fetch_html_with_retry)
        .and_return([html, "ok", "https://news.example.com/story/big-news"])

      result = og.fetch("https://bit.ly/abc123")

      expect(result.image).to eq("https://news.example.com/hero.jpg")
    end
  end

  describe "#fetch_many" do
    it "scrapes a URL once even when several batches ask for it" do
      url = "https://news.example.com/story"
      allow(og).to receive(:fetch).with(url)
        .and_return(described_class::Result.new(url: url, title: "Story"))

      first = og.fetch_many([url])
      second = og.fetch_many([url])

      expect(og).to have_received(:fetch).once
      expect(second.first).to be(first.first)
    end

    it "returns results in the order it was asked for them" do
      %w[a b].each do |slug|
        allow(og).to receive(:fetch).with("https://example.com/#{slug}")
          .and_return(described_class::Result.new(url: "https://example.com/#{slug}", title: slug))
      end

      results = og.fetch_many(%w[https://example.com/b https://example.com/a])

      expect(results.map(&:title)).to eq(%w[b a])
    end
  end
end
