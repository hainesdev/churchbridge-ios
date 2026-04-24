# ChurchBridge iOS Realtime Translation Plan

## Purpose

This document defines the next-phase plan for ChurchBridge realtime translation UX.

The immediate implementation focus is the iOS app. The plan also documents the server-side event model changes that will be needed to support the intended iOS experience, plus the web-breaking changes that must be addressed later when the web clients are updated.

The main product goals are:

- add a static bottom dock for live English translation
- reduce visually jarring rewrites in the main feed
- preserve the ability for the LLM to correct catastrophic STT and translation failures
- stop relying on destructive segment merges as the normal display behavior
- keep Google translation as a safe fallback when enrichment is late, rejected, or unavailable

## Product Direction

### What we want the user to feel

The app should feel live, but not chaotic.

- The bottom dock is the fast, provisional reading surface.
- The scrollable feed is the stable reading history.
- The user should not feel like lines are constantly disappearing, combining, or relocating.
- If the LLM fixes a serious error, the user should still receive the correction.

### Core display model

The system should operate with two display layers:

1. Live dock
   Shows the newest English in realtime.
   This is where provisional translation belongs.

2. Stable feed
   Shows committed translation rows that remain in place.
   Rows may be revised in place, but should not be destructively merged away during normal operation.

### Source-of-truth policy

- Google is the fast fallback path.
- LLM enrichment is the preferred stable path when it arrives in time and passes guardrails.
- If Google has already been committed to the feed and the LLM later produces a meaning-level correction, the feed row should still be revised.
- We are not using a "minor changes only" policy. Correctness wins over stability.
- We are using a "stable row identity" policy. Corrections happen in place.

## Problems In The Current Flow

### 1. The feed receives Google too early

Today the server emits a visible `translation` event immediately after Google sentence translation completes. The LLM then follows with `translation_update` or `caption_merge`.

That means:

- the first thing the user reads is often the Google text
- the LLM is forced into post-hoc correction mode
- the main feed visibly churns even when the discourse logic is correct

### 2. Merge behavior should be reserved for segmentation repair only

The current head-anchored merge logic is better than naive collapsing, but it still does this:

- one segment disappears
- another segment is rewritten
- the user sees a visible collapse of content they may have already read

This is acceptable only as a segmentation-repair fallback when the stream split at the wrong boundary.

### 3. The iOS "live" area is not truly docked

The app already has a partial/live card, but it is rendered inside the scrollable feed rather than as a fixed bottom dock.

That means:

- live text competes with committed history
- the provisional layer is not visually separated from the stable layer
- the feed cannot settle into a calmer reading surface

### 4. Realtime Spanish is not helping the primary mobile UX

For the current iOS phase, the right simplification is:

- do not show realtime Spanish in the live dock
- keep the experience English-first
- leave phrase-level English-to-Spanish reveal for a later phase

## Target UX

## Phase 1 UX: iOS-first

### Live dock

The live dock should:

- be fixed above the main control bar
- show live English only
- represent the best currently available translation for the active thought-in-progress
- be visually distinct from committed feed items
- tolerate rapid updates without feeling like feed history is changing

Recommended characteristics:

- larger text than metadata, smaller than the main reading headline if needed
- one active text surface, not multiple stacked provisional rows
- subtle live indicator
- no visible Spanish in this dock for now

### Stable feed

The main feed should:

- contain committed translation rows only
- keep stable row IDs
- allow in-place revision when better text arrives
- avoid deleting or absorbing rows during normal operation
- visually acknowledge a revision without causing reflow

Recommended revision treatment:

- brief highlight or glow
- optional "updated" styling that fades quickly
- no movement of the row's position
- no segment deletion as part of normal correction

## Recommended Event Model

This is the desired future event contract. We do not need to implement all of it at once, but this is the model the iOS work should aim toward.

### Stable Segment Identity

Stable segment identity is a hard requirement for the next backend phase.

Once a segment is created, that identity should remain canonical for the entire lifecycle of that spoken unit.

That means:

- provisional/live output may reference the segment before stable commit
- stable feed commit keeps the same segment identity
- later LLM corrections revise that same segment in place
- grouping must not destroy the underlying segment identity
- metadata must remain attached to the original segment, not whichever row happens to survive presentation logic

Why this matters:

