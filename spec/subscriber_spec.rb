RSpec.describe Xtricate::SubscriberBuilder do
  let(:defaults) do
    OpenStruct.new(timezone: "America/Denver", lookback_days: 5, include_replies: false,
                   max_solo_picks: 25, max_payload_tweets: 150,
                   payload_tweets_per_account: 3, max_discoveries: 5)
  end

  def build(yml, email: "reader@example.com")
    described_class.build(yml, id: "subscriber-1", email: email, defaults: defaults)
  end

  it "reads accounts written as a YAML list" do
    sub = build({ "accounts" => %w[paulg karpathy] })

    expect(sub.accounts).to eq(%w[paulg karpathy])
  end

  it "reads accounts written as a comma-separated string, the same way" do
    sub = build({ "accounts" => "paulg, karpathy" })

    expect(sub.accounts).to eq(%w[paulg karpathy])
  end

  it "tolerates leading @, blanks, comments, and duplicates" do
    sub = build({ "accounts" => "@paulg\n\n# a note\nkarpathy\npaulg" })

    expect(sub.accounts).to eq(%w[paulg karpathy])
  end

  it "inherits timezone and lookback_days when the config omits them" do
    sub = build({ "accounts" => %w[paulg] })

    expect(sub.timezone).to eq("America/Denver")
    expect(sub.lookback_days).to eq(5)
  end

  it "prefers the subscriber's own timezone and lookback_days over the defaults" do
    sub = build({ "accounts" => %w[paulg], "timezone" => "America/New_York", "lookback_days" => 3 })

    expect(sub.timezone).to eq("America/New_York")
    expect(sub.lookback_days).to eq(3)
  end

  it "inherits the fetch and cap knobs when the config omits them" do
    sub = build({ "accounts" => %w[paulg] })

    expect(sub.include_replies).to be(false)
    expect(sub.max_solo_picks).to eq(25)
    expect(sub.max_payload_tweets).to eq(150)
    expect(sub.payload_tweets_per_account).to eq(3)
    expect(sub.max_discoveries).to eq(5)
  end

  it "prefers the subscriber's own caps over the defaults" do
    sub = build({ "accounts" => %w[paulg], "max_solo_picks" => 5, "max_payload_tweets" => 40,
                  "payload_tweets_per_account" => 1, "max_discoveries" => 2 })

    expect(sub.max_solo_picks).to eq(5)
    expect(sub.max_payload_tweets).to eq(40)
    expect(sub.payload_tweets_per_account).to eq(1)
    expect(sub.max_discoveries).to eq(2)
  end

  it "lets a subscriber opt in to replies the default leaves off" do
    sub = build({ "accounts" => %w[paulg], "include_replies" => true })

    expect(sub.include_replies).to be(true)
  end

  it "honours an explicit include_replies: false instead of reading it as absent" do
    defaults.include_replies = true

    sub = build({ "accounts" => %w[paulg], "include_replies" => false })

    expect(sub.include_replies).to be(false)
  end

  it "treats a zero cap as a real value rather than a missing one" do
    sub = build({ "accounts" => %w[paulg], "max_solo_picks" => 0 })

    expect(sub.max_solo_picks).to eq(0)
  end

  it "ignores an email written in the config when one is supplied alongside it" do
    sub = build({ "accounts" => %w[paulg], "email" => "attacker@example.com" },
                email: "reader@example.com")

    expect(sub.email).to eq("reader@example.com")
  end

  it "falls back to the config's email when none is supplied" do
    sub = build({ "accounts" => %w[paulg], "email" => "local@example.com" }, email: nil)

    expect(sub.email).to eq("local@example.com")
  end

  it "rejects a config with no accounts at all" do
    expect { build({ "timezone" => "America/New_York" }) }
      .to raise_error(Xtricate::SubscriberError, /no accounts/)
  end

  it "rejects a config that is not a mapping" do
    expect { build(%w[paulg karpathy]) }
      .to raise_error(Xtricate::SubscriberError, /not a YAML mapping/)
  end

  it "accepts a bluesky-only subscriber" do
    sub = build({ "bluesky_accounts" => %w[pfrazee.com] })

    expect(sub.accounts).to be_empty
    expect(sub.bluesky_accounts).to eq(%w[pfrazee.com])
  end

  describe "#follows?" do
    subject(:sub) do
      build({ "accounts" => %w[PaulG], "bluesky_accounts" => %w[pfrazee.com] })
    end

    it "matches its own handles case-insensitively, per source" do
      expect(sub.follows?("paulg", :twitter)).to be(true)
      expect(sub.follows?("paulg", :bluesky)).to be(false)
      expect(sub.follows?("pfrazee.com", :bluesky)).to be(true)
    end
  end

  describe "#since" do
    it "is lookback_days before now" do
      sub = build({ "accounts" => %w[paulg], "lookback_days" => 3 })

      expect(sub.since).to be_within(5).of(Time.now - (3 * 86_400))
    end
  end
end
