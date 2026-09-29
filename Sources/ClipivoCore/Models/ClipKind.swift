import Foundation

/// The semantic type assigned to every clip. Stored as its raw value in the database,
/// so raw values must never change once shipped.
public enum ClipKind: String, Codable, CaseIterable, Sendable, Hashable {
    case text
    case richText = "rich_text"
    case url
    case image
    case screenshot
    case file
    case folder
    case pdf
    case code
    case color
    case email
    case phone
    case address
    case credential
    case otp
    case unknown

    public var displayName: String {
        switch self {
        case .text: return "Text"
        case .richText: return "Rich Text"
        case .url: return "Link"
        case .image: return "Image"
        case .screenshot: return "Screenshot"
        case .file: return "File"
        case .folder: return "Folder"
        case .pdf: return "PDF"
        case .code: return "Code"
        case .color: return "Color"
        case .email: return "Email"
        case .phone: return "Phone"
        case .address: return "Address"
        case .credential: return "Credential"
        case .otp: return "One-Time Code"
        case .unknown: return "Other"
        }
    }

    /// True for kinds whose primary payload is bitmap data.
    public var isImageLike: Bool { self == .image || self == .screenshot }

    /// True for kinds whose primary payload is text.
    public var isTextLike: Bool {
        switch self {
        case .text, .richText, .url, .code, .color, .email, .phone, .address, .credential, .otp: return true
        default: return false
        }
    }
}

/// User-facing filter buckets. A bucket maps to one or more `ClipKind`s.
public enum ClipCategory: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case all, text, images, screenshots, links, files, code, colors, pdfs

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: return "All"
        case .text: return "Text"
        case .images: return "Images"
        case .screenshots: return "Screenshots"
        case .links: return "Links"
        case .files: return "Files"
        case .code: return "Code"
        case .colors: return "Colors"
        case .pdfs: return "PDFs"
        }
    }

    /// `nil` means "no restriction".
    public var kinds: Set<ClipKind>? {
        switch self {
        case .all: return nil
        case .text: return [.text, .richText, .email, .phone, .address, .credential, .otp, .unknown]
        case .images: return [.image, .screenshot]
        case .screenshots: return [.screenshot]
        case .links: return [.url]
        case .files: return [.file, .folder]
        case .code: return [.code]
        case .colors: return [.color]
        case .pdfs: return [.pdf]
        }
    }

    /// Parses the value of a `type:` search token.
    public static func parse(_ raw: String) -> ClipCategory? {
        let value = raw.lowercased()
        if let exact = ClipCategory(rawValue: value) { return exact }
        switch value {
        case "txt", "string": return .text
        case "image", "img", "picture", "photo", "pic": return .images
        case "screenshot", "shot": return .screenshots
        case "link", "url", "urls": return .links
        case "file", "folder", "folders": return .files
        case "snippet", "snippets": return .code
        case "color", "colour", "colours": return .colors
        case "pdf": return .pdfs
        default: return nil
        }
    }
}
