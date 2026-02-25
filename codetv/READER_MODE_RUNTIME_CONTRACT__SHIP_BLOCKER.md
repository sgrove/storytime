# Storytime Reader Mode Runtime Contract (Ship Blocker)

Status: Active  
Owner: Reader Track  
Date: 2026-02-25  
Spec anchors: FR-031..FR-044, FR-048, FR-054, AC-009..AC-012, AC-015

## 1. Purpose

This contract is the canonical source of truth for reader-mode runtime behavior.
If implementation and this contract diverge, this contract wins.

It defines:

- Runtime boot config for deployed reader static sites
- StoryPack consumption contract
- Per-word timing contracts (including ElevenLabs dialogue timestamps)
- Reader state-machine invariants
- Collaboration sync and host/guest behavior
- Required error behavior and non-negotiable UX guarantees

## 2. Runtime Config Contract

Reader runtime MUST load `/runtime-config.json` with:

```json
{
  "apiBase": "https://storytime-api-<id>.onrender.com",
  "storyId": "uuid-or-slug-id",
  "storySlug": "story-slug",
  "packUrl": "https://storytime-api-<id>.onrender.com/api/stories/<id>/pack",
  "instantAppId": "instant-app-id"
}
```

Resolution order is strict:

1. URL query params (`api`, `story_id`, `story_slug`, `pack`, `instant`)
2. `/runtime-config.json`
3. Derive `storySlug` from hostname when possible (`storytime-<slug>.*`)

If no StoryPack URL can be resolved, reader MUST enter `reader.error.invalid`.

## 3. StoryPack Contract

Reader requires:

- `schemaVersion: 1`
- `title`, `slug`
- `pages[]`

Each page SHOULD provide:

- `scene.url` (or equivalent alias `scene.imageUrl`)
- `narration.text`
- `narration.audioUrl`
- `narration.timingsUrl`
- `dialogue[]` with `id`, `text`, `audioUrl`, `timingsUrl`

Music contract:

- `music.tracks[]` with `id`, `audioUrl`
- `music.spans[]` with `trackId`, `startPageIndex`, `endPageIndex`, `loop`

If StoryPack is missing or malformed:

- Reader MUST show fail-safe error state
- Reader MUST NOT crash or render blank stage

## 4. Timing Contracts

Reader supports the following timing payloads for per-word highlighting.

### 4.1 Canonical WordTimings V2 (segment-based)

```json
{
  "schemaVersion": 2,
  "provider": "elevenlabs",
  "text": "full line text",
  "segmentGapMs": 100,
  "totalDurationMs": 1234,
  "segments": [
    {
      "index": 0,
      "voice": "character",
      "speakerId": "character-id",
      "text": "segment text",
      "charStart": 0,
      "charEnd": 12,
      "durationMs": 640,
      "audioUrl": "optional-per-segment-url",
      "words": [
        {
          "text": "word",
          "startMs": 0,
          "endMs": 180,
          "charStart": 0,
          "charEnd": 4
        }
      ]
    }
  ]
}
```

### 4.2 ElevenLabs Text-to-Dialogue Convert With Timestamps (raw provider payload)

Reference: ElevenLabs API docs, endpoint `POST /v1/text-to-dialogue/convert-with-timestamps`.

Reader MUST accept the raw payload shape containing:

- `alignment.characters[]`
- `alignment.character_start_times_seconds[]`
- `alignment.character_end_times_seconds[]`
- `voice_segments[]` with at least:
  - `character_start_index`
  - `character_end_index`
  - optional speaker metadata (`speaker_id`, `dialogue_input_index`)

Reader normalization rules:

1. Build global word timings from `alignment` arrays.
2. Partition words into segments via `voice_segments` char index ranges.
3. Use millisecond timing for highlight.
4. Preserve monotonic word order.
5. Use a strict error state when arrays are invalid (length mismatch / malformed indexes).

### 4.3 Legacy compatibility payload (currently persisted in some stories)

Reader MAY accept existing segment payloads where words use `word` instead of `text`.
This is treated as a supported payload variant, not a silent fallback path.

## 5. Highlighting Rules

Reader highlight engine MUST:

- Map playback currentTime to active word index
- Keep highlight order monotonic for increasing playback time
- Avoid highlighting when timing text cannot be mapped deterministically
- Keep drift target within NFR-P05 (`<=120ms`)

## 6. Reader State Invariants

Reader state is modeled as tagged unions (ADT style).

Required top-level runtime states:

- `reader.loading`
- `reader.ready`
- `reader.error.notfound`
- `reader.error.invalid`

Required audio states:

- `reader.audio.stopped`
- `reader.audio.loading`
- `reader.audio.playing`
- `reader.audio.paused`
- `reader.audio.ended`
- `reader.audio.error`

Required mode states:

- `reader.mode.read_alone`
- `reader.mode.narrate`

Required collaboration states:

- `reader.collab.disconnected`
- `reader.collab.connecting`
- `reader.collab.solo`
- `reader.collab.active`
- `reader.collab.host`
- `reader.collab.guest`

## 7. Navigation and Playback Guarantees

Reader MUST provide:

- Prev/next navigation (arrow, click/tap, keyboard, swipe)
- Direct seek via page indicators
- Narrate mode auto-sequence:
  - narration then dialogue lines in page order
  - auto-advance to next page when sequence completes
- Read-alone mode:
  - manual playback only
  - no auto-advance

## 8. Collaboration Guarantees

Collaboration uses InstantDB room keyed by story slug.

Runtime guarantees:

- Anonymous ephemeral identity per session (no login)
- Presence list for active peers
- Host-led page sync with ordering sequence
- Named cursor overlays for same-page participants
- Guest follows current elected host when follow-host is enabled

## 9. Music Guarantees

- Music is selected by active page span
- Track change triggers crossfade
- Leaving all spans triggers fade-out
- Voice and music volume controls remain independent

## 10. Deploy Guarantees

Per-story static reader deploy MUST:

- Inject story source runtime config (`packUrl` and related env vars)
- Resolve to live URL and deep-link correctly (`/* -> index.html`)
- Continue to fetch StoryPack/assets cross-origin from API host

## 11. Required Failure Behavior

Reader MUST surface clear UI errors for:

- Missing config (`missing_story_config`)
- StoryPack fetch HTTP errors
- StoryPack schema/version violations
- Timing payload parse failures (while preserving non-crashing playback UI)
- InstantDB misconfiguration

Reader MUST NOT throw uncaught exceptions that blank the app shell.

## 12. Verification Mapping

This contract maps directly to:

- AC-009 StoryPack contract integrity
- AC-010 collaboration basics
- AC-011 deploy success path
- AC-012 deploy failure visibility
- AC-015 SPA routing