- in-place revisions are only reliable when identity is stable
- verse attachment becomes simpler and safer
- future phrase-level alignment depends on persistent segment references
- diagnostics, replay, and cross-client consistency all improve

New rule:

- do not model thought completion as identity collapse
- model thought completion as grouping layered on top of stable segment IDs

Recommended canonical fields:

- `segment_id`
- `thought_group_id`
- `group_position`
- `group_state`

Migration note:

- `ts` may remain temporarily for compatibility
- `segment_id` should become the canonical field

### Event categories

#### 1. Live events

These drive the dock only.

- `live_translation`
- `live_translation_clear`

Example responsibilities:

- Google fragment updates
- Google sentence-level provisional output
- fast fallback text while enrichment is pending

#### 2. Feed commit events

These create stable history rows.

- `feed_commit`

Each committed row should have:

- stable `segment_id`
- optional legacy `ts` during migration
- `english`
- `spanish`
- metadata such as `translation_register`, `source_quality`, `paragraph_break`
- provenance fields such as `source = google | llm | fallback`

#### 3. Feed revision events

These revise existing committed rows in place.

- `feed_revision`

This is the preferred replacement for most current `translation_update` behavior.

A revision may be large. We are not restricting revisions to cosmetic edits.

Each revision should target:

- `segment_id`

not "the segment that survived a merge."

#### 4. Structural events

These are for metadata and future advanced presentation.

- `segment_metadata`
- `thought_group_started`
- `thought_group_updated`
- `thought_group_completed`

These allow discourse-aware grouping without forcing the UI to delete rows.

#### 5. Legacy compatibility events

Current clients depend on:

- `interim_translation`
- `translation`
- `translation_update`
- `caption_merge`

These should be treated as transitional until all clients migrate.
`caption_merge` should be emitted only for `reason = segmentation_repair`.

## Server Behavior Plan

## Desired server behavior

### Rule 1: provisional text should go to the dock first

Google fragment and sentence translation should feed the live dock immediately.

That means the fast path remains visible, but it is visually separated from stable history.

### Rule 2: stable feed commit should prefer enriched text

For a newly completed sentence:

1. emit or update `live_translation`
2. wait a short enrichment window
3. if enrichment succeeds and passes guardrails, emit `feed_commit` with enriched English
4. otherwise emit `feed_commit` with Google English

Recommended first-pass window:

- `400-900ms` for normal display-ready segments

This should be tuned from actual latency measurements.

### Rule 3: display-ready false segments remain provisional longer

If the segment is structurally incomplete or flagged for continuation:

- keep it in the live/provisional layer longer
- do not rush it into the stable feed unless timeout fallback requires it

This preserves the existing thought-completion value while reducing feed churn.

### Rule 4: later LLM corrections may still revise committed feed rows

If a committed Google row later receives a clearly better LLM result:

- emit `feed_revision`
- revise that row in place
- target the original `segment_id`

This is mandatory for catastrophic recovery cases.

### Rule 5: destructive merge should become segmentation-repair-only

`caption_merge` should no longer be the normal user-facing mechanism.
It should exist only to repair a bad split in the caption stream.

Instead:

- preserve row identity whenever possible
- expose discourse grouping through metadata
- reserve true merge/collapse behavior for segmentation-repair cases only

### Rule 6: metadata should attach by original segment identity

Verse metadata, diagnostics, provenance, and future phrase-alignment metadata should attach by `segment_id`.

Clients may choose to visually group segments, but the underlying data model should remain per-segment.

## Server implementation changes

These are the likely backend changes needed later.

### LLM enrichment service

In `server/services/llm_enrichment_service.py`:

- keep `display_ready`, `continuation_required`, and quality gating
- keep guardrails that reject risky reconstructions
- stop optimizing primarily for `caption_merge`
- begin optimizing for:
  - commit timing
  - stable segment identity
  - stable row revision
  - thought grouping metadata

Potential additions:

- `segment_id`
- `preferred_commit_text`
- `commit_ready`
- `thought_group_id`
- `group_position`
- `group_state`
- `revision_reason`
- `revision_severity`

### Session manager

In `server/services/session_manager.py`:

- split dock-facing provisional events from feed-facing commit events
- stop assuming `translation` means "visible committed row"
- introduce a delayed commit coordinator
- preserve existing fallback behavior if enrichment fails
- ensure all outgoing events preserve original segment identity

