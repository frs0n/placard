import Foundation

// Match GestaltEdit's minimum OS; access is checked when acquiring a lease.
enum SystemCompatibility {
    static var isSupported: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
    }

    static var supportedRangeDescription: String {
        String(localized: "iOS/iPadOS 26.0 or later")
    }
}
