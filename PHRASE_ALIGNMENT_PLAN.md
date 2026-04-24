# Phrase Alignment Plan

## Goal

Turn stable English translation rows into an interactive reading aid:

- keep live translation fast and plain
- keep stable segment identity unchanged
- attach phrase-level English-to-Spanish mappings to committed segments
- let the user tap English to reveal the linked Spanish phrase

This is the next product step after the live dock and stable feed work.

## Product Shape

There are now two different reading surfaces:

1. Live dock
- plain English only
- provisional
- no phrase mapping UI

2. Stable feed
- committed or revised English
- optional phrase alignment metadata
- English is tappable when alignment is present
- full Spanish sentence is hidden on aligned rows and replaced by reveal-on-tap behavior

## Contract

Stable segment events may carry:

```json
"phrase_alignment": [
  {
    "english_text": "If we walk in the light",
    "spanish_text": "Si andamos en luz"
  },
  {
    "english_text": "we have fellowship",
    "spanish_text": "tenemos comunión"
  }
]
```

Rules:

- alignment is optional
- alignment belongs to a stable `segment_id`
- `feed_commit` may include alignment
- `feed_revision` may replace alignment
- if alignment is absent, clients fall back to plain English plus full Spanish
- `caption_merge` clears alignment because segmentation repair invalidates old phrase links

## Backend Behavior

The backend remains responsible for validating alignment before it reaches clients.

Current validation:

- only accepts ordered lists of objects
- requires non-empty English and Spanish text per item
- requires at least 2 items
- drops alignment if the combined English does not roughly match the displayed English

That keeps phrase mapping from surfacing obviously wrong links after a noisy LLM response.

## iOS Implementation

Files:

- `ChurchBridgeTranslation/Models.swift`
- `ChurchBridgeTranslation/DisplayFeedStore.swift`
- `ChurchBridgeTranslation/TranslationTestView.swift`

Behavior:

- `TranslationSegment` stores `[PhraseAlignment]`
- `feed_commit` stores alignment on the segment
- `feed_revision` replaces alignment when provided
- aligned rows render tappable English phrase chips
- tapping a chip reveals only the linked Spanish phrase
- verse access stays available through verse pills instead of whole-card tap

## Web Implementation

Files:

- `client/lib/useTranslationFeed.ts`
- `client/components/TranslationDisplay.tsx`

Behavior:

- feed state stores optional `phraseAlignment`
- aligned rows render tappable English phrase chips
- the stable feed hides full Spanish on aligned rows in the main reading mode
- tapping a chip reveals the mapped Spanish phrase inline

## Remaining Follow-Up

Still to improve after this step:

- better phrase grouping for long sentences
- optional provenance or confidence metadata per aligned segment
- richer alignment UI on iOS than chip-based grouping
- possible bilingual-mode refinement on web if we want a dedicated “mapping-first” bilingual presentation
- end-to-end live-session verification against production-like traffic