### Google translation service

In `server/services/google_translate_service.py`:

- keep fast fragment translation for live responsiveness
- route fast-path output to dock/live events
- stop assuming fragment and sentence Google output should both directly shape stable history

## iOS Implementation Plan

## Scope for this phase

This phase focuses on the iOS app only.

Goals:

- add the static bottom live dock
- separate dock state from committed feed state
- prepare the iOS client to consume a future split event model
- improve the current behavior even before the backend contract fully changes

## iOS architecture changes

### 1. Split display state into provisional vs committed

In `ChurchBridgeTranslation/Models.swift` and `ChurchBridgeTranslation/DisplayFeedStore.swift`:

- replace the current loose `partialEnglish` role with an explicit live dock model
- keep committed segments independent from dock state

Suggested state shape:

- `liveEnglish`
- `liveEnglishSource`
- `liveUpdatedAt`
- `segments`
- `flashingID`
- `lastCommittedEnglish`

For now, `partialSpanish` and rolling Spanish lines can remain internally if still useful for diagnostics, but they should not drive the main iOS reader UI.

### 2. Add a fixed bottom dock

In `ChurchBridgeTranslation/TranslationTestView.swift`:

- move the current `partialCard` out of the scroll content
- render a dedicated live dock using `safeAreaInset(edge: .bottom)`
- place it above the existing control bar

Structure should become:

- top: navigation and status
- center: stable feed
- bottom inset 1: live translation dock
- bottom inset 2: main control bar

### 3. Keep stable feed rows visually calm

Feed rows should:

- remain in the same order
- receive in-place text updates when needed
- show subtle revision feedback

Do not:

- remove rows during normal correction
- absorb one committed row into another as a normal flow

### 4. Continue supporting current events during transition

Before the server contract changes, the iOS client should interpret current events in a more dock-aware way.

Transitional mapping:

- `interim_translation` -> live dock
- `translation` -> committed row, but may later be revised
- `translation_update` -> in-place row revision
- `caption_merge` -> temporary compatibility path only

### 5. Prepare for future event names without requiring them immediately

The iOS store should be written so it can later accept:

- `live_translation`
- `feed_commit`
- `feed_revision`

without another structural rewrite.

## iOS work sequence

### Step 1. Introduce explicit live-dock state

Update models and store so the dock has its own state instead of piggybacking on feed rendering.

Deliverable:

- the app can render live text independently from feed rows

### Step 2. Move live card into a true dock

Rework `TranslationTestView` so the dock is fixed and the feed scrolls independently.

Deliverable:

- live text remains visible while the user scrolls history

### Step 3. Refine feed revision treatment

Keep current update logic, but make revisions feel intentional rather than disruptive.

Deliverable:

- revised rows highlight in place without reordering

### Step 4. Reduce dependence on visible Spanish in the reader

Keep Spanish out of the dock for now. Leave committed Spanish as optional secondary information in the feed.

Deliverable:

- cleaner English-first mobile reading experience

### Step 5. Add compatibility seams for future server events

Make the store accept both old and new event families during migration.

Deliverable:

- iOS can be migrated incrementally as backend work lands

## Breaking Changes And Web Impact

The following changes will affect the web clients when the server contract is updated.

These are not for the current implementation phase, but they must be documented now so the later web work is straightforward.

## Breaking change 1: `translation` can no longer be assumed to mean stable visible history

Current web code assumes:

- `translation` creates a committed row
- `translation_update` revises it
- `caption_merge` may remove a row

Future contract direction:

- `live_translation` drives provisional display
- `feed_commit` creates stable history
- `feed_revision` updates stable history in place

Impact on web:

- `client/lib/useTranslationFeed.ts` must separate live state from committed state
- `client/components/TranslationDisplay.tsx` must stop treating partial/live text as just another feed-adjacent block

## Breaking change 2: `caption_merge` should stop being a primary rendering path

Current web feed explicitly removes absorbed segments on `caption_merge`.

Future direction:

- preserve row identity by `segment_id`
- use group metadata rather than destructive collapse

Impact on web:

- merge-routing helpers will need redesign
- verse attachment logic should target stable segment IDs rather than "whichever row survived the merge"

## Breaking change 3: provisional English should move into a dedicated surface

