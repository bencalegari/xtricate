RSpec.describe Xtricate::ActivitySlice do
  def subscriber(id:, accounts:, lookback_days: 7, bluesky: [])
    Xtricate::Subscriber.new(
      id: id, email: "#{id}@example.com", accounts: accounts,
      bluesky_accounts: bluesky, timezone: "America/Los_Angeles",
      lookback_days: lookback_days
    )
  end

  def post(id:, author:, days_ago:, conversation_id: nil)
    Xtricate::Tweet.new(
      id: id, author: author, kind: :original, text: "post #{id}", urls: [],
      created_at: Time.now - (days_ago * 86_400), source: :x,
      conversation_id: conversation_id
    )
  end

  def activity(handle, tweets, source: :twitter)
    Xtricate::AccountActivity.new(handle: handle, tweets: tweets, source: source)
  end

  it "gives a subscriber only the accounts they follow" do
    activities = [activity("paulg", [post(id: "1", author: "paulg", days_ago: 1)]),
                  activity("karpathy", [post(id: "2", author: "karpathy", days_ago: 1)])]

    slice = described_class.for(subscriber(id: "s1", accounts: %w[paulg]), activities)

    expect(slice.map(&:handle)).to eq(%w[paulg])
  end

  it "matches followed handles case-insensitively" do
    activities = [activity("PaulG", [post(id: "1", author: "PaulG", days_ago: 1)])]

    slice = described_class.for(subscriber(id: "s1", accounts: %w[paulg]), activities)

    expect(slice.size).to eq(1)
  end

  it "does not hand a twitter account to a subscriber who only listed it on bluesky" do
    activities = [activity("paulg", [post(id: "1", author: "paulg", days_ago: 1)])]

    slice = described_class.for(subscriber(id: "s1", accounts: [], bluesky: %w[paulg]), activities)

    expect(slice).to be_empty
  end

  it "drops posts older than the subscriber's own lookback window" do
    activities = [activity("paulg", [post(id: "new", author: "paulg", days_ago: 1),
                                     post(id: "old", author: "paulg", days_ago: 5)])]

    short = described_class.for(subscriber(id: "s1", accounts: %w[paulg], lookback_days: 3), activities)
    long  = described_class.for(subscriber(id: "s2", accounts: %w[paulg], lookback_days: 7), activities)

    expect(short.first.tweets.map(&:id)).to eq(%w[new])
    expect(long.first.tweets.map(&:id)).to eq(%w[new old])
  end

  it "honours an explicit window over the subscriber's lookback_days" do
    activities = [activity("paulg", [post(id: "recent", author: "paulg", days_ago: 1),
                                     post(id: "older", author: "paulg", days_ago: 20)])]
    window = Xtricate::Window.new(start_at: Time.now - (25 * 86_400),
                                  end_at: Time.now - (10 * 86_400))

    slice = described_class.for(subscriber(id: "s1", accounts: %w[paulg], lookback_days: 7),
                                activities, window: window)

    expect(slice.first.tweets.map(&:id)).to eq(%w[older])
  end

  it "keeps posts with no timestamp rather than guessing they are stale" do
    undated = Xtricate::Tweet.new(id: "u", author: "paulg", kind: :original, text: "x",
                                  urls: [], created_at: nil, source: :x)
    activities = [activity("paulg", [undated])]

    slice = described_class.for(subscriber(id: "s1", accounts: %w[paulg], lookback_days: 1), activities)

    expect(slice.first.tweets.map(&:id)).to eq(%w[u])
  end

  it "leaves the shared fetch untouched when it assembles threads" do
    shared = [post(id: "a", author: "paulg", days_ago: 2, conversation_id: "c1"),
              post(id: "b", author: "paulg", days_ago: 1, conversation_id: "c1")]
    activities = [activity("paulg", shared)]

    described_class.for(subscriber(id: "s1", accounts: %w[paulg]), activities)

    expect(shared.map(&:thread_root_id)).to eq([nil, nil])
    expect(shared.map(&:thread_continuations)).to eq([nil, nil])
  end

  it "assembles threads independently for each subscriber" do
    activities = [activity("paulg", [post(id: "a", author: "paulg", days_ago: 2, conversation_id: "c1"),
                                     post(id: "b", author: "paulg", days_ago: 1, conversation_id: "c1")])]

    first = described_class.for(subscriber(id: "s1", accounts: %w[paulg]), activities)
    second = described_class.for(subscriber(id: "s2", accounts: %w[paulg]), activities)

    head = first.first.tweets.find(&:thread_head?)
    expect(head.id).to eq("a")
    expect(head.thread_continuations.map(&:id)).to eq(%w[b])
    expect(head.thread_continuations.first).not_to be(second.first.tweets.last)
  end
end
