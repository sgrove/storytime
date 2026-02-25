# [RFC] Storytime CodeTV Specification

```text
Title: [RFC] Storytime for CodeTV Web Dev Challenge v1.0
Status: RFC

Owner (Product):     Sean (CodeTV participant, Product Lead)
Owner (Engineering): Sean + AI Agents (Implementation Team)
Stakeholders:        CodeTV Production, Render Sponsor Advisors, Storytime Demo Reviewers

Created:      2026-02-24
Last Updated: 2026-02-24
Approved:     TBD

Supersedes:   None
Related:      docs/codetv-web-dev-challenge.md
              docs/ihs-editor-prd.md
              docs/storytime-build-plan.md
              docs/spec_guide.md
```

## Executive Summary

Storytime is a 4-hour build of a simplified IHS-style platform that helps parents and teachers build AI-illustrated, narrated storybooks for kids. The product includes an editor SPA, a Phoenix API with WebSocket Channels and Oban workers, and a reader SPA that renders generated stories with audio and read-along highlighting. Render is the required platform and is used for deployment, runtime hosting, managed Postgres, managed Valkey, and persistent disk asset storage. Risk level is Medium-High because the demo depends on external GenAI APIs and live deployment speed under strict time constraints.

## 1. Objective and Background

### 1.1 Objective

Deliver a complete end-to-end web app that enables users to build and deploy interactive storybooks in one session: create content in the editor, generate assets with AI, and publish a live reader site on Render.

### 1.2 Background

Current CodeTV challenge requirements demand an app that helps people build something, with a hard 4-hour implementation window and required use of Render. Storytime maps directly to this brief by helping users build children stories with visual and audio assets generated from prompts.

The reference platform (IHS) already proves product desirability and technical viability: a non-technical user can produce rich storybooks through guided authoring and AI generation. Storytime narrows this to the minimum lovable subset that is realistic in live coding time while still visually impressive and technically defensible in a demo.

If Storytime is not scoped and specified tightly, the team risks spending the 4-hour window on infrastructure churn and incomplete integrations. This spec is designed to make implementation deterministic and demo-safe.

### 1.3 Success Summary

Success means a user can create a story, add characters and pages, generate images/audio/music, deploy to a Render-hosted story URL, and read the story with page navigation, voice playback, and word-level highlighting within the same session.

## 2. Scope and Non-Goals

### 2.1 In Scope

- Full-stack Storytime system deployed on Render using a Render Blueprint.
- Editor SPA with Story, Cast, Pages, Music, and Preview tabs.
- Phoenix backend with WebSocket Channels for editor operations.
- Postgres-backed domain data via Ecto.
- Oban workers for image generation, TTS generation, music generation, and deploy orchestration.
- Persistent disk asset storage and Phoenix static asset serving.
- StoryPack JSON assembly and API delivery.
- Reader SPA with immersive page display, dialogue playback, read-along highlighting, and background music.
- Reader real-time collaboration using InstantDB for presence, page sync, and cursors.
- Per-story deploy flow creating Render Static Sites through Render API.

### 2.2 Out of Scope (Non-Goals)

- Chat-driven LLM editing loop in the editor.
Reason: Direct manipulation UI is faster to implement and easier to demo in 4 hours.

- Full user account systems for editor and reader.
Reason: Anonymous/ephemeral identity reduces scope and removes authentication bottlenecks.

- Multi-tenant hard isolation for every story database instance.
Reason: Storytime uses one primary Postgres app and per-story static site URLs; deep tenancy isolation is beyond event scope.

- Advanced IHS features such as stickers, 3D cover shader, full social workflow, and sound-effect authoring UX.
Reason: These are stretch goals and not required for core end-to-end success.

- Any hosting or managed Postgres alternatives that conflict with Render sponsor constraints.
Reason: Challenge requires Render and disallows competitive equivalents for services Render already provides.

## 3. Functional Requirements

### 3.1 Authoring and Story Data

- FR-001 Story Creation
The system MUST allow creation of a story with `title`, `slug`, and `art_style`.

> **Concept mockups (two model variants: `nano-banana-pro`, `gpt-image-1.5`).**
>
> ![Story Creation - New Story Form (nano-banana-pro)](mockups/editor-story-empty--nano-banana-pro.png)
> ![Story Creation - New Story Form (gpt-image-1.5)](mockups/editor-story-empty--gpt-image-1.5.png)
> *Figure FR-001-A: Story Creation - New Story Form.*

- FR-002 Slug Behavior
The system MUST auto-derive slug from title and MUST enforce story slug uniqueness.

- FR-003 Story Status Lifecycle
The story status MUST be one of `draft`, `generating`, `ready`, or `deployed`.

> **Concept mockups (two model variants: `nano-banana-pro`, `gpt-image-1.5`).**
>
> ![Editor Lobby - Empty State (nano-banana-pro)](mockups/editor-lobby-empty--nano-banana-pro.png)
> ![Editor Lobby - Empty State (gpt-image-1.5)](mockups/editor-lobby-empty--gpt-image-1.5.png)
> *Figure FR-003-A: Editor Lobby - Empty State (first-time user).*
>
> ![Editor Lobby - With Existing Stories (nano-banana-pro)](mockups/editor-lobby-populated--nano-banana-pro.png)
> ![Editor Lobby - With Existing Stories (gpt-image-1.5)](mockups/editor-lobby-populated--gpt-image-1.5.png)
> *Figure FR-003-B: Editor Lobby - With Existing Stories.*

- FR-004 Character CRUD
The system MUST support create, read, update, delete for characters with fields: name, visual description, voice provider/id/model, sort order, and optional headshot URL.

- FR-005 Page CRUD
The system MUST support create, read, update, delete for pages with fields: page index, scene description, narration text, scene image URL, narration audio URL, narration timings URL, and sort order.

> **Concept mockups (two model variants: `nano-banana-pro`, `gpt-image-1.5`).**
>
> ![Pages Tab - Empty State (nano-banana-pro)](mockups/editor-pages-empty--nano-banana-pro.png)
> ![Pages Tab - Empty State (gpt-image-1.5)](mockups/editor-pages-empty--gpt-image-1.5.png)
> *Figure FR-005-A: Pages Tab - Empty State.*

- FR-006 Page Reordering
The system MUST support reordering pages and MUST persist stable `page_index` ordering after each reorder operation.

