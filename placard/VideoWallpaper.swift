import AVFoundation
import CoreImage
import CoreTransferable
import Foundation
import Observation
import PhotosUI
import SwiftUI
import UIKit

struct ImportedVideo: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let destination = FileManager.default.temporaryDirectory
                .appending(path: "Placard-Video-\(UUID().uuidString).mov")
            try FileManager.default.copyItem(at: received.file, to: destination)
            return ImportedVideo(url: destination)
        }
    }
}

struct VideoWallpaperDraft: Identifiable, Equatable, Sendable {
    let id = UUID()
    let url: URL
}

enum VideoWallpaperFrameRate: Int, CaseIterable, Identifiable, Sendable {
    case efficient = 10
    case recommended = 15
    case smooth = 20
    case high = 30
    case maximum = 60

    var id: Int { rawValue }
    var framesPerSecond: Float { Float(rawValue) }
    var isHighRisk: Bool { rawValue > Self.high.rawValue }
}

@MainActor
@Observable
final class VideoInstallCoordinator {
    private(set) var state: VideoInstallState = .idle
    private let installer = VideoWallpaperInstaller()
    private var task: Task<Void, Never>?

    func install(
        url: URL,
        name: String,
        autoReverses: Bool,
        frameRate: VideoWallpaperFrameRate
    ) {
        guard !state.isWorking else { return }
        task?.cancel()
        task = Task {
            do {
                state = .inspecting
                try await installer.install(
                    sourceURL: url,
                    name: name,
                    autoReverses: autoReverses,
                    frameRate: frameRate
                ) { [weak self] phase in
                    self?.state = phase
                }
                finishInstallation()
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failure(error.localizedDescription)
            }
        }
    }

    func continueAfterLocationNotice() {
        guard state == .installed else { return }
        task = Task {
            state = .preparingRespring
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            state = .respringing
        }
    }

    private func finishInstallation() {
        if WallpaperLocationNotice.isEnabled {
            state = .installed
        } else {
            continueAfterLocationNotice()
        }
    }
}

enum VideoInstallState: Equatable, Sendable {
    case idle
    case inspecting
    case generating
    case locatingPosterBoard
    case writing
    case installed
    case preparingRespring
    case respringing
    case failure(String)

    var isWorking: Bool {
        switch self {
        case .inspecting, .generating, .locatingPosterBoard, .writing,
             .preparingRespring, .respringing: true
        default: false
        }
    }

    var isTerminal: Bool {
        if case .failure = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .idle: ""
        case .inspecting: String(localized: "Checking video…")
        case .generating: String(localized: "Creating video wallpaper…")
        case .locatingPosterBoard: String(localized: "Preparing…")
        case .writing: String(localized: "Installing…")
        case .installed: String(localized: "Wallpaper Installed")
        case .preparingRespring: String(localized: "Preparing to refresh screen…")
        case .respringing: String(localized: "Refreshing screen…")
        case .failure(let message): message
        }
    }

    var buttonTitle: String {
        switch self {
        case .idle, .failure: String(localized: "Install Wallpaper")
        default: String(localized: "Processing…")
        }
    }
}

