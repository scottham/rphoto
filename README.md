# RPhoto

RPhoto is an iOS app for semantic photo search using CLIP-family models.
Indexing, embedding generation, and similarity retrieval run entirely on-device via CoreML.

## Features

- Natural-language search over your photo library.
- Multilingual query support — select an input language and the app translates to English before search using Google ML Kit Translation.
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
3. Backfill missing image embeddings with the selected CoreML vision encoder, using only locally available photo data (including local thumbnails when full originals are not on-device).
4. If the user-selected input language is not English, the app checks ML Kit model availability. If missing, it prompts to download the model on demand, then translates to English and continues search.
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
3. Install dependencies with `pod install`.
4. Open `RPhoto.xcworkspace` and build for iOS 18+ (or Mac — Designed for iPad).

## Notes

- iOS 18+ required.
- CocoaPods is required for `GoogleMLKit/Translate`.
- Translation has a single implementation path on iOS 18+ and Mac (Designed for iPad); there is no longer an iOS-version split branch.
- Model weight binaries are gitignored (`RPhoto/Models/**/weights/*.bin`).
- First launch requires photo library permission. Use **Sync Accessible Photos** after permission changes.
- Non-English translation models are downloaded on demand, then usable offline.
- On Mac (Designed for iPad), translation uses the same ML Kit path as iPhone/iPad.
- Search is fully local. Photo loading is configured to avoid iCloud-triggered downloads (`PHImageRequestOptions.isNetworkAccessAllowed = false`).
- If a photo's full original is only in iCloud, the app uses whatever local representation is available (for example, thumbnail/degraded image) for encoding and display.

## Acknowledgements

- [Apple MobileCLIP](https://github.com/apple/ml-mobileclip)
- [Google SigLIP2](https://huggingface.co/google/siglip2-base-patch16-224)
- Tokenizer base from [Hugging Face swift-coreml-transformers](https://github.com/huggingface/swift-coreml-transformers)