```mermaid
stateDiagram-v2
    direction TB
    state "Editor Pages Tab Detailed Flow" as EditorPages {
        Empty --> Creating : Add First Page
        Populated --> Creating : Add New Page
        Creating --> Editing : Page Created
        Editing --> SceneGenerating : Generate Scene
        Editing --> NarrationGenerating : Generate Narration
        Editing --> DialogueEditing : Manage Dialogue

        state "Scene Generation" as SceneGen {
            SceneGenerating --> SceneComplete : Success
            SceneGenerating --> SceneFailed : Error
            SceneFailed --> SceneGenerating : Retry
        }

        state "Narration Generation" as NarrationGen {
            NarrationGenerating --> NarrationComplete : Success
            NarrationGenerating --> NarrationFailed : Error
            NarrationFailed --> NarrationGenerating : Retry
        }

        state "Dialogue Management" as DialogueManage {
            DialogueEditing --> DialogueLineCreating : Add Line
            DialogueLineCreating --> DialogueLineEditing : Line Created
            DialogueLineEditing --> DialogueGenerating : Generate TTS
            DialogueGenerating --> DialogueComplete : Success
            DialogueGenerating --> DialogueFailed : Error
            DialogueFailed --> DialogueGenerating : Retry
            DialogueComplete --> DialogueLineEditing : Edit More
        }

        SceneComplete --> Editing : Continue Editing
        NarrationComplete --> Editing : Continue Editing
        DialogueComplete --> Editing : Continue Editing

        Editing --> Reordering : Drag to Reorder
        Reordering --> Editing : Drop Complete
    }
```

- FR-007 Dialogue CRUD
The system MUST support create, read, update, delete for dialogue lines linked to pages and characters with sortable order.

- FR-008 Music CRUD
The system MUST support music tracks and page-span assignments with optional looping behavior.

- FR-009 Preview Fidelity
The editor Preview tab MUST render from the same StoryPack contract used by the reader to prevent schema drift.

### 3.2 Editor Real-Time Protocol

- FR-010 Story Channel
The editor client MUST connect to a Phoenix Channel topic `story:{story_id}`.

- FR-011 Client Event Support
The channel MUST accept at least the following client events: `update_story`, `add_character`, `update_character`, `delete_character`, `add_page`, `update_page`, `reorder_pages`, `delete_page`, `add_dialogue_line`, `update_dialogue_line`, `delete_dialogue_line`, `generate_headshot`, `generate_scene`, `generate_all_scenes`, `generate_dialogue_audio`, `generate_all_audio`, `generate_music`, `generate_all`, `deploy_story`.

```mermaid
stateDiagram-v2
    direction TB
    state "Real-time Connection" as WebSocketFlow {
        Disconnected --> Connecting : App Start
        Connecting --> Connected : Handshake Complete
        Connected --> Disconnected : Network Lost
        Disconnected --> Reconnecting : Auto Retry
        Reconnecting --> Connected : Reconnect Success
        Reconnecting --> Disconnected : Retry Failed

        Connected --> ChannelJoined : Join Story Channel
        ChannelJoined --> ReceivingUpdates : Live Events
        ReceivingUpdates --> ChannelJoined : Continue
    }
```

- FR-012 Broadcast Event Support
The channel MUST broadcast at least: `story_updated`, `character_added`, `page_updated`, `generation_started`, `generation_progress`, `generation_completed`, `generation_failed`, `deploy_started`, `deploy_completed`, `deploy_failed`.

- FR-013 Event Persistence
All mutating channel events MUST persist authoritative changes in Postgres before success acknowledgment.

- FR-014 Generation Queue Visibility
The editor MUST show active generation jobs and progress state derived from channel broadcasts.

> **Concept mockups (two model variants: `nano-banana-pro`, `gpt-image-1.5`).**
>
> ![Generation Queue - Active Jobs with Progress (nano-banana-pro)](mockups/editor-generation-active--nano-banana-pro.png)
> ![Generation Queue - Active Jobs with Progress (gpt-image-1.5)](mockups/editor-generation-active--gpt-image-1.5.png)
> *Figure FR-014-A: Generation Queue - Active Jobs with Progress.*

```mermaid
stateDiagram-v2
    direction TB
    state "Global Generation Queue" as GenQueue {
        Idle --> SingleJobActive : Start Generation
        SingleJobActive --> MultipleJobsActive : More Jobs Added
        MultipleJobsActive --> SingleJobActive : Jobs Completing
        SingleJobActive --> Idle : Last Job Complete

        Idle --> GenerateAllRunning : Generate All Clicked
        GenerateAllRunning --> MultipleJobsActive : Jobs Enqueued
        GenerateAllRunning --> Idle : All Complete

        state "Job States" as JobStates {
            Pending --> Running : Worker Started
            Running --> Complete : Success
            Running --> Failed : Error
            Failed --> Pending : Retry
        }

        SingleJobActive --> JobStates
        MultipleJobsActive --> JobStates
        GenerateAllRunning --> JobStates
    }
```

### 3.3 Generation Pipeline

- FR-015 Job Offloading
Generation and deploy operations MUST execute asynchronously in Oban workers.

- FR-016 Image Generation
`ImageGen` worker MUST generate headshots and scenes via OpenAI Images API using `gpt-image-1.5` with size `1024x1024` for headshots and `1536x1024` for scenes.

- FR-017 Image Prompt Composition
Image prompts MUST combine story-level art style plus target-level visual context.

> **Concept mockups (two model variants: `nano-banana-pro`, `gpt-image-1.5`).**
>
> ![Pages Tab - Scene Editing with Generation Preview (nano-banana-pro)](mockups/editor-pages-editing--nano-banana-pro.png)
> ![Pages Tab - Scene Editing with Generation Preview (gpt-image-1.5)](mockups/editor-pages-editing--gpt-image-1.5.png)
> *Figure FR-005/FR-006/FR-016/FR-017-A: Pages editing + scene generation workflow.*

- FR-018 TTS Generation
`TtsGen` worker MUST generate narration/dialogue audio using ElevenLabs timestamp API and persist audio plus timings outputs.

- FR-019 Timings Contract
TTS word timing outputs MUST be transformed to WordTimings V2 segment-based JSON for reader compatibility.

- FR-020 Music Generation
`MusicGen` worker MUST call Sonauto create endpoint, poll for completion, download MP3, and persist asset metadata.

- FR-021 Kitchen-Sink Trigger
`generate_all` MUST enqueue jobs for missing headshots, scenes, dialogue audio, narration audio, and music.

- FR-022 Failure Handling
If a worker fails, the system MUST set generation job status `failed`, persist error text, and broadcast `generation_failed`.

- FR-023 Retry Behavior
Workers SHOULD use bounded retry with exponential backoff; retries MUST not duplicate completed assets for the same target and story.

### 3.4 Asset Pipeline and StoryPack

- FR-024 Asset Storage Pathing
All generated files MUST be written under `/app/assets/{story_id}/` on Render persistent disk.

