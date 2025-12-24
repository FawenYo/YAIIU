# Immich Uploader (iOS)

**Immich Uploader** is a lightweight, unofficial iOS app designed to complement the official Immich iOS app — not replace it.

This project focuses on solving a few specific pain points that currently affect certain Immich users on iOS, especially photographers who rely on **JPEG + RAW workflows** and **background uploads**.

The app is open source, experimental, and contributions are very welcome 🙌

## Disclaimer

This is a unofficial project and has no affiliation with the official Immich project. Use at your own risk.

If you find any issues, please report them on this repository only but not on the official Immich channels.

## Why This App Exists

The official Immich iOS app is great, but there are a few limitations that impact some workflows:

### 1. JPEG + RAW Upload Support

When a photo in Apple Photos contains both **JPEG + RAW**, the official Immich iOS app currently uploads **only the JPEG**.

- This app uploads **both JPEG and RAW**.
- A fix has already been proposed upstream:
  - Immich PR: https://github.com/immich-app/immich/pull/24777
- However, the merge timeline is uncertain, so this app provides an immediate workaround.

### 2. iOS Background Uploads (iOS 26.1+)

Apple introduced a new PhotoKit API in iOS 26.1 that enables **true background uploads**:

- `Uploading Asset Resources in the Background`
- Apple documentation: https://developer.apple.com/documentation/photokit/uploading-asset-resources-in-the-background

At the moment, this is **not yet supported** by the official Immich iOS app.

Implementing this API is the **top priority** for Immich Uploader.

## Requirements

- iOS 17.0 or later (iOS 26.1+ for background uploads)
- An existing Immich server
- Immich API key

## Current Features

- 🔑 **Immich API Key authentication**
- 📦 **Import Immich SQLite database**
  - Allows users to reuse SQLite database dumped from the official Immich app
  - Avoids re-hashing all photos and videos
- 🖼 **JPEG + RAW upload support**
  - Correctly uploads both resources from Apple Photos

## Planned Features / Roadmap

- 🚀 **iOS 26.1 Background Upload Support** (Top Priority)
  - Contributions and PRs are highly welcome!
- 🌐 **Browse remote photos from Immich server**
  - In addition to local Photos library

## Non-Goals

To keep the scope clear:

- This app is **NOT** intended to replace the official Immich iOS app
- It does **NOT** aim to implement full Immich client features
- It focuses only on specific upload-related workflows

## Contributing

Contributions are very welcome ❤️

Whether you want to:

- Implement new features
- Improve performance or stability
- Clean up UI / UX
- Improve documentation
- Fix bugs

Please feel free to open issues or submit PRs, even small PRs are appreciated!

## License

AGPL-3.0 License
