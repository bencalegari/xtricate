require "mail"

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

    def deliver(to:, subject:, html:)
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