The current web full-mode UI only partially exposes realtime English, and bilingual mode treats live Spanish/English as rolling parallel text.

Future direction:

- distinct provisional live zone
- distinct stable history zone

Impact on web:

- all display modes will need UX decisions
- lower-third behavior may remain more aggressive and simpler than full/mobile-reader behavior

## Breaking change 4: metadata may describe thought groups instead of forcing collapsed rows

If the server begins emitting thought-group metadata:

- web code should not assume every discourse connection becomes a merge
- clients should be able to visually group related segments without deleting them

## Web follow-up tasks

Later, the web update should include:

- refactor `useTranslationFeed.ts` around provisional vs committed state
- key rows and metadata by `segment_id`
- redesign `TranslationDisplay.tsx` full mode to include a stable live zone
- reevaluate bilingual mode once phrase-level alignment is introduced
- preserve lower-third simplicity where appropriate

## Backend Migration Checklist For Stable IDs

### Stage 1. Introduce canonical segment IDs alongside legacy ts

- add `segment_id` to outgoing translation, revision, metadata, and verse events
- keep `ts` temporarily for compatibility
- include both in diagnostics and logs

Success condition:

- clients can migrate to `segment_id` without breaking current flows

### Stage 2. Move revisions and metadata to segment-based targeting

- `translation_update` or future `feed_revision` should target `segment_id`
- verse and metadata events should attach by `segment_id`

Success condition:

- clients no longer depend on merge-survivor remapping

### Stage 3. Convert merge semantics into grouping semantics

- introduce `thought_group_id`
- preserve per-segment identity
- emit grouping metadata instead of destructive caption merge for the normal path
- keep `caption_merge` only for `segmentation_repair`

Success condition:

- discourse completion no longer requires deleting segment identity

### Stage 4. Split provisional vs committed event families

- add `live_translation`
- add `feed_commit`
- add `feed_revision`
- add `live_translation_clear`

Success condition:

- dock/live state and stable feed state are cleanly separated

### Stage 5. Deprecate merge-first client behavior

- retain `caption_merge` only as exceptional `segmentation_repair` compatibility behavior
- stop using merge as the primary path for meaning completion

Success condition:

- clients render stable history using persistent segment identities

## Phrase-Level English To Spanish Reveal

This is not part of the immediate iOS phase, but it is the best next major UX improvement after the live dock and stable feed work.

### Future goal

Rather than showing full Spanish live text, allow users to:

- read English normally
- tap an English word or phrase
- reveal the linked Spanish source phrase

### Why this matters

This is more useful than showing both languages at once because it:

- reduces clutter
- supports comprehension
- teaches the connection between languages
- uses the LLM for explainability rather than just polish

### Future dependency

This feature will work best after:

- stable segment IDs exist
- feed revisions are in place
- the event contract can carry phrase alignment metadata

## Risks

### Risk 1: waiting too long before feed commit

If the enrichment window is too long:

- the feed feels sluggish
- users may rely only on the dock

Mitigation:

- start with a short window
- tune using measured latency

### Risk 2: late LLM revisions still feel disruptive

Even with stable row IDs, a large rewrite may surprise the user.

Mitigation:

- use in-place visual acknowledgment
- avoid row movement
- keep the live dock as the "already moving" area

### Risk 3: mixed old/new event contracts during migration

During rollout, some clients may expect legacy events while newer clients want split live/commit events.

Mitigation:

- support legacy and next-gen events in parallel during migration
- migrate iOS first
- update web after the contract stabilizes

## Success Criteria

This phase is successful when:

- iOS has a true fixed live English dock
- the feed feels calmer and more readable
- committed rows can still be corrected in place
- catastrophic LLM fixes remain visible to the user
- the codebase is ready for a future split event model
- the future web breakages are clearly documented before backend changes land

## Immediate Next Actions

### iOS now

1. Add explicit live-dock state in the display models and store.
2. Move provisional translation UI into a fixed bottom dock.
3. Keep feed rows stable and revise them in place.
4. Leave realtime Spanish out of the dock for this phase.

### Backend later

1. Introduce provisional live events vs stable feed events.
2. Delay feed commit briefly to prefer enriched text.
3. Replace merge-first rendering with stable row revision and thought-group metadata.

### Web later

