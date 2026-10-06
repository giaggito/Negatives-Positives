import DarkroomCore
import SwiftUI

/// Help → Credits & Licences: the app's own licence, then the work it builds on, each with its licence text.
public struct CreditsView: View {
    let app: String
    let credits: [Credit]
    let notice: String?
    let licenceText: (String) -> String?
    @State private var shown: String?

    /// `licenceText` finds the app's own licence files; the shared ones are found automatically.
    public init(app: String, credits: [Credit], notice: String? = nil, licenceText: @escaping (String) -> String? = { _ in nil }) {
        self.app = app
        self.credits = credits
        self.notice = notice
        self.licenceText = licenceText
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(app).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("\(SharedCredits.copyright). Free software: you may use, share and change it under the GNU General Public License, version 3. It comes with no warranty.")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                    licenceButton(SharedCredits.appLicenceFile, title: "GNU GPL 3.0")
                }
                Text("\(app) builds on the work of others").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                ForEach(credits) { c in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(c.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                        Text(c.what).font(.system(size: 11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                        Text("\(c.authors) · \(c.licence)").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                        HStack(spacing: 12) {
                            if let u = URL(string: c.link) { Link(c.link, destination: u).font(.system(size: 10)) }
                            if let f = c.file { licenceButton(f, title: "Licence…") }
                        }
                    }
                }
                if let notice {
                    Text(notice).font(.system(size: 10)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 480, minHeight: 420)
        .background(Theme.panel)
    }

    @ViewBuilder
    private func licenceButton(_ file: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(shown == file ? "Hide licence" : title) { shown = shown == file ? nil : file }
                .buttonStyle(.link).font(.system(size: 10))
            if shown == file, let t = licenceText(file) ?? SharedCredits.licenceText(file) {
                Text(t).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.secondary)
                    .textSelection(.enabled).padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.hairline.opacity(0.5)))
            }
        }
    }
}
