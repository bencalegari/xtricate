# Xtricate

the twitter company makes me not happy-- thats okay, [ill still keep drinking that garbage](https://x.com/realDonaldTrump/status/258262904091058176?lang=en)

## How it works

```
subscribers ──► fetch once (twitterapi.io / Bluesky) ──► per-subscriber slice
                                                                │
                                          cluster by article ──► Claude grouping
                                                                │
                              email (Gmail SMTP) ◄── ERB/HTML render (their timezone)
```

One run serves several subscribers. Handles are fetched **once** across everybody — a follow shared
by three people is billed once — then each subscriber gets their own slice, their own Claude pass,
and their own email. Stateless: each run looks back `lookback_days` using post timestamps, so
there's no database.

## Setup

### 1. Install

```bash
bundle install
cp .env.example .env   # API keys only
```

### 2. Fill in `.env`

`.env` holds shared credentials, nothing personal.

| Var | Where | Notes |
| --- | --- | --- |
| `TWITTERAPI_IO_KEY` | twitterapi.io dashboard → API Key | Add a few $ of balance. Not your Twitter login. |
| `ANTHROPIC_API_KEY` | console.anthropic.com → API Keys | Separate from any Claude subscription; pay-as-you-go. Starts with `sk-ant-`. |
| `GMAIL_ADDRESS` / `GMAIL_APP_PASSWORD` | myaccount.google.com → Security → App passwords | Requires 2-Step Verification on. Only needed for live email, not `--dry-run`. |

> If your work Google Workspace blocks app passwords, use a personal Gmail, or
> stick with `--dry-run` until you sort out delivery.

### 3. Your own settings: `subscribers.local.yml`

Gitignored, so it stays out of this public repo. Copy `subscribers.example.yml` and edit:

```yaml
- email: you@example.com
  accounts:
    - paulg
    - karpathy
  bluesky_accounts: []
  timezone: America/Los_Angeles
  lookback_days: 7
```

`accounts` takes a YAML list or a comma/newline string; a leading `@` is fine. `timezone` and
`lookback_days` are optional and fall back to `config.yml`.

## Run it locally

```bash
# 1. Sanity-check fetching against a few accounts (needs only TWITTERAPI_IO_KEY)
bin/digest --fetch-only --limit 3

# 2. Generate the digest to a local file and open it — review/tune before any email
#    (needs TWITTERAPI_IO_KEY + ANTHROPIC_API_KEY)
bin/digest --dry-run && open digest.html

# 3. The real thing: fetch, summarize, and email
bin/digest
```

Useful flags: `--subscribers FILE` for an alternate list, `--only subscriber-2` (or an email) to run
one person, `--out-dir DIR` for `--dry-run` with several subscribers, `--verbose` to print handles
and addresses (local only — CI logs are public).

## Subscribing someone else

Each subscriber keeps their own settings in their own gist, so you never hand-maintain their follow
list and they can change it whenever they like.

**They do this:**

1. Create a **secret gist** at <https://gist.github.com> with one file named `xtricate.yml`:

   ```yaml
   accounts:
     - paulg
     - karpathy
   bluesky_accounts: []
   timezone: America/New_York
   lookback_days: 7
   ```

2. Send you the gist URL.

**You do this:** add a line to the `XTRICATE_SUBSCRIBERS` secret (Repo → **Settings → Secrets and
variables → Actions**), one entry per line:

```
you@example.com|https://gist.github.com/you/6f1c0b9e2d3a4b5c6d7e8f90
friend@example.com|https://gist.github.com/friend/9ab3c2d1e0f9a8b7c6d5e4f3
```

The email lives on your side, never in the gist — so a subscriber editing their own gist can't
point the digest at somebody else's inbox. Removing their line unsubscribes them.

> **A secret gist is unlisted, not private.** GitHub's own docs: "secret gists are not private — if
> you send the URL to a friend, they can see it." The URL is a 32-hex string nobody can guess or
> search for, and the roster of URLs lives in an Actions secret, so subscribers can't see each
> other's. But it is not encryption. Don't put anything in there you'd mind a URL leak exposing.

Runs log by position (`[subscriber-2] sent — 41 post(s), 5 theme(s).`) and never print handles,
emails, or gist URLs, because Actions logs on a public repo are world-readable.

## Tests

```bash
bundle exec rspec
```

Specs live in `spec/` and run offline (no API keys or network). They cover subscriber config
parsing, gist loading, per-subscriber slicing and timezones, and the renderer's unit-grouping logic.

## Schedule it (GitHub Actions)

1. Push this repo to GitHub.
2. Repo → **Settings → Secrets and variables → Actions** → add:
   `XTRICATE_SUBSCRIBERS`, `TWITTERAPI_IO_KEY`, `ANTHROPIC_API_KEY`, `GMAIL_ADDRESS`,
   `GMAIL_APP_PASSWORD`.
3. Only `config.yml` is committed; everything personal lives in secrets and gists.
4. The workflow in `.github/workflows/weekly-digest.yml` runs every Monday. Use the
   **Actions** tab → *Weekly Twitter Digest* → **Run workflow** to trigger a test run.

Adjust the day/time by editing the `cron:` line in that workflow. A subscriber whose gist fails to
load is skipped and the run still delivers to everyone else, then exits nonzero so you see the red X.

## Configuration (`config.yml`)

Global knobs, shared by every subscriber.

| Key | Default | Meaning |
| --- | --- | --- |
| `lookback_days` | 7 | Default window; a subscriber may override |
| `model` | `claude-sonnet-4-6` | Claude model used to write the digest |
| `max_tweets_per_account` | 100 | Per-account fetch cap |
| `sender_name` | Xtricate Digest | Display name on the From line |
| `timezone` | `America/Los_Angeles` | Default IANA TZ; a subscriber may override |
| `preferred_long_form_outlets` | (list of left-wing outlets) | Domains to prioritize for long-form picks |

## Cost

twitterapi.io ~$1–2/mo · Anthropic a few cents per subscriber per run · GitHub Actions + Gmail free.
