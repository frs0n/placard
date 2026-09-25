//
//  TendiesModel.swift
//  AirCard-iOS
//
//  Models and data structures for PosterBoard .tendies wallpapers.
//

import SwiftUI

public enum TendiePosterType: String, Codable, CaseIterable {
    case collections = "Collections"
    case suggestedPhotos = "Suggested Photos"
    case mercury = "Mercury"
    case container = "App Container"

    public var systemIcon: String {
        switch self {
        case .collections: return "paintpalette.fill"
        case .suggestedPhotos: return "photo.fill"
        case .mercury: return "sparkles"
        case .container: return "shippingbox.fill"
        }
    }

    public var badgeColor: Color {
        switch self {
        case .collections: return .purple
        case .suggestedPhotos: return .blue
        case .mercury: return .orange
        case .container: return .indigo
        }
    }

    public var extensionBundleId: String {
        switch self {
        case .collections:
            return "com.apple.WallpaperKit.CollectionsPoster"
        case .suggestedPhotos:
            return "com.apple.PhotosUIPrivate.PhotosPosterProvider"
        case .mercury:
            return "com.apple.MercuryPoster"
        case .container:
            return "com.apple.PosterBoard"
        }
    }
}

public struct TendieItem: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var fileName: String
    public var relativePath: String
    public var isContainer: Bool
    public var unsafeContainer: Bool
    public var descriptorCount: Int
    public var posterType: TendiePosterType
    public var previewImageData: Data?
    public var dateImported: Date
    public var isSelected: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        fileName: String,
        relativePath: String,
        isContainer: Bool = false,
        unsafeContainer: Bool = false,
        descriptorCount: Int = 1,
        posterType: TendiePosterType = .collections,
        previewImageData: Data? = nil,
        dateImported: Date = Date(),
        isSelected: Bool = true
    ) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.relativePath = relativePath
        self.isContainer = isContainer
        self.unsafeContainer = unsafeContainer
        self.descriptorCount = descriptorCount
        self.posterType = posterType
        self.previewImageData = previewImageData
        self.dateImported = dateImported
        self.isSelected = isSelected
    }

    public var fileURL: URL {
        TendiesEngine.tendiesStorageDirectory.appendingPathComponent(relativePath)
    }

    public var uiPreview: UIImage? {
        guard let data = previewImageData else { return nil }
        return UIImage(data: data)
    }

    public static func == (lhs: TendieItem, rhs: TendieItem) -> Bool {
        lhs.id == rhs.id &&
        lhs.name == rhs.name &&
        lhs.isSelected == rhs.isSelected &&
        lhs.descriptorCount == rhs.descriptorCount &&
        lhs.previewImageData?.count == rhs.previewImageData?.count
    }
}
