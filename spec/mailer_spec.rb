require "xtricate/mailer"

RSpec.describe Xtricate::Mailer do
  subject(:mailer) do
    described_class.new(gmail_address: "me@gmail.com", gmail_app_password: "pw")
  end

  let(:sent) { [] }
  let(:fail_on) { [] }

  before do
    allow_any_instance_of(Mail::Message).to receive(:delivery_method)
    allow_any_instance_of(Mail::Message).to receive(:deliver!) do |message|
      raise Net::SMTPServerBusy, "rejected" if fail_on.include?(message.subject)

      sent << message
    end
  end

  def deliver(parts)
    mailer.deliver_parts(to: "you@example.com", subject: "Your Twitter digest", parts: parts)
  end

  it "sends a single email with an unnumbered subject when it all fits" do
    deliver(["<p>one</p>"])

    expect(sent.map(&:subject)).to eq(["Your Twitter digest"])
  end

  it "numbers the subject once there is more than one part" do
    deliver(["<p>one</p>", "<p>two</p>"])

    expect(sent.map(&:subject)).to eq(["Your Twitter digest (1/2)", "Your Twitter digest (2/2)"])
  end

  it "points later parts at the first part so Gmail threads them" do
    deliver(["<p>one</p>", "<p>two</p>", "<p>three</p>"])

    root = sent.first.message_id
    expect(root).not_to be_nil
    expect(sent.drop(1).map(&:in_reply_to)).to all(eq(root))
    expect(sent.drop(1).map { |m| Array(m.references).first }).to all(eq(root))
  end

  it "leaves the first part unthreaded so it opens the conversation" do
    deliver(["<p>one</p>", "<p>two</p>"])

    expect(sent.first.in_reply_to).to be_nil
  end

  it "gives every part its own message id" do
    deliver(["<p>one</p>", "<p>two</p>"])

    expect(sent.map(&:message_id).uniq.size).to eq(2)
  end

  it "reports how many parts went out" do
    count, failures = deliver(["<p>one</p>", "<p>two</p>"])

    expect(count).to eq(2)
    expect(failures).to be_empty
  end

  it "keeps sending the rest when one part is rejected" do
    fail_on << "Your Twitter digest (2/3)"

    count, failures = deliver(["<p>one</p>", "<p>two</p>", "<p>three</p>"])

    expect(count).to eq(2)
    expect(sent.map(&:subject)).to eq(["Your Twitter digest (1/3)", "Your Twitter digest (3/3)"])
    expect(failures.first).to include("part 2/3")
  end

  it "still threads the survivors when the first part is the one that fails" do
    fail_on << "Your Twitter digest (1/2)"

    count, failures = deliver(["<p>one</p>", "<p>two</p>"])

    expect(count).to eq(1)
    expect(failures.first).to include("part 1/2")
    expect(sent.first.in_reply_to).to be_nil
  end

  it "carries the html through as the message body" do
    deliver(["<p>hello mr president</p>"])

    expect(sent.first.html_part.body.decoded).to include("hello mr president")
  end
end