- FR-025 Required Asset Naming
The system MUST use deterministic file naming:
`headshot_{character_id}.png`, `scene_{page_id}.png`, `dialogue_{line_id}.mp3`, `dialogue_{line_id}_timings.json`, `narration_{page_id}.mp3`, `narration_{page_id}_timings.json`, `music_{track_id}.mp3`, `story.json`.

- FR-026 Asset Serving
Phoenix MUST serve `/assets/*` publicly via Plug.Static.

- FR-027 StoryPack Endpoint
The backend MUST expose `GET /api/stories/:id/pack` returning canonical StoryPack JSON.

- FR-028 StoryPack URL Integrity
Asset URLs in StoryPack MUST be absolute URLs that resolve against the Phoenix host.

- FR-029 CORS Behavior
Asset and StoryPack responses MUST support cross-origin reads from reader domains.

- FR-030 Schema Versioning
StoryPack payload MUST include `schemaVersion: 1`; word timing payload MUST include `schemaVersion: 2`.

### 3.5 Reader Experience

- FR-031 Story Loading
Reader MUST load story data at startup and render fail-safe error state if story JSON is unavailable or invalid.

- FR-032 Core Page Rendering
Reader MUST render full-bleed scene image with non-cropping strategy and background letterbox treatment.

> **Concept mockups (two model variants: `nano-banana-pro`, `gpt-image-1.5`).**
>
> ![Reader - Page Reading Experience (nano-banana-pro)](mockups/reader-page-reading--nano-banana-pro.png)
> ![Reader - Page Reading Experience (gpt-image-1.5)](mockups/reader-page-reading--gpt-image-1.5.png)
> *Figure FR-031/FR-032-A: Reader page loading and core reading composition.*

- FR-033 Navigation
Reader MUST support page navigation via tap/click/arrow and SHOULD support swipe on touch devices.

```mermaid
stateDiagram-v2
    direction TB
    state "Reader Navigation" as ReaderNav {
        FirstPage --> MiddlePage : Next Pressed
        MiddlePage --> LastPage : Next Pressed
        LastPage --> MiddlePage : Previous Pressed
        MiddlePage --> FirstPage : Previous Pressed

        state "Page Transition" as PageTransition {
            [*] --> Transitioning
            Transitioning --> Complete : Animation Done
            Complete --> [*]
        }

        FirstPage --> PageTransition : Navigate
        MiddlePage --> PageTransition : Navigate
        LastPage --> PageTransition : Navigate

        state "Seeking" as Seeking {
            [*] --> PageIndicatorTouched
            PageIndicatorTouched --> JumpToPage : Page Selected
            JumpToPage --> [*] : Jump Complete
        }

        FirstPage --> Seeking : Page Indicator
        MiddlePage --> Seeking : Page Indicator
        LastPage --> Seeking : Page Indicator
    }
```

- FR-034 Dialogue Playback
Reader MUST support per-dialogue-line playback using generated audio assets.

- FR-035 Read-Along Highlighting
Reader MUST map playback position to active words using WordTimings V2 and highlight words in-order.

> **Concept mockups (two model variants: `nano-banana-pro`, `gpt-image-1.5`).**
>
> ![Reader - Audio Narration with Word Highlighting (nano-banana-pro)](mockups/reader-audio-narration--nano-banana-pro.png)
> ![Reader - Audio Narration with Word Highlighting (gpt-image-1.5)](mockups/reader-audio-narration--gpt-image-1.5.png)
> *Figure FR-034/FR-035-A: Dialogue and narration playback with karaoke highlighting.*

```mermaid
stateDiagram-v2
    direction TB
    state "Reader Audio System" as ReaderAudio {
        Stopped --> Loading : Play Pressed
        Loading --> Playing : Audio Ready
        Loading --> Error : Load Failed
        Playing --> Paused : Pause Pressed
        Paused --> Playing : Resume
        Playing --> Stopped : Audio Ended
        Error --> Loading : Retry

        state "Audio Types" as AudioTypes {
            state "Narration Mode" as NarrationMode {
                NarrationPlaying --> WordHighlighting : Sync Active
                WordHighlighting --> NarrationPlaying : Continue
            }

            state "Dialogue Mode" as DialogueMode {
                DialoguePlaying --> WordHighlighting : Sync Active
                WordHighlighting --> DialoguePlaying : Continue
            }
        }

        Playing --> AudioTypes : Audio Type Specific
    }
```

- FR-036 Narrate Mode
Reader MUST provide `Narrate` mode that auto-plays voice content in page order.

- FR-037 Read-Alone Mode
Reader MUST provide `Read Alone` mode that disables auto-play and allows manual playback.

```mermaid
stateDiagram-v2
    direction TB
    state "Reader Mode System" as ReaderModes {
        ReadAlone --> Switching : Switch to Narrate
        Switching --> Narrate : Mode Changed
        Narrate --> Switching : Switch to Read Alone
        Switching --> ReadAlone : Mode Changed

        state "Mode Behaviors" as ModeBehaviors {
            state "Read Alone Mode" as ReadAloneBehavior {
                ManualControl --> [*] : User Driven
            }

            state "Narrate Mode" as NarrateBehavior {
                AutoAdvance --> NextPageAuto : Audio Ends
                NextPageAuto --> [*] : Continue Story
            }
        }

        ReadAlone --> ReadAloneBehavior
        Narrate --> NarrateBehavior
    }
```

- FR-038 Music Playback
Reader MUST support background music playback and crossfade when page span transitions require track changes.

- FR-039 Independent Volume
Reader MUST provide independent controls for voice and music volume.

```mermaid
stateDiagram-v2
    direction TB
    state "Reader Volume Control" as VolumeControl {
        [*] --> VoiceVolume
        [*] --> MusicVolume
        VoiceVolume --> Adjusting : Slider Active
        MusicVolume --> Adjusting : Slider Active
        Adjusting --> VoiceVolume : Voice Changed
        Adjusting --> MusicVolume : Music Changed
    }
```

### 3.6 Reader Collaboration

- FR-040 Collaboration Store
Reader collaboration MUST use InstantDB in a room keyed by story slug.

- FR-041 Identity Model
Reader MUST assign anonymous ephemeral identity at runtime (stable for session, no login requirement).

- FR-042 Presence
Reader MUST show active participants in the current room.

- FR-043 Page Sync
Reader MUST support host-led page synchronization across connected participants.

- FR-044 Pointer Sharing
Reader MUST support named pointer cursors for collaborators.

> **Concept mockups (two model variants: `nano-banana-pro`, `gpt-image-1.5`).**
>
> ![Reader - Collaborative Reading with Cursors (nano-banana-pro)](mockups/reader-collab-active--nano-banana-pro.png)
> ![Reader - Collaborative Reading with Cursors (gpt-image-1.5)](mockups/reader-collab-active--gpt-image-1.5.png)
> *Figure FR-040..FR-044-A: Collaboration room with presence and shared cursors.*

