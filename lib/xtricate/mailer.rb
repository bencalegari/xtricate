require "mail"
require "securerandom"

module Xtricate
  # Sends the digest as an HTML email from a Gmail account over SMTP using an
  # app password. (Gmail API OAuth is a future fallback if app passwords are
  # disabled on the account's Workspace.)
  class Mailer
    def initialize(gmail_address:, gmail_app_password:, sender_name: "Xtricate Digest")
      @gmail_address = gmail_address
      @gmail_app_password = gmail_app_password
      @sender_name = sender_name
    end

    def deliver_parts(to:, subject:, parts:)
      thread_root = nil
      sent = 0
      failures = []

      parts.each_with_index do |html, index|
        numbered = parts.size > 1 ? "#{subject} (#{index + 1}/#{parts.size})" : subject
        id = "<xtricate-#{SecureRandom.hex(8)}-#{index + 1}@#{mail_domain}>"
        begin
          deliver(to: to, subject: numbered, html: html, message_id: id, in_reply_to: thread_root)
          thread_root ||= id
          sent += 1
        rescue StandardError => e
          failures << "part #{index + 1}/#{parts.size}: #{e.class}: #{e.message}"
        end
      end

      [sent, failures]
    end

    def mail_domain
      @gmail_address.to_s.split("@").last || "xtricate.local"
    end

    def deliver(to:, subject:, html:, message_id: nil, in_reply_to: nil)
      from_address = @gmail_address
      from_name = @sender_name
      pw = @gmail_app_password
      sender = @gmail_address

      mail = Mail.new do
        from    "#{from_name} <#{from_address}>"
        to      to
        subject subject

        html_part do
          content_type "text/html; charset=UTF-8"
          body html
        end
      end

      mail.message_id = message_id if message_id
      if in_reply_to
        mail.in_reply_to = in_reply_to
        mail.references = in_reply_to
      end

      mail.delivery_method(:smtp,
        address: "smtp.gmail.com",
        port: 587,
        user_name: sender,
        password: pw,
        authentication: :login,
        enable_starttls_auto: true)

      mail.deliver!
    end
  end
end
