<p align="center">
  <img src="docs/images/app-icon.png" width="128" alt="Placard app icon">
</p>

# Placard

Placard is an iOS app for browsing, creating, installing, and managing custom PosterBoard wallpapers.

## Features

- Browse, search, sort, and preview community-made interactive wallpapers
- Download or import local `.tendies` wallpaper packages
- Turn a vertical video of up to 12 seconds into a looping or auto-reversing Lock Screen wallpaper
- Install wallpapers directly into PosterBoard on supported physical devices
- View and remove installed custom and featured wallpapers
- Refresh SpringBoard after wallpaper changes with NeoSpring
- English and Simplified Chinese localization

## Preview

<p align="center">
  <img src="docs/images/browse-custom.png" width="360" alt="Placard's Custom wallpaper browsing screen">
</p>

## Requirements

- Xcode 26 or later
- iOS 26 or later
- A physical device with `bad_query` support, or iOS 27+ with LocalDevVPN and a pairing file for Airlift installation

The Simulator can be used to browse the catalog and develop the interface, but it cannot install or manage system wallpapers.

## Building

1. Clone this repository.
2. Run `./scripts/prepare-airlift.sh` to fetch the pinned `AirliftFFI` XCFramework.
3. Open `placard.xcodeproj` in Xcode.
4. Select the **placard** target and choose your own development team under **Signing & Capabilities**.
5. Build and run the app on your device.

Swift Package Manager resolves [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) automatically when the project is opened.

## How it works

Placard fetches the community wallpaper catalog, downloads the selected `.tendies` package, validates and extracts its PosterBoard descriptors, and assigns fresh identifiers before installation. On supported builds, `bad_query` provides access to the PosterBoard container. Placard also uses that access to display and remove installed wallpapers. On other iOS 27+ builds, the installation path uses Airlift after device pairing and LocalDevVPN setup.

For a custom video wallpaper, Placard generates the required CAML and PosterBoard descriptor structure locally, then installs it through the same pipeline. Wallpaper changes finish with a SpringBoard refresh powered by NeoSpring.

### Airlift fallback on iOS 27+

On iOS 27 builds where `bad_query` is unavailable, Placard can write new PosterBoard descriptors through [AirCard-iOS](https://github.com/Mak5er/AirCard-iOS)'s on-device `AirliftFFI` implementation. This requires LocalDevVPN in loopback mode and a pairing file imported in Placard's Airlift tab. Pair the device with AirCard-iOS in Developer Mode, then share its `aircard_pairing.plist` or `airlift_pairing.plist` into Placard. The fallback currently installs wallpapers; the installed-wallpaper library and removal still require `bad_query`. Airlift is not used on iOS 26 or earlier, where its iOS 27 workflow has not been verified.

Run `./scripts/prepare-airlift.sh` before building to fetch the pinned AirCard-iOS framework. This large, third-party binary is deliberately not committed to Placard. The script checks the upstream commit before copying the XCFramework.

> [!WARNING]
> Placard relies on behavior that is not provided by a public Apple API. Compatibility may change between iOS releases. Installing or deleting system wallpaper data carries risk; use the app only on a device and OS version you are prepared to test.

## Acknowledgements

Placard would not exist without the work of the following projects and contributors:

- [Pocket Poster](https://github.com/leminlimez/Pocket-Poster) by LeminLimez, the original project that inspired Placard's PosterBoard wallpaper workflow and `.tendies` support.
- [bad_query](https://github.com/forcequitOS/bad_query) by forcequitOS, which provides the sandbox extension technique used to access PosterBoard data on supported systems.
- [airlift](https://github.com/0xjohnnydev/airlift) by Johnny Franks (0xjohnnydev), whose AirTraffic and ATAirlock research underlies the fallback.
- [AirCard-iOS](https://github.com/Mak5er/AirCard-iOS) by Mak5er and contributors, whose MIT-licensed `AirliftFFI` implementation provides the on-device transport and PosterBoard folder injection. Its license is reproduced in [third-party notices](THIRD_PARTY_NOTICES.md).
- [SerStars/nugget-wallpapers](https://github.com/SerStars/nugget-wallpapers) and [CAPlayground/wallpapers](https://github.com/CAPlayground/wallpapers), which provide the wallpaper metadata, previews, and packages shown in Placard.
- [NeoSpring](https://github.com/rooootdev/neospring) by rooootdev and its contributors, whose SpringBoard refresh technique is used after wallpaper changes.
- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) for ZIP archive handling.

Wallpaper artwork remains the property of its respective creators. Author attribution supplied by the catalog is displayed in the app.

## License

Placard is released under the [GNU General Public License v3.0](LICENSE).

Some incorporated techniques or source material come from upstream projects. Review their respective terms before redistributing a build; in particular, the upstream `bad_query` and NeoSpring repositories may not declare a separate license.
