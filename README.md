# RPhoto

RPhoto is an iOS app for semantic photo search using CLIP-family models.
Indexing, embedding generation, and similarity retrieval run entirely on-device via CoreML.

## Features

- Natural-language search over your photo library.
- Multilingual query support — select an input language and the app translates to English before search. The translation panel only appears when a language pack needs to be installed.
- Persistent local embedding cache (SwiftData) for fast repeat searches.
- Switchable model backends:
  - **MobileCLIP-S2** — compact, fast; good default.
  - **SigLIP2** (FP16) — Google's SigLIP2-base-patch16-224, higher capacity with 768-dim embeddings and 256K Gemma/SentencePiece vocabulary.
  - **TinyCLIP** — smallest footprint.
- Top-K retrieval control (5 / 10 / 20 / 50 / 100).
- Cache inspector view for checking per-model embedding counts and clearing data.

## Retrieval Pipeline

1. Sync currently accessible `PHAsset` image IDs.
2. Restore cached embeddings from SwiftData.
3. Backfill missing image embeddings with the selected CoreML vision encoder.
4. If the user-selected input language is not English, translate the query to English using Apple's Translation framework (iOS 18+). If the required language pack is not installed, search is blocked with guidance on which pack to download.
5. Encode the final English query with the corresponding tokenizer (OpenAI BPE for MobileCLIP/TinyCLIP, SentencePiece BPE for SigLIP2) and CoreML text encoder.
6. Compute cosine similarity against indexed image embeddings.
7. Sort and display Top-K results.

## Model Details

| Model | Image Size | Embedding Dim | Context Length | Precision | Weights |
|-------|-----------|---------------|----------------|-----------|---------|
| MobileCLIP-S2 | 256×256 | 512 | 77 | FP16 | ~189 MB |
| SigLIP2 | 224×224 | 768 | 64 | FP16 | ~715 MB |
| TinyCLIP | 224×224 | 512 | 77 | FP16 | ~220 MB |

SigLIP2 notes:
- Input text is lowercased before tokenization (Gemma tokenizer requirement).
- `attention_mask` is never passed to the text encoder — SigLIP2 defaults to all-ones internally.
- Pad token ID is 0; EOS token ID is 1.

## Quick Start

1. Clone the repository.
2. Place CoreML `.mlpackage` weight files under `RPhoto/Models/`. The model structure files (`model.mlmodel`, `Manifest.json`) are tracked in git; only the large `weight.bin` files need to be added locally.
3. Open `RPhoto.xcodeproj` and build for iOS 18+ (or Mac — Designed for iPad).

## Notes

- iOS 18+ required (Translation framework dependency).
- Model weight binaries are gitignored (`RPhoto/Models/**/weights/*.bin`).
- First launch requires photo library permission. Use **Sync Accessible Photos** after permission changes.
- On Mac (Designed for iPad), the Translation framework is bypassed — queries are sent directly in English, and the language picker is hidden.
- Search is fully local. Photos may fetch iCloud originals depending on library state.

## Acknowledgements

- [Apple MobileCLIP](https://github.com/apple/ml-mobileclip)
- [Google SigLIP2](https://huggingface.co/google/siglip2-base-patch16-224)
- Tokenizer base from [Hugging Face swift-coreml-transformers](https://github.com/huggingface/swift-coreml-transformers)
