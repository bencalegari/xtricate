RSpec.describe Xtricate::WindowParser do
  around do |example|
    old = ENV["TZ"]
    ENV["TZ"] = "America/Los_Angeles"
    example.run
    ENV["TZ"] = old
  end

  it "returns nil when neither bound is given, leaving lookback_days in charge" do
    expect(described_class.parse).to be_nil
  end

  it "ignores blank bounds, which is what an untouched workflow_dispatch input sends" do
    expect(described_class.parse(since: "", until_at: "  ")).to be_nil
  end

  it "reads a bare --since date as local midnight that day" do
    window = described_class.parse(since: "2026-08-01")

    expect(window.start_at).to eq(Time.new(2026, 8, 1, 0, 0, 0))
    expect(window.end_at).to be_nil
  end

  it "reads a bare --until date as the end of that day, so the day itself is included" do
    window = described_class.parse(until_at: "2026-08-07")

    expect(window.start_at).to be_nil
    expect(window.end_at).to eq(Time.new(2026, 8, 8, 0, 0, 0))
  end

  it "keeps an explicit timestamp exactly as written" do
    window = described_class.parse(since: "2026-08-01T09:30:00", until_at: "2026-08-01T17:00:00")

    expect(window.start_at).to eq(Time.new(2026, 8, 1, 9, 30, 0))
    expect(window.end_at).to eq(Time.new(2026, 8, 1, 17, 0, 0))
  end

  it "rejects a range that ends before it starts" do
    expect { described_class.parse(since: "2026-08-07", until_at: "2026-08-01") }
      .to raise_error(Xtricate::WindowError, /must be before/)
  end

  it "rejects a range whose bounds land on the same instant" do
    expect { described_class.parse(since: "2026-08-01T09:00:00", until_at: "2026-08-01T09:00:00") }
      .to raise_error(Xtricate::WindowError, /must be before/)
  end

  it "names the offending flag when a bound is unparseable" do
    expect { described_class.parse(until_at: "last tuesday") }
      .to raise_error(Xtricate::WindowError, /--until is not a date/)
  end
end

RSpec.describe Xtricate::Window do
  subject(:window) do
    described_class.new(start_at: Time.new(2026, 8, 1), end_at: Time.new(2026, 8, 8))
  end

  it "counts the days it spans" do
    expect(window.days).to eq(7)
  end

  it "covers a post inside the range" do
    expect(window.covers?(Time.new(2026, 8, 4))).to be(true)
  end

  it "excludes a post before the start" do
    expect(window.covers?(Time.new(2026, 7, 31, 23, 59))).to be(false)
  end

  it "excludes a post at or after the end, keeping the range half-open" do
    expect(window.covers?(Time.new(2026, 8, 8))).to be(false)
  end

  it "covers a post whose timestamp could not be parsed rather than dropping it" do
    expect(window.covers?(nil)).to be(true)
  end

  it "labels the period for the digest header" do
    expect(window.label).to eq("Aug 1 – Aug 8, 2026")
  end
end
