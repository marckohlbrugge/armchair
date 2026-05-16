# Armchair

A real-time AI sidebar for live podcasts by [Marc Köhlbrugge](https://x.com/marckohlbrugge).

## What is Armchair?

Armchair listens to a live YouTube stream, transcribes it in real time, and cuts in with commentary from a panel of four AI armchair critics — inspired by the staff of *The Howard Stern Show*:

- 📋 **Gary** — the stern producer who keeps facts straight
- 🎛️ **Fred** — the encyclopedic context guy with the lateral connection
- 🤣 **Jackie** — the comedy writer with the one-liner
- 🧌 **Troll** — the cynic who won't let hype slide

Each completed speaker turn is routed through a single LLM gate that casts exactly one persona (or stays silent). The result is a live "sidebar" next to the transcript: commentary arrives seconds after the point it reacts to, visually tied to the exact sentence that triggered it.

## Why this exists

Inspired by [a tweet from @twistartups](https://x.com/twistartups/status/2044437861668171974) describing exactly this idea — a live AI sidebar with four personas watching a pod in real time. It sounded like a fun thing to build, so I built it.

## Stack

- **Rails 8** — Propshaft, Importmap, Turbo Streams, Stimulus, Tailwind v4
- **SQLite** — single-file DB for the whole app (primary, Solid Queue, Solid Cable)
- **Solid Queue** — background jobs, running inside Puma via plugin
- **Solid Cable** — Turbo broadcast channel backed by the DB
- **Deepgram Nova-3** — real-time speech-to-text over WebSocket
- **RubyLLM** — thin Ruby abstraction over xAI's Grok (`grok-4-1-fast-non-reasoning` for gating, `grok-4.20-0309-non-reasoning` for commentary, `grok-4.20-0309-reasoning` + built-in `web_search` for fact-checking via xAI's Responses API)
- **ffmpeg** — pipe live audio into Deepgram's WebSocket
- **Kamal** — container-based deploy

## Running locally

Requires Ruby 3.4, `ffmpeg`, a Deepgram API key (STT), and an xAI API key (chat + web search).

```bash
bin/setup

EDITOR="code --wait" bin/rails credentials:edit --environment development
# add:
#   deepgram_api_key: ...
#   xai_api_key: ...

bin/dev
```

Alternatively, self-hosters can set `DEEPGRAM_API_KEY` and `XAI_API_KEY` as environment variables instead of using Rails credentials.

Visit `http://localhost:3000`, head to `/manage/sessions/new`, paste a YouTube URL (live or recorded), and watch the personas chime in.

### STT provider + shadow bakeoff

Microphone ingest supports both providers via `STT_PROVIDER`:

- `deepgram` (default)
- `openai`

You can also run a side-by-side comparison with `STT_SHADOW`:

- When `STT_PROVIDER=deepgram`, set `STT_SHADOW=openai`
- When `STT_PROVIDER=openai`, set `STT_SHADOW=deepgram`

Example (URL ingest, Deepgram primary + OpenAI shadow):

```bash
OPENAI_API_KEY=... STT_SHADOW=openai bin/rails runner script/ingest.rb <session-id>
```

This writes a JSONL log to `log/stt_shadow_<session-id>.jsonl` with timing and transcript events from both providers.

After ingest finishes:

```bash
bin/rails runner script/stt_bakeoff_report.rb <session-id>
```

Optional env vars:

- `STT_PROVIDER` (microphone ingest primary; default: `deepgram`)
- `STT_SHADOW` (`openai` or `deepgram`, must differ from `STT_PROVIDER`)
- `STT_OPENAI_REALTIME_MODEL` (default: `gpt-realtime-whisper`)
- `STT_OPENAI_LANGUAGE` (default: `en`)

## Deploying

The included `Dockerfile` bundles `yt-dlp` and `ffmpeg`, so Kamal deploys work out of the box. Set production credentials before deploying:

```yaml
# config/credentials/production.yml.enc
deepgram_api_key: ...
xai_api_key: ...
manage:
  username: admin
  password: <strong password>
```

`manage:` credentials gate the `/manage/*` routes behind HTTP basic auth in production. The public home page and session replay URLs stay open.

## How it works

1. **Ingest** — `ffmpeg` decodes stream audio to 16kHz mono PCM and pipes it into Deepgram's WebSocket.
2. **Transcript events** — raw Deepgram payloads persist immediately (`TranscriptEvent`) for replay fidelity.
3. **Turn building** — `is_final` segments accumulate until a natural sentence boundary, closing into a `Turn` of ≥8 words (80 max).
4. **Gate** — one fast Grok call per turn picks a persona: `wait | none | fact_checker | context | comedy | troll` with reasoning.
5. **Reaction** — the chosen persona runs a Grok call with context from recent turns and its own recent remarks; FactChecker additionally goes through xAI's Responses API with the built-in `web_search` tool. Any persona can abstain with `PASS`.
6. **Cooldown** — a persona that just spoke is skipped for 3 turns even if re-selected.
7. **Live UI** — Turbo Streams push every turn and comment into a single CSS grid; sticky positioning keeps the latest comment pinned.

Ingest runs as a detached subprocess per session so the web stays responsive. Start/Stop buttons spawn and SIGTERM it.

## License

Armchair is released under the [O'Saasy License](LICENSE.md).
