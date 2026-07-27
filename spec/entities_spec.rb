require "xtricate/entities"

RSpec.describe Xtricate::Entities do
  describe ".decode" do
    it "decodes the core markup entities" do
      expect(described_class.decode("a &amp; b &lt;c&gt; &quot;d&quot; &apos;e&apos;"))
        .to eq(%(a & b <c> "d" 'e'))
    end

    it "decodes named typographic entities CGI.unescapeHTML leaves alone" do
      title = "Letter to the Editor: The creepiest &lsquo;sales demo&rsquo; of all time"
      expect(described_class.decode(title))
        .to eq("Letter to the Editor: The creepiest ‘sales demo’ of all time")
    end

    it "decodes dashes, ellipses and nbsp" do
      expect(described_class.decode("AI&nbsp;spending&mdash;up&hellip;")).to eq("AI spending—up…")
    end

    it "decodes decimal and hex numeric references" do
      expect(described_class.decode("&#8217;&#x2019;&#38;")).to eq("’’&")
    end

    it "leaves unknown named entities intact" do
      expect(described_class.decode("&notarealentity; &amp;")).to eq("&notarealentity; &")
    end

    it "leaves malformed and out-of-range numeric references intact" do
      expect(described_class.decode("&#0; &#1114112; &#xD800;")).to eq("&#0; &#1114112; &#xD800;")
    end

    it "decodes only one level, so double-encoded markup stays inert" do
      expect(described_class.decode("&amp;lt;script&amp;gt;")).to eq("&lt;script&gt;")
    end

    it "passes through text with no entities" do
      expect(described_class.decode("plain text")).to eq("plain text")
    end

    it "handles nil" do
      expect(described_class.decode(nil)).to eq("")
    end
  end
end
