import Foundation

/// Supported range: iOS/iPadOS 26.0 through 26.6.1, plus 27.0 developer betas 1-4.
/// Every 27.0 beta reports systemVersion "27.0", so betas are told apart by build number.
enum SystemCompatibility {
    /// iOS/iPadOS 27.0 beta 1-4 build numbers (iPadOS beta 3 shipped a revised "v2" build).
    private static let supportedBuilds27: Set<String> = [
        "24A5355q", // 27.0 beta 1
        "24A5370h", // 27.0 beta 2
        "24A5380h", // 27.0 beta 3
        "24A5380l", // 27.0 beta 3 (iPadOS revised build)
        "24A5390f"  // 27.0 beta 4
    ]

    nonisolated static var isSupported: Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        if version.majorVersion == 26 {
            return isAtMost(version, major: 26, minor: 6, patch: 1)
        }
        if version.majorVersion == 27, version.minorVersion == 0, version.patchVersion == 0 {
            guard let build = currentBuildNumber() else { return false }
            return supportedBuilds27.contains(build)
        }
        return false
    }

    /// The AirTraffic route used by AirCard-iOS targets iOS 27 and newer.
    nonisolated static var canUseAirlift: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
        #endif
    }

    nonisolated static var usesBadQuery: Bool { isSupported && BadQuery.isAvailable }

    static var supportedRangeDescription: String {
        String(localized: "iOS/iPadOS 26.0–26.6.1, or 27.0 developer beta 1–4")
    }

    nonisolated private static func isAtMost(
        _ version: OperatingSystemVersion,
        major: Int,
        minor: Int,
        patch: Int
    ) -> Bool {
        let lhs = (version.majorVersion, version.minorVersion, version.patchVersion)
        let rhs = (major, minor, patch)
        return lhs == rhs || lhs < rhs
    }

    nonisolated private static func currentBuildNumber() -> String? {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
