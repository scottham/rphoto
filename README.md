# RPhoto

RPhoto is an iOS app for semantic photo search using CLIP-family models.
Indexing, embedding generation, and similarity retrieval run entirely on-device via CoreML. The app makes no network requests.

## Features

- Natural-language search over your photo library.
- Multilingual queries — SigLIP2 is multilingual, so queries in Chinese, Japanese, etc. are encoded directly without translation.
- Persistent local embedding cache (SwiftData) for fast repeat searches.
- Model: **SigLIP2** — Google's `siglip2-base-patch32-256`, 6-bit palettized, 768-dim embeddings and 256K Gemma/SentencePiece vocabulary. (MobileCLIP2-S2 support is kept as disabled source only.)
- Top-K retrieval control (5 / 10 / 20 / 50 / 100).
- Cache inspector view for checking per-model embedding counts and clearing data.

## Retrieval Pipeline

1. Sync currently accessible `PHAsset` image IDs.
2. Restore cached embeddings from SwiftData.
3. Backfill missing image embeddings with the CoreML vision encoder, using only locally available full-quality photo data (iCloud-only photos are skipped).
4. Encode the raw query (any language) with the SentencePiece BPE tokenizer and CoreML text encoder.
5. Compute cosine similarity against indexed image embeddings.
6. Sort and display Top-K results, skipping photos that cannot be loaded locally.

Multilingual check (PyTorch FP32, 43 ImageNet classes, raw single-word queries): retrieval P@10 is 0.993 for English, 0.965 for Chinese, 0.956 for Japanese.

## Model Details

| Model | Image Size | Embedding Dim | Context Length | Precision | Weights |
|-------|-----------|---------------|----------------|-----------|---------|
| SigLIP2 (patch32-256) | 256×256 | 768 | 64 | 6-bit palettized | ~269 MB |

SigLIP2 notes:
- Input text is lowercased before tokenization (Gemma tokenizer requirement).
- `attention_mask` is never passed to the text encoder — SigLIP2 defaults to all-ones internally.
- Pad token ID is 0; EOS token ID is 1.

## Quick Start

1. Clone the repository.
2. Place CoreML `.mlpackage` weight files under `RPhoto/Models/`. The model structure files (`model.mlmodel`, `Manifest.json`) are tracked in git; only the large `weight.bin` files need to be added locally.
3. Open `RPhoto.xcworkspace` (or `RPhoto.xcodeproj`; there are no third-party dependencies) and run on Mac (Designed for iPad) or a physical iPhone/iPad.

## Notes

- iOS 26+ required.
- Do not use the iOS Simulator for validation in this project.
- When testing locally, prefer the Mac app path (Designed for iPad). If needed, use a physical iPhone/iPad.
- Model weight binaries are gitignored (`RPhoto/Models/**/weights/*.bin`).
- First launch requires photo library permission. Use **Sync Accessible Photos** after permission changes.
- The app is fully offline: no translation service, no reverse geocoding (photo location is shown as coordinates).
- Search is fully local. Photo loading is configured to avoid iCloud-triggered downloads (`PHImageRequestOptions.isNetworkAccessAllowed = false`).
- If a photo's full original is only in iCloud, it is not encoded; for display, the app uses whatever local representation is available (for example, a thumbnail).
- Privacy policy URL: `https://gist.github.com/scottham/43b16e9e73acb809e5c68263203201e6/raw/privacy_policy_rphoto.md`
- Local source for privacy policy content: `privacy_policy_rphoto.md`

## Acknowledgements

- [Apple MobileCLIP](https://github.com/apple/ml-mobileclip)
- [Google SigLIP2](https://huggingface.co/google/siglip2-base-patch32-256) (Apache License 2.0)
- Tokenizer base from [Hugging Face swift-coreml-transformers](https://github.com/huggingface/swift-coreml-transformers)
