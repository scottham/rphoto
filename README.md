# RPhoto

**RPhoto** is an intelligent photo gallery search application built for iOS, powered by Apple's **MobileCLIP** models. It demonstrates how to perform efficient, on-device Zero-Shot Image Retrieval, allowing you to search your photo library using natural language queries without sending any data to the cloud.

## Features

- **Semantic Search**: Find photos using natural language (e.g., "sleeping cat", "birthday cake", "sunset at beach").
- **Privacy First**: All machine learning inference runs 100% on-device. Your photos never leave your phone.
- **Multiple Models**: Switch between different MobileCLIP architectures (S0, S1, S2, B-LT) to balance performance and latency.
- **Efficient Caching**: Image embeddings are cached using SwiftData for instant subsequent searches.
- **Top-K Filtering**: Customize your search results by filtering for the top 5, 10, 20, or more matches.

## Requirements

- **iOS 17.0** or later.
- Xcode 15 or later.

## Setup & Installation

1. **Download Models**
   Download the required CoreML models from the [Hugging Face repository](https://huggingface.co/apple/coreml-mobileclip).

2. **Add Models to Project**
   Place the downloaded `.mlpackage` folders in the following directory:
   `ios_app/RPhoto/Models/`

   *Ensure you have models like `mobileclip_s2_image.mlpackage`, etc.*

3. **Generate Project**
   This project uses `xcodegen` to manage the Xcode project file.
   ```bash
   brew install xcodegen
   xcodegen generate
   ```

4. **Build and Run**
   Open `RPhoto.xcodeproj` and run on a device or simulator.

## Usage

1. **Import Photos**: Tap the `+` button to select photos from your library to index.
2. **Search**: Enter a text query in the search bar.
3. **Explore**: View results ranked by similarity score. Tap on an image to see details.
4. **Manage Cache**: Use the debug menu to view or clear cached embeddings.

## Benchmarks (MobileCLIP)

The application supports standard MobileCLIP variants:

| Model | Latency (est) | Accuracy (IN-1k) | Description |
|-------|---------------|------------------|-------------|
| **S0** | ~2.1 ms | 67.8% | Fastest, ultra-lightweight. |
| **S1** | ~5.8 ms | 72.6% | Balanced speed/accuracy. |
| **S2** | ~6.9 ms | 74.4% | Recommended default. |
| **B-LT**| ~13.7 ms | 77.2% | High accuracy, larger model. |

## Acknowledgements

This project is based on the [MobileCLIP](https://github.com/apple/ml-mobileclip) sample code provided by Apple.

- **Original Copyright**: Copyright (C) 2024 Apple Inc. All Rights Reserved.
- **Modifications**: Modified by individual developer to transform the real-time camera classification sample into a gallery search application.

Please see the `LICENSE` file for full licensing details.

