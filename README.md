# Xtricate

A weekly email digest of what the X/Twitter accounts you follow have been up to —
topics, articles shared, the commentary around them, and notable quote-tweets —
so you can stop opening X every day.

It pulls tweets via [twitterapi.io](https://twitterapi.io) (no X login, ~$1–2/mo
for <50 accounts), has Claude write the digest, and emails it from your Gmail.
Runs weekly on GitHub Actions — nothing to keep running on your machine.

## How it works

```
accounts.txt ──► fetch (twitterapi.io) ──► cluster by article ──► Claude summary
                                                                        │
                                            email (Gmail SMTP) ◄── ERB/HTML render
```

Stateless: each run looks back `lookback_days` (default 7) using tweet timestamps,
so there's no database.

## Setup

### 1. Install

```bash
bundle install
cp .env.example .env   # then fill in keys + accounts (see below)
```

### 2. Fill in `.env`

Everything personal lives in `.env` (gitignored locally) or GitHub Actions secrets (CI) — nothing about who you follow is committed.

| Var | Where | Notes |
| --- | --- | --- |
| `XTRICATE_ACCOUNTS` | you | Comma- or newline-separated handles. Leading `@` optional. Keep it under ~50. |
| `XTRICATE_RECIPIENT` | you | The email address the digest gets delivered to. |
| `TWITTERAPI_IO_KEY` | twitterapi.io dashboard → API Key | Add a few $ of balance. Not your X login. |
| `ANTHROPIC_API_KEY` | console.anthropic.com → API Keys | Separate from any Claude subscription; pay-as-you-go. Starts with `sk-ant-`. |
| `GMAIL_ADDRESS` / `GMAIL_APP_PASSWORD` | myaccount.google.com → Security → App passwords | Requires 2-Step Verification on. Only needed for live email, not `--dry-run`. |

> If your work Google Workspace blocks app passwords, use a personal Gmail, or
> stick with `--dry-run` until you sort out delivery.

## Run it locally

```bash
# 1. Sanity-check fetching against a few accounts (needs only TWITTERAPI_IO_KEY)
bin/digest --fetch-only --limit 3

# 2. Generate the digest to a local file — review/tune before any email
#    (needs TWITTERAPI_IO_KEY + ANTHROPIC_API_KEY)
bin/digest --dry-run        # writes ./digest.html

# 3. The real thing: fetch, summarize, and email
bin/digest
```

## Schedule it (GitHub Actions)

1. Push this repo to GitHub.
2. Repo → **Settings → Secrets and variables → Actions** → add the six secrets:
   `XTRICATE_ACCOUNTS`, `XTRICATE_RECIPIENT`, `TWITTERAPI_IO_KEY`, `ANTHROPIC_API_KEY`, `GMAIL_ADDRESS`, `GMAIL_APP_PASSWORD`.
   (For `XTRICATE_ACCOUNTS`, paste the handles comma- or newline-separated.)
3. Only `config.yml` is committed; everything personal lives in secrets.
4. The workflow in `.github/workflows/weekly-digest.yml` runs every Monday. Use the
   **Actions** tab → *Weekly X Digest* → **Run workflow** to trigger a test run.

Adjust the day/time by editing the `cron:` line in that workflow.

## Configuration (`config.yml`)

| Key | Default | Meaning |
| --- | --- | --- |
| `lookback_days` | 7 | How far back each run looks |
| `model` | `claude-sonnet-4-6` | Claude model used to write the digest |
| `max_tweets_per_account` | 100 | Per-account fetch cap |
| `sender_name` | Xtricate Digest | Display name on the From line |
| `timezone` | `America/Los_Angeles` | IANA TZ used for tweet timestamps |
| `preferred_long_form_outlets` | (list of left-wing outlets) | Domains to prioritize for long-form picks |

## Cost

twitterapi.io ~$1–2/mo · Anthropic a few cents/run · GitHub Actions + Gmail free.
