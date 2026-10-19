import AppKit
import ClipivoCore
import CoreImage
import SwiftUI

/// Ways to support the developer. A fixed allow-list: the UI only ever opens these URLs, never
/// anything built from user input, and the feature makes no network requests of its own.
enum SupportLink: String, CaseIterable {
    case upi, wise, sponsor, star, issues

    static let upiID = "jishnumahanta17@oksbi"
    static let repositoryPath = "jishnumahanta/clipivo"

    /// The exact string encoded in the QR code (also in `assets/upi-qr.svg`).
    static let upiPayment = "upi://pay?pa=\(upiID)&pn=Jishnu%20Mahanta&cu=INR&tn=Support%20Clipivo"

    var url: URL {
        switch self {
        case .upi: return URL(string: Self.upiPayment)!
        case .wise: return URL(string: "https://wise.com/pay/business/jishnumahanta")!
        case .sponsor: return URL(string: "https://github.com/sponsors/jishnumahanta")!
        case .star: return URL(string: "https://github.com/\(Self.repositoryPath)")!
        case .issues: return URL(string: "https://github.com/\(Self.repositoryPath)/issues")!
        }
    }

    /// Opens in the user's default browser.
    func open() { NSWorkspace.shared.open(url) }
}

/// "Support Clipivo" window. Paying unlocks nothing; every feature is already free.
struct SupportView: View {
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "heart.fill").foregroundStyle(SupportHeart.color)
                    Text("Support \(Branding.productName)").font(.title2.weight(.semibold))
                }
                Text("Paying unlocks nothing. Every feature is already free.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Text("\(Branding.productName) is free, with no limits, and built by one developer in Guwahati, India. If it helped you, a small thank-you keeps it going.")
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    upiCard.frame(minWidth: 280)
                    anywhereCard.frame(width: 220)
                }
                VStack(spacing: 12) { upiCard; anywhereCard }
            }

            HStack(spacing: 8) {
                Text("Free ways to help:").font(.callout).foregroundStyle(.secondary)
                Button { SupportLink.star.open() } label: { Label("Star it on GitHub", systemImage: "star") }
                Button { SupportLink.issues.open() } label: { Label("Report a problem", systemImage: "exclamationmark.bubble") }
            }
            .buttonStyle(.borderless)

            Divider()
            Text("\(Branding.productName) \(GeneralSettings.versionString). Copyright © 2026 Jishnu Mahanta. Source available under the Clipivo Source-Available License.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(minWidth: 420, idealWidth: 580)
    }

    private var upiCard: some View {
        HStack(alignment: .top, spacing: 14) {
            UPIQRCode()
                .frame(width: 148, height: 148)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white))
                .accessibilityLabel("UPI QR code to pay Jishnu Mahanta")
            VStack(alignment: .leading, spacing: 6) {
                Text("UPI (India)").font(.headline)
                Text("Scan with Google Pay, PhonePe, Paytm or any UPI app.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    Text(SupportLink.upiID)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                    Button(copied ? "Copied" : "Copy", action: copyUPI)
                        .controlSize(.small)
                        .accessibilityLabel("Copy UPI ID")
                }
                if copied {
                    Text("UPI ID copied").font(.caption).foregroundStyle(.secondary).transition(.opacity)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }

    private var anywhereCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("From anywhere").font(.headline)
            Text("Card or bank transfer in your own currency.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 10)
            Button { SupportLink.wise.open() } label: { Text("Pay with Wise").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
            Button { SupportLink.sponsor.open() } label: { Text("GitHub Sponsors").frame(maxWidth: .infinity) }
                .controlSize(.large)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(card)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(0.04))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
    }

    private func copyUPI() {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(SupportLink.upiID, forType: .string)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { withAnimation { copied = false } }
    }
}

enum SupportHeart {
    static let color = Color(hex: 0xE5737F)
}

/// The UPI payment QR, rendered locally with Core Image (dark modules on white, always).
struct UPIQRCode: View {
    private static let image: NSImage? = {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(SupportLink.upiPayment.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        // Map black/white to the brand's near-black on pure white.
        let colored = output.applyingFilter("CIFalseColor", parameters: [
            "inputColor0": CIColor(red: 0x0E / 255, green: 0x15 / 255, blue: 0x12 / 255),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1),
        ])
        let scaled = colored.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }()

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image).interpolation(.none).resizable().aspectRatio(1, contentMode: .fit)
        } else {
            Image(systemName: "qrcode").resizable().aspectRatio(1, contentMode: .fit).foregroundStyle(.black)
        }
    }
}
