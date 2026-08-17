require "json"
require "tmpdir"

RSpec.describe Xtricate::SubscriberSource do
  let(:defaults) do
    OpenStruct.new(timezone: "America/Denver", lookback_days: 5, subscribers_raw: nil)
  end

  def gist_body(**config)
    JSON.generate("files" => { "xtricate.yml" => { "content" => config.transform_keys(&:to_s).to_yaml } })
  end

  def stubbed_conn(&block)
    stubs = Faraday::Adapter::Test::Stubs.new(&block)
    [Faraday.new { |f| f.adapter(:test, stubs) }, stubs]
  end

  def resolve(config: defaults, root: Dir.pwd, path: nil, conn: nil)
    described_class.resolve(config: config, root: root, path: path, conn: conn)
  end

  describe ".parse_entries" do
    it "reads email|url pairs separated by newlines" do
      pairs, problems = described_class.parse_entries(<<~RAW)
        a@example.com|https://gist.github.com/a/1111aaaa
        b@example.com|https://gist.github.com/b/2222bbbb
      RAW

      expect(pairs).to eq([["a@example.com", "https://gist.github.com/a/1111aaaa"],
                           ["b@example.com", "https://gist.github.com/b/2222bbbb"]])
      expect(problems).to be_empty
    end

    it "reads them separated by commas too" do
      pairs, = described_class.parse_entries(
        "a@example.com|https://gist.github.com/a/1111aaaa,b@example.com|https://gist.github.com/b/2222bbbb"
      )

      expect(pairs.size).to eq(2)
    end

    it "skips blank lines and # comments" do
      pairs, problems = described_class.parse_entries(<<~RAW)
        # ben, paused for now
        a@example.com|https://gist.github.com/a/1111aaaa

      RAW

      expect(pairs.size).to eq(1)
      expect(problems).to be_empty
    end

    it "reports a malformed entry by position and keeps the valid ones" do
      pairs, problems = described_class.parse_entries(<<~RAW)
        a@example.com|https://gist.github.com/a/1111aaaa
        https://gist.github.com/b/2222bbbb
        c@example.com|https://gist.github.com/c/3333cccc
      RAW

      expect(pairs.map(&:first)).to eq(["a@example.com", "c@example.com"])
      expect(problems).to eq([2])
    end
  end

  describe "resolving from a gist" do
    it "builds a subscriber from the gist's xtricate.yml, with the email from the secret" do
      conn, stubs = stubbed_conn do |s|
        s.get("https://api.github.com/gists/1111aaaa") do
          [200, {}, gist_body(accounts: %w[paulg], email: "attacker@example.com")]
        end
      end
      defaults.subscribers_raw = "reader@example.com|https://gist.github.com/a/1111aaaa"

      result = resolve(conn: conn, root: Dir.mktmpdir)

      expect(result.origin).to eq(:gists)
      expect(result.subscribers.map(&:email)).to eq(["reader@example.com"])
      expect(result.subscribers.first.accounts).to eq(%w[paulg])
      expect(result.subscribers.first.id).to eq("subscriber-1")
      stubs.verify_stubbed_calls
    end

    it "refuses a non-gist host without issuing any request" do
      conn, = stubbed_conn { |_s| nil }
      defaults.subscribers_raw = "reader@example.com|https://evil.example.com/config.yml"

      expect { resolve(conn: conn, root: Dir.mktmpdir) }
        .to raise_error(Xtricate::ConfigError, /no subscriber gists could be loaded/)
    end

    it "refuses a plain-http gist URL" do
      conn, = stubbed_conn { |_s| nil }
      defaults.subscribers_raw = "reader@example.com|http://gist.github.com/a/1111aaaa"

      expect { resolve(conn: conn, root: Dir.mktmpdir) }
        .to raise_error(Xtricate::ConfigError)
    end

    it "skips a gist that 404s and keeps the other subscribers" do
      conn, = stubbed_conn do |s|
        s.get("https://api.github.com/gists/1111aaaa") { [404, {}, "not found"] }
        s.get("https://api.github.com/gists/2222bbbb") { [200, {}, gist_body(accounts: %w[karpathy])] }
      end
      defaults.subscribers_raw = <<~RAW
        gone@example.com|https://gist.github.com/a/1111aaaa
        here@example.com|https://gist.github.com/b/2222bbbb
      RAW

      result = resolve(conn: conn, root: Dir.mktmpdir)

      expect(result.subscribers.map(&:email)).to eq(["here@example.com"])
      expect(result.failures.map(&:first)).to eq(["subscriber-1"])
    end

    it "fetches a gist.githubusercontent.com raw URL directly as YAML" do
      raw = "https://gist.githubusercontent.com/a/1111aaaa/raw/xtricate.yml"
      conn, = stubbed_conn do |s|
        s.get(raw) { [200, {}, { "accounts" => %w[simonw] }.to_yaml] }
      end
      defaults.subscribers_raw = "reader@example.com|#{raw}"

      result = resolve(conn: conn, root: Dir.mktmpdir)

      expect(result.subscribers.first.accounts).to eq(%w[simonw])
    end

    it "says why every gist failed when none of them load" do
      conn, = stubbed_conn do |s|
        s.get("https://api.github.com/gists/1111aaaa") { [401, {}, "bad credentials"] }
      end
      defaults.subscribers_raw = "reader@example.com|https://gist.github.com/a/1111aaaa"

      expect { resolve(conn: conn, root: Dir.mktmpdir) }
        .to raise_error(Xtricate::ConfigError, /subscriber-1: gist request failed \(HTTP 401\)/)
    end

    it "never puts a gist URL or an email in its log output" do
      conn, = stubbed_conn do |s|
        s.get("https://api.github.com/gists/1111aaaa") { [200, {}, gist_body(accounts: %w[paulg])] }
      end
      defaults.subscribers_raw = "reader@example.com|https://gist.github.com/a/1111aaaa"
      out = StringIO.new

      described_class.resolve(config: defaults, root: Dir.mktmpdir, conn: conn, logger: out)

      expect(out.string).not_to include("1111aaaa")
      expect(out.string).not_to include("reader@example.com")
    end
  end

  describe "authenticating gist requests" do
    def with_env(**vars)
      original = ENV.to_hash
      %w[GITHUB_TOKEN XTRICATE_GIST_TOKEN].each { |k| ENV.delete(k) }
      vars.each { |k, v| ENV[k.to_s] = v }
      yield
    ensure
      ENV.replace(original)
    end

    def auth_header(**vars)
      with_env(**vars) do
        described_class.new(config: defaults).send(:conn).headers["Authorization"]
      end
    end

    it "omits the Authorization header for the Actions installation token, which cannot read gists" do
      expect(auth_header(GITHUB_TOKEN: "ghs_actionsinstallationtoken")).to be_nil
    end

    it "sends a personal access token from GITHUB_TOKEN" do
      expect(auth_header(GITHUB_TOKEN: "ghp_personaltoken")).to eq("Bearer ghp_personaltoken")
    end

    it "prefers XTRICATE_GIST_TOKEN over GITHUB_TOKEN" do
      header = auth_header(GITHUB_TOKEN: "ghs_actionsinstallationtoken",
                           XTRICATE_GIST_TOKEN: "ghp_personaltoken")

      expect(header).to eq("Bearer ghp_personaltoken")
    end

    it "omits the Authorization header when no token is set" do
      expect(auth_header).to be_nil
    end
  end

  describe "source precedence" do
    def write(dir, name, entries)
      File.join(dir, name).tap { |p| File.write(p, entries.to_yaml) }
    end

    it "prefers an explicit path over subscribers.local.yml and the secret" do
      Dir.mktmpdir do |dir|
        write(dir, Xtricate::SubscriberSource::LOCAL_FILE,
              [{ "email" => "local@example.com", "accounts" => %w[paulg] }])
        explicit = write(dir, "other.yml",
                         [{ "email" => "explicit@example.com", "accounts" => %w[karpathy] }])
        defaults.subscribers_raw = "secret@example.com|https://gist.github.com/a/1111aaaa"

        result = resolve(root: dir, path: explicit)

        expect(result.origin).to eq(:file)
        expect(result.subscribers.map(&:email)).to eq(["explicit@example.com"])
      end
    end

    it "prefers subscribers.local.yml over the secret" do
      Dir.mktmpdir do |dir|
        write(dir, Xtricate::SubscriberSource::LOCAL_FILE,
              [{ "email" => "local@example.com", "accounts" => %w[paulg] }])
        defaults.subscribers_raw = "secret@example.com|https://gist.github.com/a/1111aaaa"

        result = resolve(root: dir)

        expect(result.origin).to eq(:local)
        expect(result.subscribers.map(&:email)).to eq(["local@example.com"])
      end
    end

    it "labels local subscribers positionally" do
      Dir.mktmpdir do |dir|
        write(dir, Xtricate::SubscriberSource::LOCAL_FILE, [
                { "email" => "a@example.com", "accounts" => %w[paulg] },
                { "email" => "b@example.com", "accounts" => %w[karpathy] }
              ])

        expect(resolve(root: dir).subscribers.map(&:id)).to eq(%w[subscriber-1 subscriber-2])
      end
    end

    it "accepts a single mapping instead of a list" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, Xtricate::SubscriberSource::LOCAL_FILE),
                   { "email" => "solo@example.com", "accounts" => %w[paulg] }.to_yaml)

        expect(resolve(root: dir).subscribers.size).to eq(1)
      end
    end

    it "raises when there is no local file and no secret" do
      expect { resolve(root: Dir.mktmpdir) }
        .to raise_error(Xtricate::ConfigError, /No subscribers/)
    end

    it "raises when a local file defines nobody usable" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, Xtricate::SubscriberSource::LOCAL_FILE),
                   [{ "email" => "a@example.com" }].to_yaml)

        expect { resolve(root: dir) }.to raise_error(Xtricate::ConfigError, /no usable subscribers/)
      end
    end
  end
end
