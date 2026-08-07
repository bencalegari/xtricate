require "xtricate/pool"

RSpec.describe Xtricate::Throttle do
  def clock_that_only_moves_when_someone_sleeps
    now = 0.0
    waits = []
    clock = -> { now }
    sleeper = lambda do |seconds|
      waits << seconds
      now += seconds
    end
    [clock, sleeper, waits, -> { now }]
  end

  it "lets the first caller through without waiting" do
    clock, sleeper, waits = clock_that_only_moves_when_someone_sleeps

    described_class.new(qps: 4, clock: clock, sleeper: sleeper).acquire

    expect(waits).to be_empty
  end

  it "spaces successive callers one interval apart" do
    clock, sleeper, waits = clock_that_only_moves_when_someone_sleeps
    throttle = described_class.new(qps: 4, clock: clock, sleeper: sleeper)

    4.times { throttle.acquire }

    expect(waits).to eq([0.25, 0.25, 0.25])
  end

  it "admits no more than qps acquisitions per second of clock time" do
    clock, sleeper, _waits, now = clock_that_only_moves_when_someone_sleeps
    throttle = described_class.new(qps: 4, clock: clock, sleeper: sleeper)

    5.times { throttle.acquire }

    expect(now.call).to be >= 1.0
  end

  it "does not make a caller wait for a slot that has already passed" do
    now = 0.0
    waits = []
    throttle = described_class.new(
      qps: 4,
      clock: -> { now },
      sleeper: ->(seconds) { waits << seconds }
    )

    throttle.acquire
    now += 10.0
    throttle.acquire

    expect(waits).to be_empty
  end

  it "rejects a non-positive rate rather than dividing by zero" do
    expect { described_class.new(qps: 0) }.to raise_error(ArgumentError, /positive/)
  end
end

RSpec.describe Xtricate::Pool do
  it "returns results in input order regardless of completion order" do
    result = described_class.map([0.03, 0.01, 0.02], threads: 3) do |delay|
      sleep(delay)
      delay
    end

    expect(result).to eq([0.03, 0.01, 0.02])
  end

  it "is a no-op for an empty list" do
    expect(described_class.map([], threads: 4) { raise "never called" }).to eq([])
  end

  it "runs work concurrently rather than one item at a time" do
    started = Queue.new
    described_class.map([1, 2, 3], threads: 3) do |item|
      started << item
      sleep(0.05) if started.size < 3
      item
    end

    expect(started.size).to eq(3)
  end

  it "never uses more threads than there are items" do
    threads = Queue.new

    described_class.map([1, 2], threads: 8) { threads << Thread.current.object_id }

    expect(threads.size).to eq(2)
  end

  it "lets every other item finish before surfacing a failure" do
    seen = Queue.new

    expect do
      described_class.map([1, 2, 3], threads: 1) do |item|
        raise "boom on #{item}" if item == 2

        seen << item
      end
    end.to raise_error(/boom on 2/)

    expect(seen.size).to eq(2)
  end

  it "reports the earliest failure when several items raise" do
    expect do
      described_class.map([1, 2, 3], threads: 1) { |item| raise "boom on #{item}" if item > 1 }
    end.to raise_error(/boom on 2/)
  end
end
