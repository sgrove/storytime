# Feature Complete Editor Plan (2026-02-25)

## Goal
Ship the remaining editor/backend feature gaps so the editor flow is production-ready for story creation, asset generation, queue observability, and deploy handoff, while aligning spec text with implemented behavior.

## Scope
- Editor + API + workers + spec docs only.
- Reader UI parity work is left to the dedicated reader track, but backend contracts needed by reader are included.

## Requirements Alignment
- Source spec: `spec-assets/specs/storytime_codetv.spec.md` and `codetv/storytime_codetv.spec.md`.
- Additional runtime contract: `codetv/READER_MODE_RUNTIME_CONTRACT__SHIP_BLOCKER.md`.
- Repo-specific constraints: `CLAUDE.md`, `CODING_GUIDELINES.md`.

## Workstreams

### 1) Spec Drift Correction
1. Update FR-016 image size text from `512x512` to `1024x1024` headshots.
2. Apply same correction in both canonical spec copies to keep verification artifacts consistent.
3. Confirm no remaining stale references to `512x512` in spec docs.

### 2) Dialogue Generation Contract Upgrade (ElevenLabs Text-to-Dialogue)
1. Add a page-level ElevenLabs `text-to-dialogue/convert-with-timestamps` call inside dialogue generation worker.
2. Use generated dialogue lines (multiple inputs) with character-selected voice IDs.
3. Persist per-line timings derived from dialogue API alignment/voice segment metadata.
4. Keep per-line audio generation path for compatibility, but mark it to preserve page-generated timings.
5. Ensure queue payloads/events include enough context for debugging failed dialogue page generation.

### 3) TTS Worker Hardening + Narrator Default
1. Add support for preserving existing dialogue timings when `preserve_timings` is set.
2. Set default narration voice to Alice:
   - Voice ID: `Xb7hH8MSUJpSbSDYk0k2`
   - Label: `Alice - Clear, Engaging Educator`.
3. Keep override behavior through `ELEVENLABS_DEFAULT_VOICE_ID` env var.
4. Add/adjust tests for:
   - narrator voice default selection
   - preserve timings behavior
   - dialogue API payload expectations where feasible.

### 4) Scene Consistency Conditioning + Queue Clarity
1. Remove hard cap on scene character references so all page characters are included.
2. Keep low-fidelity reference usage for token/cost control and consistent conditioning behavior.
3. Add full character list metadata for scene jobs in diagnostics.
4. Update editor queue rendering to show scene character list without truncation.

### 5) Queue Transport Improvement (Push-first)
1. Reduce reliance on `/jobs` polling by:
   - continuing channel event-driven updates,
   - using polling only as periodic reconciliation safety net.
2. Maintain current diagnostics endpoint for stale/retry metadata.

### 6) Verification
1. Run targeted tests for changed modules.
2. Run full `mix test`.
3. Run `mix dialyzer` (or report blockers if environment limits).
4. Validate format/lint expectations (`mix format --check-formatted`).

## Delivery Artifacts
- Code changes in workers/controller/editor/spec files.
- Updated tests.
- This plan in `plans/`.
- Commit with drift correction + feature work.

## Risk Notes
- ElevenLabs dialogue endpoint response shape variations can break parsing; code should fail explicitly with actionable errors.
- Keeping per-line audio while using page-level dialogue timings is a transitional compatibility mode; reader track can later optimize to segment playback.

## Definition of Done
- Editor can generate page dialogue via multi-input ElevenLabs dialogue endpoint and preserve timing data.
- Narration defaults to Alice unless explicitly overridden.
- Scene queue entries show full character conditioning list.
- Spec no longer documents deprecated `512x512` headshot size.
- Tests and dialyzer pass locally.
