import AVFoundation
import CoreImage
import CoreTransferable
import Foundation
import ImageIO
import Observation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

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

@MainActor
@Observable
final class VideoInstallCoordinator {
    private(set) var state: VideoInstallState = .idle
    private let installer = VideoWallpaperInstaller()
    private var task: Task<Void, Never>?

    func install(url: URL, name: String, autoReverses: Bool) {
        guard !state.isWorking else { return }
        task?.cancel()
        task = Task {
            do {
                state = .inspecting
                try await installer.install(
                    sourceURL: url,
                    name: name,
                    autoReverses: autoReverses
                ) { [weak self] phase in
                    self?.state = phase
                }
                state = .preparingRespring
                try await Task.sleep(for: .milliseconds(250))
                state = .respringing
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failure(error.localizedDescription)
            }
        }
    }
}

enum VideoInstallState: Equatable, Sendable {
    case idle
    case inspecting
    case generating
    case locatingPosterBoard
    case writing
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
        case .inspecting: "正在检查视频…"
        case .generating: "正在生成动态壁纸…"
        case .locatingPosterBoard: "正在准备…"
        case .writing: "正在安装…"
        case .preparingRespring: "即将刷新屏幕…"
        case .respringing: "正在刷新屏幕…"
        case .failure(let message): message
        }
    }

    var buttonTitle: String {
        switch self {
        case .idle, .failure: "安装壁纸"
        default: "处理中…"
        }
    }
}

