# RPhoto

RPhoto is an iOS app for local semantic photo search using MobileCLIP.  
All indexing and retrieval run on-device.

## What It Does

- Search your photo library with natural language.
- Cache image embeddings locally for faster repeat use.
- Switch between different MobileCLIP model variants.
- Keep user data local (no cloud inference).

## Quick Start

1. Install tools:
   ```bash
   brew install xcodegen
   ```
2. Download MobileCLIP CoreML `.mlpackage` models and place them in:
   `RPhoto/Models/`
3. Generate the Xcode project:
   ```bash
   xcodegen generate
   ```
4. Open `RPhoto.xcodeproj` and run.

## Notes

- iOS 17+ is required.
- Model weight binaries are kept local and are not tracked in this repo.
- On first launch, grant photo permission.  
  Use `Sync Accessible Photos` to analyze newly accessible photos.

## Acknowledgements

Built on Apple MobileCLIP resources and sample code:
[apple/ml-mobileclip](https://github.com/apple/ml-mobileclip)