```mermaid
stateDiagram-v2
    direction TB
    state "Reader Collaboration Detailed" as ReaderCollab {
        Disconnected --> Connecting : Join Room
        Connecting --> Solo : Connected, No Others
        Solo --> Active : Participant Joins
        Active --> Solo : Last Other Leaves

        state "Role Management" as RoleManage {
            Guest --> Host : Host Left/Assigned
            Host --> Guest : Relinquish Host
        }

        Active --> RoleManage : Role Changes

        state "Sync Behaviors" as SyncBehaviors {
            state "Host Behaviors" as HostBehaviors {
                HostPageChange --> BroadcastPageChange
                BroadcastPageChange --> [*]
            }

            state "Guest Behaviors" as GuestBehaviors {
                ReceivePageChange --> FollowHost
                FollowHost --> [*]
            }
        }

        Host --> HostBehaviors : Page Navigation
        Guest --> GuestBehaviors : Receive Update

        state "Cursor Sharing" as CursorSharing {
            [*] --> CursorMove
            CursorMove --> BroadcastCursor
            BroadcastCursor --> [*]
        }

        Active --> CursorSharing : Mouse/Touch Move
    }
```

### 3.7 Deployment and Render Site Provisioning

- FR-045 Deploy Trigger
Editor deploy action MUST request `subdomain` and enqueue deploy worker.

- FR-046 Deploy Assembly
Deploy worker MUST assemble latest StoryPack JSON from Postgres and asset URLs from persistent disk.

- FR-047 Render API Site Creation
Deploy worker MUST create a Render Static Site per story through Render API and persist Render site ID.

- FR-048 Reader Runtime Configuration
Per-story reader site MUST receive story source configuration through environment variables or equivalent render-time config.

- FR-049 Deploy Completion State
On successful deploy, backend MUST set story status `deployed`, store `deploy_url`, and broadcast `deploy_completed`.

> **Concept mockups (two model variants: `nano-banana-pro`, `gpt-image-1.5`).**
>
> ![Deploy Complete - Published Story with Share Options (nano-banana-pro)](mockups/editor-deploy-complete--nano-banana-pro.png)
> ![Deploy Complete - Published Story with Share Options (gpt-image-1.5)](mockups/editor-deploy-complete--gpt-image-1.5.png)
> *Figure FR-045..FR-049-A: Deploy complete state with live URL handoff to reader.*

- FR-050 Deploy Failure State
On failed deploy, backend MUST persist failure reason and broadcast `deploy_failed`.

### 3.8 System Health and Operability

- FR-051 Health Endpoint
Backend MUST expose `GET /health` returning 200 when app, DB, and critical runtime dependencies are healthy enough for traffic.

- FR-052 Migration on Deploy
Production deploy process MUST run migrations before app startup.

- FR-053 Static Editor Routing
Editor static site MUST rewrite non-asset routes to `index.html` for SPA routing.

- FR-054 Reader Template Reusability
Reader MUST be built once as a template deployable repeatedly for per-story static sites.

## 4. Non-Functional Requirements

```text
PERFORMANCE
NFR-P01: Editor Channel join MUST complete within 1 second P95 on stable network.
NFR-P02: CRUD event round-trip (client event to broadcast update) MUST complete within 300ms P95.
NFR-P03: StoryPack endpoint response time MUST be <=500ms P95 for stories with <=20 pages.
NFR-P04: Reader initial render SHOULD complete within 2 seconds on modern mobile over strong LTE/Wi-Fi.
NFR-P05: Word highlight drift relative to audio MUST be <=120ms for generated TTS lines.

RELIABILITY
NFR-R01: Core API service availability target MUST be >=99.5% during challenge demo window.
NFR-R02: Worker jobs MUST be durable across service restarts through Oban/Postgres persistence.
NFR-R03: Completed generation jobs MUST be idempotent; replays MUST NOT duplicate files or corrupt URLs.
NFR-R04: Deploy worker MUST tolerate transient Render API failures with bounded retries.

SCALABILITY
NFR-S01: System MUST support at least 10 concurrent generation jobs without API crash.
NFR-S02: Reader collaboration room MUST support at least 5 concurrent participants with acceptable UX.

SECURITY AND INTEGRITY
NFR-I01: API keys MUST never be committed to repository or returned to browser clients.
NFR-I02: CORS MUST allow only required methods/headers for reader asset fetch and API usage.
NFR-I03: Story and asset records MUST maintain referential integrity through foreign keys and changesets.

COST/EFFICIENCY
NFR-E01: Build MUST use Render starter/basic plans that fit challenge budget constraints.
NFR-E02: Generation retries MUST be bounded to avoid runaway third-party API cost.

EXPERIENCEABILITY
NFR-X01: Editor and reader MUST both be usable on desktop and mobile viewport classes.
NFR-X02: Demo-critical actions (Generate All, Deploy, Play dialogue, Next page) MUST be discoverable without hidden menus.
```

## 5. Constraints and Dependencies

```text
TECHNICAL CONSTRAINTS
C-T01: MUST use Render as deployment platform for app hosting and managed Postgres.
C-T02: MUST NOT use competitive deployment or managed Postgres providers.
C-T03: MUST implement within effective 4-hour coding window using prebuilt skeleton repository.
C-T04: Backend stack is fixed to Phoenix 1.8, Ecto/Postgres, Oban, Phoenix Channels.
C-T05: Asset storage is fixed to Render Persistent Disk mounted at /app/assets.
C-T06: Reader collaboration uses InstantDB only for real-time collaboration features.

ORGANIZATIONAL CONSTRAINTS
C-O01: Solo builder + AI agents; concurrency is limited by one human integrator.
C-O02: Demo slot is 3-5 minutes, requiring polished happy path over complete feature parity with IHS.

COMPATIBILITY CONSTRAINTS
C-C01: StoryPack contract MUST be compatible with reader runtime expectations from IHS-derived types.
C-C02: Word timings MUST use segment-based V2 semantics for karaoke highlighting.

DEPENDENCIES
D-01: Render API
      Needed for: per-story static site creation
      Risk: Medium (token scope or API latency issues)

D-02: OpenAI Images API
      Needed for: scene/headshot generation
      Risk: Medium (latency variability and occasional generation failures)

D-03: ElevenLabs TTS API
      Needed for: dialogue and narration with timestamps
      Risk: Medium (rate limits and variable synthesis latency)

D-04: Sonauto API
      Needed for: background music generation
      Risk: Medium-High (async generation may exceed demo timing)

D-05: InstantDB
      Needed for: reader presence/page sync/pointers
      Risk: Low-Medium (service or key misconfiguration can disable collaboration layer)
```