1. Refactor feed state around provisional vs committed layers.
2. Stop assuming `translation` always means stable history.
3. Remove `caption_merge` as the primary rendering strategy.

## Next Backend Phase

This is the recommended next implementation phase after the iOS dock and stable-ID groundwork.

The goal of this phase is to make the event contract match the intended product model.

### Objectives

- separate provisional live text from stable feed history
- preserve stable `segment_id` through the entire pipeline
- make LLM-enriched text the preferred feed commit when it arrives in time
- keep Google as a safe fallback
- use grouping metadata instead of merge-first display behavior
- reserve `caption_merge` strictly for segmentation repair

### Phase outcome

By the end of this phase:

- the dock should be driven by explicit live events
- stable feed rows should be driven by explicit commit events
- revisions should target committed rows directly by `segment_id`
- grouping should be represented as metadata instead of destructive collapse

## Proposed Event Contract

This is the target shape for the next event family.

### 1. `live_translation`

Purpose:

- drive the provisional dock
- represent the best currently available text for the active segment or active thought-in-progress

Recommended payload:

```json
{
  "type": "live_translation",
  "segment_id": 1234567890,
  "ts": 1234567890,
  "text": "And if we walk in the light...",
  "source": "google_fragment",
  "display_ready": false
}
```

Notes:

- `segment_id` should be present even if the text is still provisional
- `source` helps diagnostics and future UX decisions
- `display_ready` allows clients to know whether the text is likely to become a stable row soon

### 2. `live_translation_clear`

Purpose:

- clear the provisional dock when the active live text has been committed or invalidated

Recommended payload:

```json
{
  "type": "live_translation_clear",
  "segment_id": 1234567890,
  "ts": 1234567890,
  "reason": "committed"
}
```

Recommended reasons:

- `committed`
- `superseded`
- `timeout`
- `segmentation_repair`

### 3. `feed_commit`

Purpose:

- create a stable feed row

Recommended payload:

```json
{
  "type": "feed_commit",
  "segment_id": 1234567890,
  "ts": 1234567890,
  "spanish": "Si andamos en luz...",
  "english": "If we walk in the light...",
  "source": "llm",
  "translation_register": "scripture",
  "source_quality": "clean",
  "paragraph_break": false
}
```

Notes:

- `source` should be one of `llm`, `google`, or `fallback`
- if a segment reaches stable history through fallback, that should be explicit

### 4. `feed_revision`

Purpose:

- revise a stable feed row in place

Recommended payload:

```json
{
  "type": "feed_revision",
  "segment_id": 1234567890,
  "ts": 1234567890,
  "english": "If we walk in the light as he himself is in the light...",
  "source": "llm",
  "reason": "meaning_correction"
}
```

Recommended reasons:

- `meaning_correction`
- `scripture_fidelity`
- `deferred_release`
- `context_repair`
- `segmentation_repair`

### 5. `segment_metadata`

Purpose:

- attach stable per-segment metadata without creating or revising rows directly

Recommended payload:

```json
{
  "type": "segment_metadata",
  "segment_id": 1234567890,
  "ts": 1234567890,
  "translation_register": "scripture",
  "paragraph_break": false,
  "source_quality": "clean",
  "pending_completion": false,
  "terminal_incomplete": false,
  "thought_group_id": "tg-1234567890-a",
  "group_position": "single",
  "group_state": "finalized"
}
```

### 6. `thought_group_*`

Purpose:

- express that multiple stable segments belong to one completed thought without collapsing identity

Suggested event family:

- `thought_group_started`
- `thought_group_updated`
- `thought_group_completed`

This can be deferred if `segment_metadata` is enough initially, but it is the right long-term direction.

### 7. `caption_merge`

Purpose:

- segmentation repair only

Required payload rule:

```json
{
  "type": "caption_merge",
  "reason": "segmentation_repair",
  "segment_id_keep": 1234567890,
  "segment_id_absorb": 1234567891,
  "ts_keep": 1234567890,
  "ts_absorb": 1234567891,
  "spanish": "...",
  "english": "..."
}
```

If the event is emitted for any reason other than `segmentation_repair`, that is a contract violation.

## Rollout Sequence

The safest rollout is progressive and additive.

### Stage A. Emit canonical IDs everywhere

Status:

- partially complete

Needed:

