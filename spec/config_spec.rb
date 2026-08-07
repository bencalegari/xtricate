RSpec.describe Xtricate::Config do
  def config(**env)
    original = ENV.to_hash
    %w[TWITTERAPI_IO_KEY ANTHROPIC_API_KEY GMAIL_ADDRESS GMAIL_APP_PASSWORD
       XTRICATE_SUBSCRIBERS].each { |k| ENV.delete(k) }
    env.each { |k, v| ENV[k.to_s] = v }
    described_class.new("timezone" => "America/Denver", "lookback_days" => 5)
  ensure
    ENV.replace(original)
  end

  let(:all_keys) do
    { TWITTERAPI_IO_KEY: "t", ANTHROPIC_API_KEY: "a", GMAIL_ADDRESS: "g", GMAIL_APP_PASSWORD: "p" }
  end

  describe "defaults" do
    it "leaves replies off, so a new subscriber is not billed for them" do
      expect(described_class.new({}).include_replies).to be(false)
    end

    it "paces requests under the twitterapi.io Starter plan's 5/s limit" do
      expect(described_class.new({}).fetch_qps).to be < 5
    end

    it "caps the sections and payload that would otherwise grow with the follow list" do
      config = described_class.new({})

      expect(config.max_solo_picks).to eq(25)
      expect(config.max_payload_tweets).to eq(150)
      expect(config.payload_tweets_per_account).to eq(3)
      expect(config.max_discoveries).to eq(5)
    end

    it "takes each knob from config.yml when it is set" do
      config = described_class.new(
        "include_replies" => true, "fetch_qps" => 9, "max_solo_picks" => 10,
        "max_payload_tweets" => 40, "payload_tweets_per_account" => 1,
        "max_discoveries" => 2
      )

      expect(config.include_replies).to be(true)
      expect(config.fetch_qps).to eq(9)
      expect(config.max_solo_picks).to eq(10)
      expect(config.max_payload_tweets).to eq(40)
      expect(config.payload_tweets_per_account).to eq(1)
      expect(config.max_discoveries).to eq(2)
    end

    it "reads include_replies: false as set rather than missing" do
      expect(described_class.new("include_replies" => false).include_replies).to be(false)
    end
  end

  it "does not care whether anyone is subscribed" do
    expect { config(**all_keys).validate!(mode: :full) }.not_to raise_error
  end

  it "skips the twitterapi key when nobody follows a Twitter account" do
    expect { config(ANTHROPIC_API_KEY: "a").validate!(mode: :dry_run, needs_twitter: false) }
      .not_to raise_error
  end

  it "demands the twitterapi key when someone does" do
    expect { config(ANTHROPIC_API_KEY: "a").validate!(mode: :dry_run) }
      .to raise_error(Xtricate::ConfigError, /TWITTERAPI_IO_KEY/)
  end

  it "demands the Anthropic key only once Claude is involved" do
    expect { config(TWITTERAPI_IO_KEY: "t").validate!(mode: :fetch_only) }.not_to raise_error
    expect { config(TWITTERAPI_IO_KEY: "t").validate!(mode: :dry_run) }
      .to raise_error(Xtricate::ConfigError, /ANTHROPIC_API_KEY/)
  end

  it "demands the Gmail credentials only for a live send" do
    keys = { TWITTERAPI_IO_KEY: "t", ANTHROPIC_API_KEY: "a" }

    expect { config(**keys).validate!(mode: :dry_run) }.not_to raise_error
    expect { config(**keys).validate!(mode: :full) }
      .to raise_error(Xtricate::ConfigError, /GMAIL_ADDRESS.*GMAIL_APP_PASSWORD/m)
  end

  it "reads the subscriber roster from the environment" do
    expect(config(XTRICATE_SUBSCRIBERS: "a@example.com|https://gist.github.com/a/1111aaaa").subscribers_raw)
      .to eq("a@example.com|https://gist.github.com/a/1111aaaa")
  end

  describe ".parse_accounts" do
    it "reads a comma- or newline-separated string" do
      expect(described_class.parse_accounts("paulg, karpathy\nsimonw"))
        .to eq(%w[paulg karpathy simonw])
    end

    it "reads an array, so a gist can use YAML list syntax" do
      expect(described_class.parse_accounts(%w[@paulg karpathy])).to eq(%w[paulg karpathy])
    end

    it "is empty for nil" do
      expect(described_class.parse_accounts(nil)).to eq([])
    end
  end
end