## 6. Acceptance Criteria

```text
AC-001: Create Story and Persist Basics (FR-001, FR-002, FR-003)
GIVEN the editor is connected to story:{story_id}
WHEN user sets title "The Moonlit Garden" and art style "watercolor"
THEN story record is persisted with non-empty slug and status "draft"
AND refreshed editor state shows same values

AC-002: Character CRUD Round-Trip (FR-004, FR-011, FR-013)
GIVEN an existing draft story
WHEN user adds a character with voice settings and then edits then deletes it
THEN each operation is persisted in Postgres
AND corresponding channel updates are broadcast

AC-003: Page and Dialogue Editing (FR-005, FR-006, FR-007)
GIVEN an existing draft story
WHEN user adds 3 pages, reorders them, and adds dialogue lines
THEN page order and dialogue sort order are stable after reload
AND all records remain linked to correct story/page/character IDs

AC-004: Scene Generation Success (FR-015, FR-016, FR-017, FR-024, FR-025)
GIVEN a page with scene description and story art style
WHEN user triggers generate_scene
THEN an Oban job runs and writes scene_{page_id}.png under /app/assets/{story_id}
AND page record stores absolute URL
AND generation_completed broadcast includes target ID and URL

AC-005: Dialogue TTS and Timings (FR-018, FR-019, FR-035)
GIVEN a dialogue line with valid speaker voice metadata
WHEN user triggers generate_dialogue_audio
THEN system stores dialogue_{line_id}.mp3 and dialogue_{line_id}_timings.json
AND timings payload uses schemaVersion 2 with segment+word offsets
AND reader highlights words in playback order

AC-006: Music Generation and Span Playback (FR-020, FR-038)
GIVEN a music track and page span assignment
WHEN user triggers generate_music and opens reader
THEN music_{track_id}.mp3 is persisted
AND reader starts track on span start page and crossfades on span transition

AC-007: Generate All Missing Assets (FR-021)
GIVEN a story with partial assets already generated
WHEN user triggers generate_all
THEN system enqueues only missing assets
AND existing completed asset URLs remain unchanged

AC-008: Worker Failure Handling (FR-022, FR-023)
GIVEN external API returns an error for generation
WHEN worker exhausts retries
THEN generation job status is "failed"
AND error text is persisted and broadcast via generation_failed
AND editor queue displays failed state without crashing

AC-009: StoryPack Contract Integrity (FR-026, FR-027, FR-028, FR-030, FR-031)
GIVEN a story with generated assets
WHEN reader requests /api/stories/:id/pack
THEN response includes schemaVersion 1 and complete characters/pages/music structure
AND every asset URL resolves over HTTP 200
AND reader renders story without schema parsing errors

AC-010: Collaboration Basics (FR-040, FR-041, FR-042, FR-043, FR-044)
GIVEN two clients open same deployed story slug
WHEN host changes page and both users move pointers
THEN both users appear in presence list
AND guest page follows host page
AND pointer overlays show names and positions in near real-time

AC-011: Deploy Success Path (FR-045, FR-046, FR-047, FR-048, FR-049)
GIVEN story has valid content and deploy subdomain input
WHEN user clicks Deploy and deploy worker completes
THEN backend persists render_site_id and deploy_url
AND deploy_completed broadcast contains public URL
AND opening URL loads reader story successfully

AC-012: Deploy Failure Path (FR-050)
GIVEN Render API token is invalid or site creation fails
WHEN deploy worker runs
THEN story remains non-deployed status
AND deploy_failed includes error details visible in editor

AC-013: Invalid Inputs and Boundaries (FR-002, FR-045)
GIVEN malformed slug or subdomain input
WHEN user attempts save/deploy
THEN API rejects with validation error
AND no DB row or Render site is created

AC-014: Service Health (FR-051, FR-052)
GIVEN production service startup
WHEN health endpoint is checked
THEN /health returns 200 only after migrations complete and dependencies are configured

AC-015: SPA Routing (FR-053, FR-054)
GIVEN user deep-links into editor/reader routes
WHEN static site handles request
THEN request rewrites to index.html and client router resolves correct page
```

## 7. Design Guidance (Non-Binding)

**NOTE:** This section is guidance, not requirements. Engineering may deviate with documented rationale.

### 7.0 Supplementary Asset Contract (Compiler/Run Integration)

To keep implementation and verification aligned with the visual references in this spec:

- All markdown image references in this document (mockups, moodboards, and similar) are intentional supplementary assets and are addressed relative to this spec file path.
- Inline fenced Mermaid blocks in this document are authoritative diagram source and MUST be treated as reviewable implementation context.
- If an asset file is renamed or moved, this spec MUST be updated in the same change so references remain valid.
- Supplementary assets are read-only implementation context, not generated output requirements by themselves.

![Editor workshop moodboard reference](moodboard-editor-materials.png)
*Figure 7-A: Editor world moodboard - handcrafted workshop materials, parchment, leather, and brass accents.*

![Reader cottage moodboard reference](moodboard-reader-cottage-gpt.png)
*Figure 7-B: Reader world moodboard - cozy Cotswold cottage ambiance with honey stone, hearth warmth, and storybook intimacy.*

### 7.1 Recommended Approach

Use a Render-first architecture with one Phoenix backend and two React SPAs.

- Editor SPA is a Render Static Site.
- Phoenix API is a Render Web Service using managed Postgres, managed Valkey, and persistent disk.
- Reader template is a Render Static Site reused for per-story deployments.
- Deploy worker provisions per-story static sites with story source config pointing back to Phoenix-hosted StoryPack/assets.

Rationale: This approach satisfies sponsor constraints, minimizes platform sprawl, and keeps all mission-critical runtime components on Render.

### 7.2 Architecture Blueprint

```text
User -> Editor SPA (Render Static Site)
     -> Phoenix Channel (story:{id})
     -> Ecto/Postgres
     -> Oban workers (image, tts, music, deploy)
     -> /app/assets/{story_id} (Render Persistent Disk)
     -> StoryPack API + /assets static serving
     -> Render API creates per-story Reader Static Site
Reader -> fetch story pack/assets from Phoenix
       -> InstantDB room for collaboration state
```