private actor VideoWallpaperInstaller {
    private let fileManager = FileManager.default
    private let maximumDuration = 12.0
    private let maximumOutputLongEdge: CGFloat = 1920

    func install(
        sourceURL: URL,
        name: String,
        autoReverses: Bool,
        frameRate: VideoWallpaperFrameRate,
        progress: @MainActor @Sendable (VideoInstallState) -> Void
    ) async throws {
        #if targetEnvironment(simulator)
        throw VideoWallpaperError.deviceRequired
        #else
        guard BadQuery.isAvailable else { throw VideoWallpaperError.unsupportedSystem }

        await progress(.generating)
        let workspace = fileManager.temporaryDirectory
            .appending(path: "Placard-Video-Install-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        let descriptor = try await createDescriptor(
            from: sourceURL,
            in: workspace,
            autoReverses: autoReverses,
            requestedFrameRate: frameRate.framesPerSecond
        )
        try Task.checkCancellation()

        await progress(.locatingPosterBoard)
        let appHash = try BadQuery.findPosterBoardHash()
        try Task.checkCancellation()

        await progress(.writing)
        let paths = try BadQuery.writeDescriptors(
            appHash: appHash,
            extensionID: "com.apple.WallpaperKit.CollectionsPoster",
            descriptorFolders: [descriptor]
        )
        InstalledWallpaperNameStore.record(name: name, paths: paths)
        #endif
    }

    private func createDescriptor(
        from sourceURL: URL,
        in workspace: URL,
        autoReverses: Bool,
        requestedFrameRate: Float
    ) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw VideoWallpaperError.invalidVideo
        }
        guard durationSeconds <= maximumDuration else {
            throw VideoWallpaperError.videoTooLong(maximumDuration)
        }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoWallpaperError.invalidVideo
        }

        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        let transformedRect = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
            .standardized
        let sourceWidth = Int(transformedRect.width.rounded())
        let sourceHeight = Int(transformedRect.height.rounded())
        guard sourceWidth > 0, sourceHeight > 0, nominalFrameRate > 0 else {
            throw VideoWallpaperError.invalidVideo
        }
        let maximumOutputLongEdge = maximumOutputLongEdge
        let outputSize = await MainActor.run {
            let nativeSize = UIScreen.main.nativeBounds.size
            let nativeLongEdge = max(nativeSize.width, nativeSize.height)
            let nativeShortEdge = min(nativeSize.width, nativeSize.height)
            let outputLongEdge = min(nativeLongEdge, maximumOutputLongEdge)
            let scaledShortEdge = outputLongEdge * nativeShortEdge / nativeLongEdge
            let outputShortEdge = max(2, (scaledShortEdge / 2).rounded(.down) * 2)
            return CGSize(width: outputShortEdge, height: outputLongEdge)
        }
        let width = Int(outputSize.width)
        let height = Int(outputSize.height)
        let outputFrameRate = min(nominalFrameRate, requestedFrameRate)
        NSLog(
            "[Placard] video source=%ldx%ld %.2f fps output=%ldx%ld %.2f fps duration=%.3f",
            sourceWidth,
            sourceHeight,
            nominalFrameRate,
            width,
            height,
            outputFrameRate,
            durationSeconds
        )

        let identifier = Int.random(in: 9_999...99_999)
        let descriptorURL = workspace.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let wallpaperName = "9183.Custom-810w-1080h@2x~ipad.wallpaper"
        let wallpaperURL = descriptorURL
            .appending(path: "versions/1/contents/\(wallpaperName)", directoryHint: .isDirectory)
        let backgroundName = "9183.Custom_Background-810w-1080h@2x~ipad.ca"
        let floatingName = "9183.Custom_Floating-810w-1080h@2x~ipad.ca"
        let animationURL = wallpaperURL.appending(path: backgroundName, directoryHint: .isDirectory)
        let assetsURL = animationURL.appending(path: "assets", directoryHint: .isDirectory)
        let floatingURL = wallpaperURL.appending(path: floatingName, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: floatingURL, withIntermediateDirectories: true)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VideoWallpaperError.invalidVideo }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? VideoWallpaperError.invalidVideo
        }

        let context = CIContext()
        var frameNames: [String] = []
        var lastFrameTime: CMTime?
        var encodedBytes = 0
        let frameInterval = CMTime(
            seconds: 1 / Double(outputFrameRate),
            preferredTimescale: 600
        )
        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if let lastFrameTime,
               CMTimeCompare(CMTimeSubtract(presentationTime, lastFrameTime), frameInterval) < 0 {
                continue
            }
            let frameName = "\(frameNames.count).jpg"
            let jpeg = try autoreleasepool { () throws -> Data in
                guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                    throw VideoWallpaperError.frameEncodingFailed
                }
                let sourceImage = CIImage(cvPixelBuffer: imageBuffer)
                    .transformed(by: preferredTransform)
                let normalizedImage = sourceImage.transformed(
                    by: CGAffineTransform(
                        translationX: -sourceImage.extent.minX,
                        y: -sourceImage.extent.minY
                    )
                )
                let scale = max(
                    outputSize.width / normalizedImage.extent.width,
                    outputSize.height / normalizedImage.extent.height
                )
                let scaledImage = normalizedImage.transformed(
                    by: CGAffineTransform(scaleX: scale, y: scale)
                )
                let cropRect = CGRect(
                    x: scaledImage.extent.midX - outputSize.width / 2,
                    y: scaledImage.extent.midY - outputSize.height / 2,
                    width: outputSize.width,
                    height: outputSize.height
                )
                let outputImage = scaledImage.cropped(to: cropRect).transformed(
                    by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY)
                )
                guard let cgImage = context.createCGImage(
                    outputImage,
                    from: CGRect(origin: .zero, size: outputSize)
                ),
                      let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.7) else {
                    throw VideoWallpaperError.frameEncodingFailed
                }
                return data
            }
            try jpeg.write(to: assetsURL.appending(path: frameName), options: .atomic)
            frameNames.append(frameName)
            encodedBytes += jpeg.count
            lastFrameTime = presentationTime
        }
        guard reader.status == .completed, !frameNames.isEmpty else {
            throw reader.error ?? VideoWallpaperError.invalidVideo
        }

        let animationDuration = durationSeconds
        NSLog(
            "[Placard] encoded %ld video frames (%ld bytes)",
            frameNames.count,
            encodedBytes
        )
        try makeDescriptorMetadata(
            at: descriptorURL,
            identifier: identifier,
            wallpaperName: wallpaperName,
            backgroundName: backgroundName,
            floatingName: floatingName,
            width: width,
            height: height
        )
        try caml(
            width: width,
            height: height,
            frameNames: frameNames,
            duration: animationDuration,
            autoReverses: autoReverses
        ).write(to: animationURL.appending(path: "main.caml"), atomically: true, encoding: .utf8)
        try indexXML(width: width, height: height)
            .write(to: animationURL.appending(path: "index.xml"), atomically: true, encoding: .utf8)
        try blankCAML()
            .write(to: floatingURL.appending(path: "main.caml"), atomically: true, encoding: .utf8)
        try floatingIndexXML()
            .write(to: floatingURL.appending(path: "index.xml"), atomically: true, encoding: .utf8)
        return descriptorURL
    }

    private func makeDescriptorMetadata(
        at descriptorURL: URL,
        identifier: Int,
        wallpaperName: String,
        backgroundName: String,
        floatingName: String,
        width: Int,
        height: Int
    ) throws {
        try Data(String(identifier).utf8).write(
            to: descriptorURL.appending(path: "com.apple.posterkit.provider.descriptor.identifier"),
            options: .atomic
        )
        try Data("PRPosterRoleLockScreen".utf8).write(
            to: descriptorURL.appending(path: "com.apple.posterkit.role.identifier"),
            options: .atomic
        )

        let providerInfo = try NSKeyedArchiver.archivedData(
            withRootObject: ["kConfigurationLastUseDateKey": Date()],
            requiringSecureCoding: false
        )
        try providerInfo.write(to: descriptorURL.appending(path: "providerInfo.plist"), options: .atomic)

        let contentsURL = descriptorURL.appending(path: "versions/1/contents", directoryHint: .isDirectory)
        let userInfo: [String: Any] = [
            "posterEnvironmentOverrides": Data("{}".utf8),
            "wallpaperRepresentingFileName": wallpaperName,
            "wallpaperRepresentingIdentifier": identifier
        ]
        try writePlist(
            userInfo,
            to: contentsURL.appending(path: "com.apple.posterkit.provider.contents.userInfo")
        )

        let wallpaper: [String: Any] = [
            "appearanceAware": true,
            "assets": [
                "lockAndHome": [
                    "default": [
                        "backgroundAnimationFileName": backgroundName,
                        "floatingAnimationFileNameKey": floatingName,
                        "identifier": 9183,
                        "name": "Chip",
                        "type": "LayeredAnimation"
                    ]
                ]
            ],
            "contentVersion": 2.01,
            "family": "Chip",
            "identifier": identifier,
            "logicalScreenClass": "810w-1080h@2x~ipad",
            "name": "Chip",
            "preferredProminentColor": ["dark": "#00000", "default": "#FFFFFF"],
            "version": 1
        ]
        try writePlist(
            wallpaper,
            to: contentsURL.appending(path: wallpaperName, directoryHint: .isDirectory)
                .appending(path: "Wallpaper.plist")
        )
    }

    private func writePlist(_ value: Any, to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: value,
            format: .binary,
            options: 0
        )
        try data.write(to: url, options: .atomic)
    }

    private func caml(
        width: Int,
        height: Int,
        frameNames: [String],
        duration: Double,
        autoReverses: Bool
    ) -> String {
        let values = frameNames
            .map { "        <CGImage src=\"assets/\($0)\"/>" }
            .joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <caml xmlns="http://www.apple.com/CoreAnimation/1.0">
          <CALayer allowsEdgeAntialiasing="1" allowsGroupOpacity="1" bounds="0 0 \(width) \(height)" contentsFormat="RGBA8" cornerCurve="circular" hidden="0" name="_FLOATING" position="\(width / 2) \(height / 2)">
            <sublayers>
              <CATransformLayer allowsEdgeAntialiasing="1" allowsGroupOpacity="1" allowsHitTesting="1" bounds="0 0 \(width) \(height)" contentsFormat="RGBA8" cornerCurve="circular" name="Chip" position="\(width / 2) \(height / 2)">
                <sublayers>
                  <CALayer allowsEdgeAntialiasing="1" allowsGroupOpacity="1" bounds="0 0 \(width) \(height)" contentsFormat="RGBA8" cornerCurve="circular" name="CALayer1" position="\(width / 2) \(height / 2)">
                    <contents type="CGImage" src="assets/0.jpg"/>
                    <animations>
                      <animation type="CAKeyframeAnimation" calculationMode="linear" keyPath="contents" beginTime="1e-100" duration="\(duration)" removedOnCompletion="0" repeatCount="inf" repeatDuration="0" speed="1" timeOffset="0" autoreverses="\(autoReverses ? 1 : 0)">
                        <values>
        \(values)
                        </values>
                      </animation>
                    </animations>
                  </CALayer>
                </sublayers>
              </CATransformLayer>
            </sublayers>
            <states><LKState name="Locked"><elements/></LKState><LKState name="Unlock"><elements/></LKState><LKState name="Sleep"><elements/></LKState></states>
            <stateTransitions><LKStateTransition fromState="*" toState="Unlock"><elements/></LKStateTransition><LKStateTransition fromState="Unlock" toState="*"><elements/></LKStateTransition><LKStateTransition fromState="*" toState="Locked"><elements/></LKStateTransition><LKStateTransition fromState="Locked" toState="*"><elements/></LKStateTransition><LKStateTransition fromState="*" toState="Sleep"><elements/></LKStateTransition><LKStateTransition fromState="Sleep" toState="*"><elements/></LKStateTransition></stateTransitions>
          </CALayer>
        </caml>
        """
    }

    private func blankCAML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <caml xmlns="http://www.apple.com/CoreAnimation/1.0">
          <CALayer allowsEdgeAntialiasing="1" allowsGroupOpacity="1" bounds="0 0 3176 3176" contentsFormat="RGBA8" cornerCurve="circular" hidden="0" name="_BACKGROUND" position="1588 1588">
            <sublayers><CALayer allowsEdgeAntialiasing="1" allowsGroupOpacity="1" anchorPoint="0 0" bounds="0 0 0 0" contentsFormat="RGBA8" cornerCurve="circular" name="_CENTER_BACKGROUND" position="1588 1588"/></sublayers>
            <states><LKState name="Locked"><elements/></LKState><LKState name="Unlock"><elements/></LKState><LKState name="Sleep"><elements/></LKState></states>
            <stateTransitions><LKStateTransition fromState="*" toState="Unlock"><elements/></LKStateTransition><LKStateTransition fromState="Unlock" toState="*"><elements/></LKStateTransition><LKStateTransition fromState="*" toState="Locked"><elements/></LKStateTransition><LKStateTransition fromState="Locked" toState="*"><elements/></LKStateTransition><LKStateTransition fromState="*" toState="Sleep"><elements/></LKStateTransition><LKStateTransition fromState="Sleep" toState="*"><elements/></LKStateTransition></stateTransitions>
          </CALayer>
        </caml>
        """
    }

    private func indexXML(width: Int, height: Int) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>assetManifest</key><string>assetManifest.caml</string>
          <key>documentHeight</key><real>\(height)</real>
          <key>documentResizesToView</key><true/>
          <key>documentWidth</key><real>\(width)</real>
          <key>dynamicGuidesEnabled</key><true/>
          <key>geometryFlipped</key><false/>
          <key>guidesEnabled</key><true/>
          <key>interactiveMouseEventsEnabled</key><true/>
          <key>interactiveShowsCursor</key><true/>
          <key>interactiveTouchEventsEnabled</key><false/>
          <key>loopEnd</key><real>0.0</real>
          <key>loopStart</key><real>0.0</real>
          <key>loopingEnabled</key><false/>
          <key>multitouchDisablesMouse</key><false/>
          <key>multitouchEnabled</key><false/>
          <key>presentationMouseEventsEnabled</key><true/>
          <key>presentationShowsCursor</key><true/>
          <key>presentationTouchEventsEnabled</key><false/>
          <key>rootDocument</key><string>main.caml</string>
          <key>savesWindowFrame</key><false/>
          <key>scalesToFitInPlayer</key><true/>
          <key>showsTouches</key><true/>
          <key>snappingEnabled</key><true/>
          <key>timelineMarkers</key><string>[(null)]</string>
          <key>touchesColor</key><string>1 1 0 0.8</string>
          <key>unitsInPixelsInPlayer</key><true/>
        </dict></plist>
        """
    }

    private func floatingIndexXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>assetManifest</key><string>assetManifest.caml</string>
          <key>documentHeight</key><real>3176</real>
          <key>documentResizesToView</key><false/>
          <key>documentWidth</key><real>3176</real>
          <key>dynamicGuidesEnabled</key><true/>
          <key>geometryFlipped</key><false/>
          <key>guidesEnabled</key><true/>
          <key>interactiveMouseEventsEnabled</key><true/>
          <key>interactiveShowsCursor</key><true/>
          <key>interactiveTouchEventsEnabled</key><false/>
          <key>loopEnd</key><real>0.0</real>
          <key>loopStart</key><real>0.0</real>
          <key>loopingEnabled</key><false/>
          <key>multitouchDisablesMouse</key><false/>
          <key>multitouchEnabled</key><false/>
          <key>presentationMouseEventsEnabled</key><true/>
          <key>presentationShowsCursor</key><true/>
          <key>presentationTouchEventsEnabled</key><false/>
          <key>rootDocument</key><string>main.caml</string>
          <key>savesWindowFrame</key><false/>
          <key>scalesToFitInPlayer</key><false/>
          <key>showsTouches</key><true/>
          <key>snappingEnabled</key><true/>
          <key>timelineMarkers</key><string>[(null)]</string>
          <key>touchesColor</key><string>1 1 0 0.8</string>
          <key>unitsInPixelsInPlayer</key><true/>
        </dict></plist>
        """
    }
}