- ensure all relevant events carry `segment_id`
- keep legacy `ts` for migration

Acceptance criteria:

- iOS can resolve rows and metadata using `segment_id`
- legacy clients still work unchanged

### Stage B. Add new event names alongside legacy ones

Needed:

- emit `live_translation`
- emit `live_translation_clear`
- emit `feed_commit`
- emit `feed_revision`

During this stage:

- keep emitting legacy events for compatibility
- map both families in iOS and later in web

Acceptance criteria:

- new clients can be built against the future contract before legacy removal

### Stage C. Move commit timing logic to the new contract

Needed:

- dock receives fast provisional text immediately
- feed waits briefly for enrichment
- enriched commit wins when timely and valid
- Google fallback commits when enrichment misses the window

Acceptance criteria:

- most stable feed rows come in as the desired text on first commit
- late revisions still work for catastrophic corrections

### Stage D. Introduce grouping metadata

Needed:

- represent completed-thought relationships with `thought_group_id`
- stop depending on merge to express thought completion

Acceptance criteria:

- connected thoughts can be recognized without collapsing identity

### Stage E. Restrict merge to segmentation repair only

Needed:

- preserve `caption_merge` for stream repair only
- remove merge-first assumptions from all clients

Acceptance criteria:

- discourse-aware continuity no longer depends on merge
- merge volume becomes low and explainable

## Backend Acceptance Criteria

The backend migration should be considered successful when all of the following are true:

- every committed segment has a stable `segment_id`
- live dock text can be driven entirely by explicit live events
- stable feed rows can be created entirely by explicit commit events
- revisions always target committed rows by `segment_id`
- verse metadata attaches by `segment_id`
- `caption_merge` events always include `reason = segmentation_repair`
- stable reading history no longer depends on merge-survivor logic

## Web Migration Checklist

When the backend phase begins, the web work should be tracked explicitly as a follow-on migration.

### `useTranslationFeed.ts`

Must be updated to:

- maintain separate provisional and committed state
- key feed rows by `segment_id`
- attach verse metadata by `segment_id`
- treat `caption_merge` as segmentation repair only

### `TranslationDisplay.tsx`

Must be updated to:

- add a dedicated live zone
- stop treating provisional text as feed-adjacent by default
- stop assuming `translation` always creates stable history
- avoid merge-survivor rendering assumptions

### Lower-third mode

Lower-third mode may remain simpler than full reader mode, but it should still:

- prefer stable IDs
- treat merge as segmentation repair only
- avoid normal-flow destructive collapse where possible

## Open Questions For The Next Pass

These questions should be answered before or during the next backend phase.

1. What is the initial enrichment wait window for `feed_commit`?
2. Should `live_translation` be segment-scoped or thought-scoped when multiple partials are in play?
3. Do we want `source` provenance on all commit and revision events from the start?
4. Do we want `revision_reason` exposed to clients immediately, or only logged first?
5. Should `thought_group_id` be emitted in `segment_metadata` first before adding dedicated group events?

## Recommended Answer Defaults

Unless testing suggests otherwise:

1. Start with a `700ms` enrichment wait window.
2. Keep `live_translation` segment-scoped at first.
3. Include `source` on commit and revision events immediately.
4. Include `reason` on revision and merge events immediately.
5. Start with `thought_group_id` in `segment_metadata` before creating a new event family.

## Legacy Bridge Rules

The next backend phase should be additive before it becomes replacement-based.

That means:

- keep legacy events during the migration window
- emit new events in parallel where possible
- keep `segment_id` canonical even when legacy `ts` is still present
- keep iOS and web able to consume either family until rollout is complete

### Canonical interpretation during migration

Until legacy events are retired, clients should interpret them as follows:

- `interim_translation` means dock-only provisional content
- `translation` means legacy stable commit behavior
- `translation_update` means legacy revision behavior
- `caption_merge` means segmentation repair only

New events should map like this:

- `live_translation` replaces the provisional role of `interim_translation`
- `live_translation_clear` explicitly ends dock state
- `feed_commit` replaces the stable-history role of `translation`
- `feed_revision` replaces the stable-row revision role of `translation_update`

### Temporary server emission policy

During the first additive rollout:

- continue emitting legacy events for compatibility
- emit new events in parallel for iOS and future web migration
- keep payload content semantically aligned across both families
- do not let legacy merge behavior contradict the new segmentation-repair-only rule

