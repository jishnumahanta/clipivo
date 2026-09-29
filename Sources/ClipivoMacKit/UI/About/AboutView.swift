import AppKit
import ClipivoCore
import SwiftUI

/// The About window: app identity, version, and who makes it — laid out the way open-source Mac
/// apps usually credit their developer (copyright line, website, support contact).
struct AboutView: View {
    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text(Branding.productName)
                .font(.system(size: 22, weight: .bold)).padding(.top, 10)
            Text("Version \(GeneralSettings.versionString)")
                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 2)
            Text(Branding.tagline)
                .font(.callout).padding(.top, 10)

            Divider().padding(.vertical, 18).padding(.horizontal, 40)

            Link(destination: Branding.developerWebsite) {
                HStack(spacing: 10) {
                    DeveloperMark().frame(width: 42, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Made by").font(.caption).foregroundStyle(.secondary)
                        Text(Branding.developerName).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(Branding.developerWebsite.absoluteString)
            .accessibilityLabel("Made by \(Branding.developerName). Opens website.")

            HStack(spacing: 16) {
                Link("Website", destination: Branding.developerWebsite)
                if let mail = URL(string: "mailto:\(Branding.supportEmail)?subject=\(Branding.productName)%20support") {
                    Link("Support", destination: mail).help(Branding.supportEmail)
                }
            }
            .font(.callout).padding(.top, 14)

            Spacer(minLength: 16)
            Text(Branding.copyright)
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 36).padding(.bottom, 20).padding(.horizontal, 24)
        .frame(width: 340, height: 420)
        .ignoresSafeArea()
    }
}

/// The developer's "JM." mark, traced from the logo on jishnumahanta.in (48×32 design grid):
/// stroked J and M in the text color, with a blue dot.
struct DeveloperMark: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 48, size.height / 32)
            context.translateBy(x: (size.width - 48 * scale) / 2, y: (size.height - 32 * scale) / 2)
            context.scaleBy(x: scale, y: scale)

            var letters = Path()
            letters.move(to: CGPoint(x: 8.5, y: 7))
            letters.addLine(to: CGPoint(x: 8.5, y: 19.5))
            letters.addCurve(to: CGPoint(x: 4.5, y: 24), control1: CGPoint(x: 8.5, y: 22.5), control2: CGPoint(x: 7, y: 24))
            letters.addCurve(to: CGPoint(x: 1, y: 22), control1: CGPoint(x: 3, y: 24), control2: CGPoint(x: 1.5, y: 23))
            letters.move(to: CGPoint(x: 15, y: 24))
            letters.addLine(to: CGPoint(x: 15, y: 7))
            letters.addLine(to: CGPoint(x: 22, y: 18))
            letters.addLine(to: CGPoint(x: 29, y: 7))
            letters.addLine(to: CGPoint(x: 29, y: 24))
            context.stroke(letters, with: .foreground, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
            context.fill(Path(ellipseIn: CGRect(x: 35, y: 19, width: 6, height: 6)), with: .color(Color(hex: 0x58A5E4)))
        }
        .foregroundStyle(.primary)
        .accessibilityHidden(true)
    }
}