enum VideoWallpaperError: LocalizedError {
    case deviceRequired
    case unsupportedSystem
    case invalidVideo
    case videoTooLong(Double)
    case frameEncodingFailed

    var errorDescription: String? {
        switch self {
        case .deviceRequired: String(localized: "Please install wallpapers on a physical device.")
        case .unsupportedSystem: String(localized: "This system version is not supported.")
        case .invalidVideo: String(localized: "This video can't be read.")
        case .videoTooLong(let seconds): String(localized: "The video can't be longer than \(Int(seconds)) seconds.")
        case .frameEncodingFailed: String(localized: "Failed to create the video wallpaper.")
        }
    }
}

struct VideoWallpaperDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let draft: VideoWallpaperDraft

    @State private var name = String(localized: "Video Wallpaper")
    @State private var autoReverses = false
    @State private var frameRate = VideoWallpaperFrameRate.high
    @State private var installer = VideoInstallCoordinator()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VideoWallpaperHero(url: draft.url, name: displayName)
                        .listRowInsets(.init())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                VideoWallpaperOptions(
                    name: $name,
                    autoReverses: $autoReverses,
                    frameRate: $frameRate
                )
            }
            .formStyle(.grouped)
            .safeAreaInset(edge: .bottom) {
                videoInstallBar
            }
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(installer.state.isWorking)
                }
            }
        }
        .interactiveDismissDisabled(installer.state.isWorking)
        .alert(
            "Wallpaper Installed",
            isPresented: locationNoticePresented
        ) {
            Button("Don't Show Again") {
                WallpaperLocationNotice.disable()
                installer.continueAfterLocationNotice()
            }
            Button("Continue") {
                installer.continueAfterLocationNotice()
            }
        } message: {
            Text("After the screen refreshes, open the system Add New Wallpaper page and find your wallpaper by name.")
        }
        .overlay {
            if installer.state == .respringing {
                NeoSpringView().ignoresSafeArea().transition(.opacity)
            }
        }
    }

    private var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? String(localized: "Video Wallpaper") : trimmedName
    }

    private var locationNoticePresented: Binding<Bool> {
        Binding(
            get: { installer.state == .installed },
            set: { isPresented in
                if !isPresented {
                    installer.continueAfterLocationNotice()
                }
            }
        )
    }

    private var videoInstallBar: some View {
        VStack(spacing: 8) {
            if installer.state.isWorking || installer.state.isTerminal {
                HStack(spacing: 8) {
                    if installer.state.isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Text(installer.state.message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            Button {
                let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                installer.install(
                    url: draft.url,
                    name: trimmedName.isEmpty ? String(localized: "Video Wallpaper") : trimmedName,
                    autoReverses: autoReverses,
                    frameRate: frameRate
                )
            } label: {
                Label(
                    installer.state.buttonTitle,
                    systemImage: installer.state.isWorking
                        ? "hourglass"
                        : "arrow.down.circle.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(installer.state.isWorking)

            if installer.state == .idle || installer.state.isTerminal {
                Text("The screen will briefly refresh after installation.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background {
            LinearGradient(
                colors: [
                    .clear,
                    Color(uiColor: .systemBackground).opacity(0.88),
                    Color(uiColor: .systemBackground)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .padding(.top, -36)
            .ignoresSafeArea(edges: .bottom)
        }
    }
}

private struct VideoWallpaperHero: View {
    let url: URL
    let name: String

    var body: some View {
        LoopingVideoPreview(url: url)
            .aspectRatio(0.56, contentMode: .fit)
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)
            .overlay {
                LinearGradient(
                    colors: [.clear, .clear, .black.opacity(0.82)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(name)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    Label("Animated Wallpaper", systemImage: "play.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.72))
                }
                .padding(20)
            }
            .clipShape(.rect(cornerRadius: 28))
            .overlay {
                RoundedRectangle(cornerRadius: 28)
                    .stroke(.white.opacity(0.16), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
            .accessibilityElement(children: .combine)
    }
}

private struct VideoWallpaperOptions: View {
    @Binding var name: String
    @Binding var autoReverses: Bool
    @Binding var frameRate: VideoWallpaperFrameRate

    var body: some View {
        Section {
            LabeledContent {
                TextField("Video Wallpaper", text: $name)
                    .multilineTextAlignment(.trailing)
            } label: {
                Label("Name", systemImage: "textformat")
            }

            Toggle(isOn: $autoReverses) {
                Label("Ping-Pong Playback", systemImage: "repeat")
            }

            Picker(selection: $frameRate) {
                ForEach(VideoWallpaperFrameRate.allCases) { option in
                    Text("\(option.rawValue) FPS").tag(option)
                }
            } label: {
                Label("Frame Rate", systemImage: "gauge.with.dots.needle.50percent")
            }

            if frameRate.isHighRisk {
                Label {
                    Text("High frame rates may prevent this wallpaper from loading in system settings.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.footnote)
                .foregroundStyle(.orange)
            }
        }
    }
}

private struct LoopingVideoPreview: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> LoopingPlayerView {
        LoopingPlayerView(url: url)
    }

    func updateUIView(_ uiView: LoopingPlayerView, context: Context) {}

    static func dismantleUIView(_ uiView: LoopingPlayerView, coordinator: Void) {
        uiView.stop()
    }
}

private final class LoopingPlayerView: UIView {
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?

    override class var layerClass: AnyClass { AVPlayerLayer.self }

    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    init(url: URL) {
        super.init(frame: .zero)
        backgroundColor = .black
        player.isMuted = true
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        player.play()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func stop() {
        player.pause()
        looper?.disableLooping()
        looper = nil
    }
}