```mermaid
stateDiagram-v2
    direction TB

    [*] --> AppLoading
    AppLoading --> EditorLobby : App Bootstrap Complete
    AppLoading --> MaintenanceMode : Service Down

    state "Editor SPA (Workshop)" as EditorSPA {
        EditorLobby --> StoryCreation : Create New Story
        EditorLobby --> StoryEditor : Open Existing Story

        state "Story Editor" as StoryEditor {
            StoryTab --> CastTab : Navigate to Cast
            StoryTab --> PagesTab : Navigate to Pages
            StoryTab --> MusicTab : Navigate to Music
            StoryTab --> PreviewTab : Navigate to Preview

            CastTab --> StoryTab : Navigate to Story
            CastTab --> PagesTab : Navigate to Pages
            CastTab --> MusicTab : Navigate to Music
            CastTab --> PreviewTab : Navigate to Preview

            PagesTab --> StoryTab : Navigate to Story
            PagesTab --> CastTab : Navigate to Cast
            PagesTab --> MusicTab : Navigate to Music
            PagesTab --> PreviewTab : Navigate to Preview

            MusicTab --> StoryTab : Navigate to Story
            MusicTab --> CastTab : Navigate to Cast
            MusicTab --> PagesTab : Navigate to Pages
            MusicTab --> PreviewTab : Navigate to Preview

            PreviewTab --> StoryTab : Navigate to Story
            PreviewTab --> CastTab : Navigate to Cast
            PreviewTab --> PagesTab : Navigate to Pages
            PreviewTab --> MusicTab : Navigate to Music

            state "Deploy Flow" as DeployFlow {
                [*] --> DeployConfig
                DeployConfig --> DeployRunning : Submit Deploy
                DeployRunning --> DeployComplete : Success
                DeployRunning --> DeployFailed : Error
                DeployFailed --> DeployConfig : Retry
                DeployComplete --> [*] : Deploy URL Available
            }

            StoryEditor --> DeployFlow : Click Deploy
            DeployFlow --> ReaderSPA : Open Deployed Story
        }

        StoryCreation --> StoryEditor : Story Created
        StoryEditor --> EditorLobby : Back to Lobby
    }

    state "Reader SPA (Cottage)" as ReaderSPA {
        ReaderLoading --> StoryIntro : Story Pack Loaded
        ReaderLoading --> ReaderError : Load Failed

        StoryIntro --> PageReading : Start Reading
        PageReading --> PageReading : Navigate Pages

        state "Collaboration" as Collaboration {
            Solo --> Active : Participant Joins
            Active --> Solo : All Others Leave
            Guest --> Host : Become Host
            Host --> Guest : Host Leaves
        }

        PageReading --> Collaboration : Real-time Sync
        Collaboration --> PageReading : Continue Reading

        ReaderError --> ReaderLoading : Retry Load
    }

    EditorSPA --> ReaderSPA : Deploy Story / Preview
    ReaderSPA --> EditorSPA : Edit Story (if owner)

    AppLoading --> FatalError : Bootstrap Failed
    EditorSPA --> Offline : Network Lost
    ReaderSPA --> Offline : Network Lost
    Offline --> EditorSPA : Network Restored
    Offline --> ReaderSPA : Network Restored

    MaintenanceMode --> AppLoading : Service Restored

    note right of EditorSPA
        Workshop Aesthetic:
        - Warm parchment pages
        - Leather spine with ribbons
        - Craft metaphor throughout
    end note

    note right of ReaderSPA
        Cozy Cotswold Cottage Aesthetic:
        - Honey stone walls and lit fireplace
        - Aged leather tome and warm oak controls
        - Intimate bedtime-reading atmosphere
    end note
```

### 7.3 Render Services and Infrastructure Layout

```text
Service 1: storytime-api (Render Web Service)
- Runtime: Elixir
- Hosts: Phoenix API, WebSocket, Oban workers, static assets
- Disk: /app/assets (1GB+)

Service 2: storytime-editor (Render Static Site)
- Runtime: static
- Build: Vite app in editor/

Service 3: storytime-db (Render Managed Postgres)
- Stores canonical story, asset metadata, worker metadata

Service 4: storytime-kv (Render Key Value / Valkey)
- Used by Phoenix PubSub Redis adapter

Service 5: storytime-reader-template (Render Static Site)
- Built once from reader/ codebase

Service 6+: storytime-reader-{slug} (Render Static Site per deploy)
- Created via Render API by deploy worker
```

### 7.4 Data Model Implementation Details

Implement Ecto schemas and migrations for:

- `stories`
- `characters`
- `pages`
- `dialogue_lines`
- `music_tracks`
- `music_spans`
- `generation_jobs` (optional but recommended for UI/status projection)

Recommended schema field set:

```text
stories
- id: uuid PK
- title: string
- slug: string unique
- art_style: string
- status: enum draft|generating|ready|deployed
- deploy_url: string nullable
- render_site_id: string nullable
- inserted_at, updated_at

characters
- id: uuid PK
- story_id: uuid FK stories
- name: string
- visual_description: text
- voice_provider: string
- voice_id: string
- voice_model_id: string
- headshot_url: string nullable
- sort_order: integer

pages
- id: uuid PK
- story_id: uuid FK stories
- page_index: integer
- scene_description: text
- narration_text: text nullable
- scene_image_url: string nullable
- narration_audio_url: string nullable
- narration_timings_url: string nullable
- sort_order: integer

dialogue_lines
- id: uuid PK
- page_id: uuid FK pages
- character_id: uuid FK characters
- text: text
- audio_url: string nullable
- timings_url: string nullable
- sort_order: integer

music_tracks
- id: uuid PK
- story_id: uuid FK stories
- title: string
- mood: string
- audio_url: string nullable

music_spans
- id: uuid PK
- track_id: uuid FK music_tracks
- start_page_index: integer
- end_page_index: integer
- loop: boolean default true

generation_jobs
- id: uuid PK
- story_id: uuid FK stories
- job_type: enum headshot|scene|dialogue_tts|narration_tts|music|sfx|deploy
- target_id: uuid nullable
- status: enum pending|running|completed|failed
- error: text nullable
- inserted_at, updated_at
```

### 7.5 API and Channel Contracts

REST endpoints:

- `GET /health`
- `GET /api/stories/:id/pack`

Socket namespace:

- `/socket`

Topic:

- `story:{story_id}`

Client event payload style:

```text
"event_name", %{"id" => uuid, "fields" => ...}
```

Server broadcast payload style:

```text
"generation_progress", %{"job_type" => "scene", "target_id" => uuid, "progress" => 0..100}
```

### 7.6 Asset Pipeline Implementation Details

1. Editor action emits generation event over channel.
2. Channel handler validates input and enqueues Oban job.
3. Worker calls external API.
4. Worker writes file to persistent disk path for story.
5. Worker updates corresponding DB row URL fields.
6. Worker emits completion/failure broadcast.
7. StoryPack assembly reads DB records and emits absolute asset URLs.
8. Reader consumes StoryPack and streams assets directly from Phoenix static path.

Word timings conversion guidance:

- Parse ElevenLabs character alignment arrays.
- Group characters by whitespace boundaries into words.
- Record word start/end ms and char start/end offsets.
- Build segment timeline and totalDurationMs.

### 7.7 Secrets Management and Environment Configuration

Store secrets in Render environment variables with `sync: false` and never in repository.

Required server secrets:

- `SECRET_KEY_BASE`
- `DATABASE_URL`
- `REDIS_URL`
- `PHX_HOST`
- `OPENAI_API_KEY`
- `ELEVENLABS_API_KEY`
- `SONAUTO_API_KEY`
- `RENDER_API_KEY`
- `INSTANT_APP_ID`

Required editor env vars:

- `VITE_API_WS_URL`
- `VITE_API_HTTP_URL`

Recommended operational policy:

- Rotate third-party API keys before filming week.
- Scope Render API token to least privilege needed for static site creation.
- Keep separate dev and prod keys.

### 7.8 Deployment Strategy Details

Render Blueprint (`render.yaml`) SHOULD define:

- `storytime-api` web service with migration and release commands.
- `storytime-editor` static site with rewrite rules.
- managed Postgres and key value resources.
- persistent disk mount for assets.

Deploy worker behavior SHOULD be:

1. Validate subdomain format.
2. Ensure story has minimum viable content.
3. Call Render API to create static site from reader template/repo.
4. Inject story source environment variable.
5. Poll Render deploy status until success/failure timeout.
6. Persist `render_site_id` and `deploy_url`.
7. Broadcast result to editor channel.

### 7.9 Suggested Repository Layout

```text
storytime/
  render.yaml
  mix.exs
  config/
  lib/storytime/
    stories/
    generation/
    workers/
    deploy/
  lib/storytime_web/
    endpoint.ex
    router.ex
    channels/
    controllers/
  priv/repo/migrations/
  editor/
  reader/
  test/
```

### 7.10 Alternatives Considered

Option A: Node/Express backend instead of Phoenix.
- Pros: Faster onboarding for JavaScript-heavy stack.
- Cons: More custom work for durable jobs and high-quality WebSocket flows.
- Rejected because: Phoenix + Oban + Channels gives tighter integrated primitives under time pressure.

Option B: Store assets in object storage instead of persistent disk.
- Pros: Better long-term scalability and CDN patterns.
- Cons: Added setup, credentials, and integration complexity.
- Rejected because: Persistent disk + Plug.Static is fastest path for challenge demo.

Option C: Build editor as chat-first AI UX.
- Pros: Closer to full IHS interaction model.
- Cons: Significant prompt engineering and action mediation complexity.
- Rejected because: Direct edit forms are more reliable inside 4 hours.

### 7.11 Decision Log (Tagged)

- DEC-001 [Decision Maker: Sean (Interview Plan)]
Choice: Phoenix 1.8 backend with Channels and Oban.
Rationale: Native real-time + durable jobs + Render compatibility.

- DEC-002 [Decision Maker: Sean (Interview Plan)]
Choice: Render Postgres + Render Key Value + Render Persistent Disk.
Rationale: Keep infra on sponsor platform and reduce integration risk.

- DEC-003 [Decision Maker: Sean (Interview Plan)]
Choice: Editor real-time through Phoenix Channels, not chat-agent control loop.
Rationale: Deterministic direct manipulation in live coding window.

- DEC-004 [Decision Maker: Sean (Interview Plan)]
Choice: Reader collaboration via InstantDB room model.
Rationale: Fast path to presence/page-sync/pointers without custom server state logic.

- DEC-005 [Decision Maker: Sean (Interview Plan)]
Choice: Segment-based WordTimings V2.
Rationale: Enables multi-voice dialogue timing and karaoke highlighting quality.

- DEC-006 [Decision Maker: Sean (Interview Plan)]
Choice: Anonymous ephemeral reader identity.
Rationale: Avoids auth scope and keeps co-reading setup instant.

- DEC-007 [Decision Maker: Sean (Interview Plan)]
Choice: Per-story deploy creates Render Static Site via API.
Rationale: Demo-friendly live publishing and URL shareability.

- DEC-008 [Decision Maker: Codex (Spec Assembly, 2026-02-24)]
Choice: Spec status set to RFC pending explicit approval signatures.
Rationale: Guide-compliant lifecycle state before formal sign-off.

- DEC-009 [Decision Maker: Sean + Codex (Spec Enrichment, 2026-02-24)]
Choice: Embed inline state-machine diagrams and dual-model mockup references directly beside FR anchors, with reader aesthetic updated to cozy Cotswold cottage language.
Rationale: Keep implementation behavior and intended visual states co-located in the normative spec for fast 4-hour build execution.

### 7.12 Full Tech Stack Matrix

```text
BACKEND
- Elixir 1.17+ (runtime language)
- Phoenix 1.8 (web framework, endpoint, router, channels)
- Ecto + Postgrex (database layer to Render Postgres)
- Oban 2.20+ (durable async job queue)
- Phoenix PubSub Redis adapter (Valkey-backed channel fanout)
- Req + Jason (HTTP clients and JSON handling for external APIs)
- CORSPlug (cross-origin support for reader)

FRONTEND (EDITOR)
- React 19
- TypeScript
- Vite
- Tailwind CSS
- phoenix npm client (WebSocket channel integration)

FRONTEND (READER)
- React 19
- TypeScript
- Vite
- Tailwind CSS
- @instantdb/react (presence/page sync/pointers)

PLATFORM AND INFRA
- Render Web Service (Phoenix API + workers)
- Render Static Site (editor)
- Render Static Site template (reader)
- Render per-story Static Sites (API-created)
- Render Managed Postgres
- Render Key Value (Valkey)
- Render Persistent Disk
- Render Blueprint (`render.yaml`)

EXTERNAL AI SERVICES
- OpenAI Images API (`gpt-image-1.5`) for scenes/headshots
- ElevenLabs TTS timestamps API for dialogue/narration + timings
- Sonauto generation API for background music
```

### 7.13 Render Platform Feature Mapping

```text
Render Feature: Blueprint
How Used: Single `render.yaml` defines API, editor, DB, key-value, env vars, and disk.

Render Feature: Web Service
How Used: Hosts Phoenix API, Channels, Oban workers, and /assets static serving.

Render Feature: Static Site
How Used: Hosts editor SPA and reader template/per-story reader deployments.

Render Feature: Managed Postgres
How Used: Canonical relational storage for stories, pages, dialogue, jobs, and deploy metadata.

Render Feature: Key Value (Valkey)
How Used: Phoenix PubSub Redis adapter for multi-process channel fanout.

Render Feature: Persistent Disk
How Used: Generated image/audio/music/story pack files at `/app/assets/{story_id}`.

Render Feature: Environment Variables
How Used: Secret injection for API keys and runtime URLs without repo commits.

Render Feature: API/Automation
How Used: Deploy worker creates per-story reader static sites with story-specific config.
```

