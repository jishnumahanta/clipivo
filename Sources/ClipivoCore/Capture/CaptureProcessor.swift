import Foundation

/// What to do with clips that look sensitive.
public enum SensitiveContentPolicy: String, Codable, Sendable, CaseIterable {
    /// Store normally.
    case save
    /// Store encrypted and hidden until the user unlocks Clipivo.
    case saveAsPrivate
    /// Hold in memory and let the user decide.
    case ask
    /// Never store.
    case discard

    public var displayName: String {
        switch self {
        case .save: return "Always save"
        case .saveAsPrivate: return "Save as private"
        case .ask: return "Ask"
        case .discard: return "Never save"
        }
    }
}

/// All user choices that influence capture. A value type so the platform layer can snapshot
/// preferences and hand them to the processor without sharing mutable state.
public struct CapturePolicy: Sendable {
    public var isPaused = false
    public var ignoredBundleIDs: Set<String> = []
    /// Password-manager and `ConcealedType` clips.
    public var concealedPolicy: SensitiveContentPolicy = .discard
    /// Clips with likely secrets (keys, tokens, private keys, card numbers).
    public var sensitivePolicy: SensitiveContentPolicy = .ask
    /// Standalone one-time codes. They are useless minutes later, so the default is not to keep them.
    public var oneTimeCodePolicy: SensitiveContentPolicy = .discard
    /// Respect `org.nspasteboard.TransientType` (content that should never appear in history).
    public var honorTransientMarker = true
    public var duplicatePolicy: DuplicatePolicy = .moveToTop
    /// Maximum bytes kept for a single representation. `nil` means no limit.
    public var maxRepresentationBytes: Int? = 200 * 1024 * 1024
    /// Representations of non-preferred types are kept only below this size.
    public var maxOtherRepresentationBytes = 2 * 1024 * 1024
    public var privateStorageAvailable = true

    public init() {}
}

public enum CaptureOutcome: Sendable {
    case stored(StoreResult, ClipKind)
    case needsConfirmation(PendingCapture)
    case skipped(SkipReason)
}

public enum SkipReason: String, Sendable, Equatable {
    case paused
    case ignoredApplication
    case transient
    case concealed
    case sensitive
    case oneTimeCode
    case empty
    case tooLarge
}

/// A sensitive clip awaiting the user's decision. Lives only in memory.
public struct PendingCapture: Sendable, Identifiable {
    public let id = UUID()
    public var prepared: PreparedClip
    public var findings: [SensitiveContentDetector.Finding]
    public var receivedAt: Date
}

/// Turns clipboard snapshots into stored clips according to `CapturePolicy`.
///
/// Ordering matters for privacy: pause and ignored-app checks happen before any content is
/// inspected, and nothing is written (no blob, thumbnail or OCR) for a clip that is rejected.
public struct CaptureProcessor: Sendable {
    public let library: ClipLibrary

    public init(library: ClipLibrary) {
        self.library = library
    }

    /// Cheap pre-check the platform monitor calls *before* reading clipboard contents.
    public static func shouldRead(sourceBundleID: String?, policy: CapturePolicy) -> SkipReason? {
        if policy.isPaused { return .paused }
        if let id = sourceBundleID, policy.ignoredBundleIDs.contains(id) { return .ignoredApplication }
        return nil
    }

    public func process(_ snapshot: ClipboardSnapshot, policy: CapturePolicy) async throws -> CaptureOutcome {
        switch prepare(snapshot, policy: policy) {
        case .skip(let reason):
            return .skipped(reason)
        case .pending(let pending):
            return .needsConfirmation(pending)
        case .ready(let prepared):
            let result = try await library.store(prepared, duplicatePolicy: policy.duplicatePolicy)
            return .stored(result, prepared.kind)
        }
    }

    public enum Preparation: Sendable {
        case skip(SkipReason)
        case pending(PendingCapture)
        case ready(PreparedClip)
    }

    /// Pure decision step (no I/O). Exposed for testing.
    public func prepare(_ snapshot: ClipboardSnapshot, policy: CapturePolicy) -> Preparation {
        if let reason = Self.shouldRead(sourceBundleID: snapshot.sourceApp?.bundleID, policy: policy) { return .skip(reason) }
        if policy.honorTransientMarker && snapshot.isTransient { return .skip(.transient) }

        var filtered = Self.filterRepresentations(snapshot, policy: policy)
        guard !filtered.allRepresentations.isEmpty else {
            return .skip(snapshot.allRepresentations.isEmpty ? .empty : .tooLarge)
        }
        filtered.declaredTypes = snapshot.declaredTypes

        let classification = ContentClassifier.classify(filtered)
        if classification.kind == .unknown && classification.searchableText.isEmpty && filtered.allRepresentations.allSatisfy({ $0.data.isEmpty }) {
            return .skip(.empty)
        }

        var isPrivate = false
        let findings = classification.sensitivity.findings
        let decision: SensitiveContentPolicy?
        if findings.contains(.passwordManager) {
            decision = policy.concealedPolicy
        } else if classification.sensitivity.level == .likely {
            decision = policy.sensitivePolicy
        } else if classification.kind == .otp {
            decision = policy.oneTimeCodePolicy
        } else {
            decision = nil
        }

        let prepared = PreparedClip(
            kind: classification.kind, autoTitle: classification.autoTitle, metadata: classification.metadata,
            searchableText: classification.searchableText, plainText: classification.plainText,
            representations: filtered.allRepresentations,
            contentHash: PreparedClip.contentHash(kind: classification.kind, snapshot: filtered, plainText: classification.plainText),
            sourceApp: snapshot.sourceApp, createdAt: snapshot.capturedAt,
            sensitivity: classification.sensitivity.level, urlString: classification.urlString)

        switch decision {
        case .none, .save?:
            break
        case .discard?:
            if findings.contains(.passwordManager) { return .skip(.concealed) }
            return .skip(classification.kind == .otp ? .oneTimeCode : .sensitive)
        case .saveAsPrivate?:
            isPrivate = policy.privateStorageAvailable
        case .ask?:
            return .pending(PendingCapture(prepared: prepared, findings: findings, receivedAt: snapshot.capturedAt))
        }

        var final = prepared
        final.isPrivate = isPrivate
        return .ready(final)
    }

    /// Drops marker/ignored types, redundant image encodings and oversized payloads.
    static func filterRepresentations(_ snapshot: ClipboardSnapshot, policy: CapturePolicy) -> ClipboardSnapshot {
        var result = snapshot
        result.items = snapshot.items.map { item in
            let types = Set(item.map(\.type))
            return item.filter { rep in
                if RepresentationType.isIgnored(rep.type) { return false }
                // TIFF is usually an uncompressed duplicate of the PNG; PNG is lossless, so keep only PNG.
                if rep.type == RepresentationType.tiff && types.contains(RepresentationType.png) { return false }
                if let max = policy.maxRepresentationBytes, rep.data.count > max { return false }
                if !RepresentationType.preferred.contains(rep.type) && rep.data.count > policy.maxOtherRepresentationBytes { return false }
                return true
            }
        }.filter { !$0.isEmpty }
        return result
    }
}