private actor VideoWallpaperInstaller {
    private let fileManager = FileManager.default
    private let maximumDuration = 12.0
    private let maximumFrames = 720

    func install(
        sourceURL: URL,
        name: String,
        autoReverses: Bool,
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
            autoReverses: autoReverses
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
        autoReverses: Bool
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
        let width = Int(transformedRect.width.rounded())
        let height = Int(transformedRect.height.rounded())
        guard width > 0, height > 0, nominalFrameRate > 0 else {
            throw VideoWallpaperError.invalidVideo
        }

        let estimatedFrames = Int(ceil(durationSeconds * Double(nominalFrameRate)))
        guard estimatedFrames <= maximumFrames else {
            throw VideoWallpaperError.tooManyFrames(maximumFrames)
        }

        let identifier = Int.random(in: 10_000...99_999)
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

        let context = CIContext(options: [.cacheIntermediates: false])
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var frameNames: [String] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard frameNames.count < maximumFrames,
                  let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                reader.cancelReading()
                throw VideoWallpaperError.tooManyFrames(maximumFrames)
            }
            let sourceImage = CIImage(cvPixelBuffer: imageBuffer).transformed(by: preferredTransform)
            let normalizedImage = sourceImage.transformed(
                by: CGAffineTransform(translationX: -sourceImage.extent.minX, y: -sourceImage.extent.minY)
            )
            guard let cgImage = context.createCGImage(normalizedImage, from: normalizedImage.extent),
                  let jpeg = jpegData(from: cgImage, colorSpace: colorSpace) else {
                reader.cancelReading()
                throw VideoWallpaperError.frameEncodingFailed
            }
            let frameName = "\(frameNames.count).jpg"
            try jpeg.write(to: assetsURL.appending(path: frameName), options: .atomic)
            frameNames.append(frameName)
        }
        guard reader.status == .completed, !frameNames.isEmpty else {
            throw reader.error ?? VideoWallpaperError.invalidVideo
        }

        let animationDuration = Double(frameNames.count) / Double(nominalFrameRate)
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
        try blankCAML(width: width, height: height)
            .write(to: floatingURL.appending(path: "main.caml"), atomically: true, encoding: .utf8)
        try indexXML(width: width, height: height)
            .write(to: floatingURL.appending(path: "index.xml"), atomically: true, encoding: .utf8)
        return descriptorURL
    }

    private func jpegData(from image: CGImage, colorSpace: CGColorSpace) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            [
                kCGImageDestinationLossyCompressionQuality: 0.7,
                kCGImagePropertyColorModel: colorSpace.model.rawValue
            ] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
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
                        "identifier": identifier,
                        "name": "Placard Video",
                        "type": "LayeredAnimation"
                    ]
                ]
            ],
            "contentVersion": 2.01,
            "family": "Placard Video",
            "identifier": identifier,
            "logicalScreenClass": "810w-1080h@2x~ipad",
            "name": "Placard Video",
            "preferredProminentColor": ["dark": "#000000", "default": "#FFFFFF"],
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
              <CATransformLayer allowsEdgeAntialiasing="1" allowsGroupOpacity="1" allowsHitTesting="1" bounds="0 0 \(width) \(height)" contentsFormat="RGBA8" cornerCurve="circular" name="Video" position="\(width / 2) \(height / 2)">
                <sublayers>
                  <CALayer allowsEdgeAntialiasing="1" allowsGroupOpacity="1" bounds="0 0 \(width) \(height)" contentsFormat="RGBA8" cornerCurve="circular" name="VideoFrames" position="\(width / 2) \(height / 2)">
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

    private func blankCAML(width: Int, height: Int) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <caml xmlns="http://www.apple.com/CoreAnimation/1.0">
          <CALayer allowsEdgeAntialiasing="1" allowsGroupOpacity="1" bounds="0 0 \(width) \(height)" contentsFormat="RGBA8" cornerCurve="circular" hidden="0" name="_BACKGROUND" position="\(width / 2) \(height / 2)">
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
          <key>geometryFlipped</key><false/>
          <key>rootDocument</key><string>main.caml</string>
          <key>scalesToFitInPlayer</key><true/>
        </dict></plist>
        """
    }
}

enum VideoWallpaperError: LocalizedError {
    case deviceRequired
    case unsupportedSystem
    case invalidVideo
    case videoTooLong(Double)
    case tooManyFrames(Int)
    case frameEncodingFailed

    var errorDescription: String? {
        switch self {
        case .deviceRequired: "请在真机上安装壁纸。"
        case .unsupportedSystem: "当前系统版本不受支持。"
        case .invalidVideo: "无法读取这个视频。"
        case .videoTooLong(let seconds): "视频不能超过 \(Int(seconds)) 秒。"
        case .tooManyFrames(let count): "视频帧数过多，请控制在 \(count) 帧以内。"
        case .frameEncodingFailed: "生成动态壁纸失败。"
        }
    }
}

struct VideoWallpaperDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let draft: VideoWallpaperDraft

    @State private var name = "视频壁纸"
    @State private var autoReverses = false
    @State private var installer = VideoInstallCoordinator()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    LoopingVideoPreview(url: draft.url)
                        .aspectRatio(0.56, contentMode: .fit)
                        .frame(maxWidth: 420)
                        .clipShape(.rect(cornerRadius: 24))
                        .overlay {
                            RoundedRectangle(cornerRadius: 24)
                                .stroke(.separator, lineWidth: 0.5)
                        }

                    VStack(spacing: 0) {
                        TextField("壁纸名称", text: $name)
                            .textInputAutocapitalization(.never)
                            .padding(16)

                        Divider().padding(.leading, 16)

                        Toggle(isOn: $autoReverses) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("往返播放")
                                Text("循环时反向播放，衔接更自然")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(16)
                    }
                    .background(.quaternary.opacity(0.55), in: .rect(cornerRadius: 16))

                    Text("视频最长 12 秒，生成时可能需要一点时间。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .safeAreaInset(edge: .bottom) {
                videoInstallBar
            }
            .navigationTitle("视频壁纸")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .disabled(installer.state.isWorking)
                }
            }
        }
        .interactiveDismissDisabled(installer.state.isWorking)
        .overlay {
            if installer.state == .respringing {
                NeoSpringView().ignoresSafeArea().transition(.opacity)
            }
        }
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
                    name: trimmedName.isEmpty ? "视频壁纸" : trimmedName,
                    autoReverses: autoReverses
                )
            } label: {
                Text(installer.state.buttonTitle).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(installer.state.isWorking)
        }
        .padding(16)
        .background(.bar)
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
