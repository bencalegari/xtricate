source "https://rubygems.org"

ruby ">= 3.2"

gem "faraday", "~> 2.14"   # HTTP client for twitterapi.io
gem "anthropic", "~> 1.0"  # official Anthropic SDK for summarization
gem "mail", "~> 2.9"       # Gmail SMTP delivery
gem "dotenv", "~> 3.0"     # load .env for local/dry runs
gem "base64"               # runtime dep of anthropic; no longer default on Ruby 3.4+

group :development do
  gem "rspec", "~> 3.13"
  gem "ostruct" # used by the smoke test; not default on Ruby 3.5+
end