Success condition:

- new clients can switch to the new event family without requiring a simultaneous backend cutover

Update:

- the server has now moved past the additive bridge for the public translation contract
- iOS should treat the new event family as the primary contract
- web follow-up work is documented in `C:\Users\Dan\Desktop\Projects\churchbridge-ai\client\WEB_CLIENT_MIGRATION.md`

## LLM Processing Changes For The Next Pass

The next server phase is not just an event rename. The LLM decision layer needs to target the new display model directly.

### Current LLM responsibility

Today the LLM step is mainly deciding:

- improved English
- whether the segment is display-ready
- whether the segment should merge with the previous segment

That is too merge-oriented for the intended product behavior.

### Target LLM responsibility

The LLM step should shift toward deciding:

- best English for provisional display
- best English for stable commit
- whether the current segment is commit-ready
- whether a later revision is needed
- whether the relationship to nearby segments is grouping rather than merge
- whether segmentation is actually wrong enough to require repair

### Recommended next output shape

The internal LLM result should begin moving toward fields like:

- `segment_id`
- `preferred_live_text`
- `preferred_commit_text`
- `commit_ready`
- `revision_reason`
- `thought_group_id`
- `group_position`
- `group_state`
- `segmentation_repair_required`

Notes:

- `segmentation_repair_required` is the narrow replacement for broad merge intent
- a segment may be grouped with a neighboring segment without losing its identity
- `preferred_live_text` and `preferred_commit_text` may be the same string at first

### Hard rule for segmentation repair

`caption_merge` is allowed only when the model concludes that the caption stream split at the wrong boundary.

This does not include:

- normal continuation of a thought across adjacent captions
- rhetorical setup followed by answer
- quote introduction followed by quote
- a stylistic preference for one longer English sentence

This does include cases like:

- the first segment was clearly an accidental fragment caused by timing
- punctuation or timing produced a split that breaks the actual sentence structure
- the second segment cannot stand on its own because the previous split was invalid

## Implementation Checklist By File

This section turns the backend phase into a concrete engineering checklist.

### `server/services/llm_enrichment_service.py`

Needed next:

- keep stable `segment_id` in the enrichment pipeline
- narrow merge decisions into segmentation-repair decisions
- produce commit-oriented outputs rather than merge-oriented outputs
- add `revision_reason` and `source` metadata where available
- prefer grouping metadata over merge intent for normal discourse continuity

Acceptance criteria:

- normal continuation no longer produces merge intent
- segmentation repair is rare and explainable
- the enrichment result can drive `feed_commit` and `feed_revision` directly

### `server/services/session_manager.py`

Needed next:

- emit `live_translation` when provisional English changes
- emit `live_translation_clear` when provisional text is committed or invalidated
- emit `feed_commit` for stable rows
- emit `feed_revision` for in-place corrections
- keep legacy events in parallel during migration
- ensure every event carries canonical `segment_id`

Acceptance criteria:

- iOS can run entirely off the new event family
- legacy clients continue to function during migration
- no event path depends on merge-survivor identity

### `server/services/google_translate_service.py`

Needed next:

- continue producing fast fragment and sentence translations
- route fast-path text into live-event behavior rather than assuming stable-history behavior
- avoid shaping committed history directly when enrichment is expected shortly after

Acceptance criteria:

- Google remains the responsiveness fallback
- Google output no longer defines the stable feed too early by default

### `client/lib/useTranslationFeed.ts`

Needed later:

- split provisional state from committed state
- key all stable rows by `segment_id`
- attach metadata and verse references by `segment_id`
- treat `caption_merge` as segmentation repair only

### `client/components/TranslationDisplay.tsx`

Needed later:

- add a dedicated live zone
- stop assuming `translation` always means stable history
- stop using merge-collapse as the normal display path

## Non-Negotiable Invariants

The next implementation phase should preserve these rules at all times:

- stable row identity is never transferred because of normal thought completion
- committed rows are revised in place by `segment_id`
- `caption_merge` is never used for ordinary discourse continuity
- catastrophic corrections are allowed even after commit
- provisional and committed display layers remain conceptually separate
- metadata always attaches to the original segment identity

If a proposed backend shortcut violates one of these rules, it should be treated as a regression rather than a simplification.