### 7.14 4-Hour Build Execution Timeline

```text
BLOCK 1 (0:00-0:30)
- Verify skeleton app boots
- Run migrations
- Verify editor <-> channel connection

BLOCK 2 (0:30-1:30)
- Wire editor CRUD events and handlers
- Complete Story/Cast/Pages tabs
- Confirm DB round-trip for all CRUD mutations

BLOCK 3 (1:30-2:30)
- Implement ImageGen/TtsGen/MusicGen workers
- Hook generation queue UI to channel progress events
- Validate at least one successful run per asset type

BLOCK 4 (2:30-3:15)
- Implement StoryPack assembly endpoint
- Complete reader loading, page rendering, dialogue playback, word highlighting, music
- Validate collaboration hooks (presence/page sync/cursors)

BLOCK 5 (3:15-3:45)
- Implement deploy worker + Render API integration
- Run end-to-end create -> generate -> deploy -> read flow

BLOCK 6 (3:45-4:00)
- Visual polish and bug fixes
- Demo rehearsal and final smoke test
```

### 7.15 Demo Flow Script (3-5 Minutes)

```text
1. Open Storytime editor and create story "The Moonlit Garden".
2. Add two characters (Luna and Oliver) and generate headshots.
3. Add three pages with scene descriptions and dialogue.
4. Trigger Generate All scenes and show queue progress.
5. Trigger dialogue/narration generation and play one line in preview with word highlighting.
6. Deploy story to Render and show live URL.
7. Open reader on phone and laptop; show page sync and pointers.
8. Close with architecture walkthrough: Render Blueprint, Phoenix Channels, Oban workers, WordTimings V2.
```

### 7.16 Verification Checklist

```text
CHECK 1: Local Dev
- Run `mix phx.server`
- Run `cd editor && npm run dev`
- Confirm channel join + CRUD updates

CHECK 2: Generation
- Generate 1 headshot, 1 scene, 1 dialogue TTS
- Confirm files exist in `/app/assets/{story_id}/`
- Confirm URLs resolve through Phoenix static serving

CHECK 3: Render Deploy
- Push branch and let Blueprint deploy
- Confirm API/editor healthy
- Create story and deploy to per-story site

CHECK 4: Reader E2E
- Open deployed story
- Confirm page navigation, dialogue playback, word highlighting, and music

CHECK 5: Collaboration
- Open same story in two clients
- Confirm presence, page sync, and pointer sharing
```

### 7.17 Open for Engineering Decision

- Whether deploy worker passes StoryPack URL directly or story slug plus API base URL as reader env vars.
- Whether dialogue segment audio is concatenated server-side or sequenced client-side from segment metadata.
- Whether `generation_jobs` is physically persisted or derived from Oban state + channel events.

## 8. Metrics and Validation

```text
PRIMARY SUCCESS METRIC
Metric: End-to-end story publish success rate
Baseline: 0% (new build)
Target: >=90% successful create->generate->deploy cycles in rehearsal runs
Owner: Sean (Build Lead)

LEADING INDICATORS
Metric: Generation completion rate by type (scene, tts, music)
Target: >=95% scene, >=90% tts, >=70% music during rehearsal

Metric: Median deploy completion time
Target: <=60 seconds from deploy click to live URL

Metric: Reader playback quality
Target: Dialogue plays without fatal errors on >=95% generated lines

VALIDATION PLAN
T-24h (before filming): full dry run from empty DB to deployed story
T-12h: rotate and verify all API keys and Render API token scopes
T-4h: smoke test editor channel CRUD and one generation per asset type
T-1h: confirm fallback pre-generated demo story remains available
During build: run verification checklist after each block (CRUD, generation, deploy, reader, collaboration)
Post-build: run 2-device live demo check for page sync and cursor sharing
```

## 9. Risks, Assumptions, and Open Questions

```text
ASSUMPTIONS
A-01: Render services and managed datastores provision within acceptable setup time.
      Impact if wrong: Build time consumed by infra bring-up.
      Status: VALIDATING

A-02: OpenAI and ElevenLabs APIs are reachable and performant during filming.
      Impact if wrong: Generation delays reduce demo quality.
      Status: VALIDATING

A-03: Storytime can complete one full happy-path story within 4-hour coding window.
      Impact if wrong: Demo must rely on pre-generated backup story.
      Status: VALIDATING

RISKS
R-01: External GenAI API latency causes queue buildup.
      Probability: High
      Impact: High
      Mitigation: Pre-generate one backup story and keep Generate All optional for music.
      Owner: Sean

R-02: Render API deployment flow fails due token scope or API response changes.
      Probability: Medium
      Impact: High
      Mitigation: Dry-run deploy pipeline before filming; keep pre-deployed fallback story URL.
      Owner: Sean

R-03: Studio network instability breaks WebSocket reliability.
      Probability: Medium
      Impact: Medium
      Mitigation: Keep minimal HTTP fallback path for critical reads and refresh behavior.
      Owner: Sean

R-04: Sonauto generation exceeds practical demo timing.
      Probability: High
      Impact: Medium
      Mitigation: Treat music as optional for success; timeout after 2 minutes.
      Owner: Sean

R-05: Rate limits on ElevenLabs during repeated retries.
      Probability: Medium
      Impact: Medium
      Mitigation: Cache generated lines, avoid unnecessary regeneration.
      Owner: Sean

OPEN QUESTIONS
OQ-01: Should deploy worker create one reader service per story slug or reuse one service with dynamic path routing?
       Owner: Sean
       Due: 2026-02-24
       Status: RESOLVED - Per-story static site creation (matches build plan and demo narrative).

OQ-02: Should reader fetch /story.json directly or /api/stories/:id/pack via env-configured API URL?
       Owner: Engineering
       Due: 2026-02-24
       Status: RESOLVED - API pack endpoint is canonical, with env-configured story identifier.

OQ-03: Is editor authentication required for challenge judging?
       Owner: Product
       Due: 2026-02-24
       Status: RESOLVED - No editor auth in Day 1 scope.
```

## 10. Change History

```text
v1.0 (2026-02-24) - RFC
Author: Codex (for Sean)
Changes:
- Initial complete Storytime CodeTV specification
- Added full FR/NFR/AC contracts for editor, backend, generation, reader, deploy, and operations
- Added Render-first infrastructure and secrets strategy
- Added decision log with tagged decision makers
Approval: Pending

v0.1 (2026-02-24) - Draft Notes
Author: Sean (Interview build plan)
Changes:
- Established architecture, timeline, worker model, and demo flow foundations
Approval: N/A
```
