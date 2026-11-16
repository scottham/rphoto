# RPhoto Privacy Policy

Last updated: November 16, 2026

## 1. Overview

RPhoto is designed for on-device semantic photo search. Photo indexing, embedding generation, and retrieval are intended to run locally on your device.

## 2. Data Processed On Device

RPhoto may process the following data locally:

- Selected photo local identifiers and image data available on-device.
- Generated image embeddings used for semantic retrieval.
- Search query text.

## 3. How We Use This Data

The data above is used only to provide app functionality, including:

- Building and updating the local search index.
- Running semantic photo search. Queries in any language are encoded directly by the on-device model; no translation service is used.

## 4. Network Usage

- RPhoto does not use the network. Photo indexing, search, and all models run entirely on your device.
- No photos, search queries, or usage data are sent off the device.
- RPhoto configures photo loading to avoid triggering iCloud original downloads. If only iCloud originals exist, RPhoto uses local available representations (for example, thumbnails) when possible.

## 5. Third-Party Technology

Semantic search uses Google's SigLIP 2 model (Apache License 2.0), converted to run on-device with Core ML. The model is bundled with the app and does not communicate with Google or any other service.

## 6. Permissions

RPhoto requests photo library access to search selected photos. You can change or revoke this permission at any time in iOS Settings.

## 7. Data Retention and Deletion

Search cache data (including embeddings) is stored locally in the app sandbox. You can remove local data by clearing cache in-app or deleting the app from your device.

## 8. Contact

For privacy-related questions, use the developer contact channel shown on the app distribution page.
