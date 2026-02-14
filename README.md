# RPhoto

RPhoto is an iOS app for semantic photo search using CLIP-family models (MobileCLIP + TinyCLIP).
Indexing, embedding generation, and similarity retrieval run on-device.

## Features

- Natural-language search over your photo library.
- Manual input-language selection with translation-to-English preprocessing before CLIP search.
- Persistent local embedding cache for faster repeat search.
- Switchable model backends:
  - `MobileCLIP-S2`
  - `MobileCLIP-BLT`
  - `TinyCLIP`
- Top-K retrieval control (5/10/20/50/100).

## Retrieval Pipeline

1. Sync currently accessible `PHAsset` image IDs.
2. Restore cached embeddings from SwiftData.
3. Backfill missing image embeddings with CoreML image encoder.
4. For iOS 18+, use the user-selected input language (default English), then translate to English using Apple's Translation engine when needed.
5. Encode final English query text with CLIP tokenizer + CoreML text encoder.
6. Compute cosine similarity against indexed image embeddings.
7. Sort and display Top-K results.

## Recent Stability and Performance Improvements

- Fixed long-query crash risk by clipping token count to CLIP context length.
- Reduced search CPU cost:
  - normalize embeddings once at load/encode time
  - use dot-product on normalized vectors for scoring
- Reduced runtime memory:
  - keep only currently displayed result thumbnails in memory
  - clear thumbnail cache when query is cleared
- Removed an unused photo-loading code path in `GalleryManager`.
- Added multilingual search pipeline with detailed translation diagnostics in UI.

## Quick Start

1. Install tooling:
   ```bash
   brew install xcodegen
   ```
2. Place CoreML `.mlpackage` model folders under `RPhoto/Models/`.
3. Generate project:
   ```bash
   xcodegen generate
   ```
4. Open `RPhoto.xcodeproj` and run on iOS 18+.

## Notes

- iOS 18+ required.
- Model weight binaries are intentionally not tracked (`RPhoto/Models/**/weights/*.bin` is gitignored).
- First launch requires photo permission. Use `Sync Accessible Photos` after permission changes.
- Search inference is local. Depending on library state, Photos may fetch iCloud originals; metadata reverse geocoding may also require network.
- Query input language is user-selectable in the search bar and persisted across app launches.
- If translation resources are missing for the selected source language to English, search is blocked and the app prompts users to download language packs in Apple's Translate app.

## Acknowledgements

- Apple MobileCLIP resources: [apple/ml-mobileclip](https://github.com/apple/ml-mobileclip)
- Tokenizer base from Hugging Face swift-coreml-transformers
