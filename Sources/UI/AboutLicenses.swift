import AppKit
import SwiftUI

struct LicensedComponent: Identifiable {
    let name: String
    let role: String
    let license: String
    let copyright: String
    let sourceURL: URL?
    let licenseFile: String

    var id: String { name }

    var licenseText: String {
        Self.loadLicense(licenseFile)
    }

    static func loadLicense(_ file: String) -> String {
        guard let url = Bundle.module.url(forResource: file, withExtension: "txt", subdirectory: "Licenses"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return L("License text is missing from this build.")
        }
        return text
    }
}

enum AboutLicenses {
    static let repositoryURL = URL(string: "https://github.com/gigimon/keemac")!
    static let keeMacCopyright = "Copyright © 2026 gigimon"

    /// Keep revisions in sync with scripts/build_vendor_frameworks.sh.
    static let components: [LicensedComponent] = [
        LicensedComponent(
            name: "KeePassKit",
            role: L("KeePass database engine (KDBX reading, writing and encryption)"),
            license: "GPL-3.0-or-later",
            copyright: "Copyright © 2012–2014 Michael Starke, HicknHack Software GmbH",
            sourceURL: URL(string: "https://github.com/MacPass/KeePassKit/tree/b5cf50ee4ebd67cb355792d7813965fe3ac7125e"),
            licenseFile: "KeePassKit"
        ),
        LicensedComponent(
            name: "KissXML",
            role: L("XML parser used by KeePassKit"),
            license: "BSD",
            copyright: "Copyright © 2012 Robbie Hanson",
            sourceURL: URL(string: "https://github.com/robbiehanson/KissXML/tree/990cdef080213b5a3f0d9709b845d553bd3ddb97"),
            licenseFile: "KissXML"
        ),
        LicensedComponent(
            name: "Argon2",
            role: L("Argon2 key derivation, bundled in KeePassKit"),
            license: "CC0-1.0 or Apache-2.0",
            copyright: "Copyright © 2015 Daniel Dinu, Dmitry Khovratovich, Jean-Philippe Aumasson and Samuel Neves",
            sourceURL: URL(string: "https://github.com/P-H-C/phc-winner-argon2/tree/b31aa322566a8559403d419b2e9cd3f57957e394"),
            licenseFile: "Argon2"
        ),
        LicensedComponent(
            name: "Twofish",
            role: L("Twofish cipher, bundled in KeePassKit"),
            license: "Permissive (attribution)",
            copyright: "Copyright © 2002 Niels Ferguson",
            sourceURL: URL(string: "https://github.com/MacPass/KeePassKit/tree/b5cf50ee4ebd67cb355792d7813965fe3ac7125e/TwoFish"),
            licenseFile: "Twofish"
        ),
        LicensedComponent(
            name: "ChaCha20",
            role: L("ChaCha20 cipher, bundled in KeePassKit"),
            license: "ISC-style",
            copyright: "Copyright © 2014 insane coder",
            sourceURL: URL(string: "https://github.com/MacPass/KeePassKit/tree/b5cf50ee4ebd67cb355792d7813965fe3ac7125e/ChaCha20"),
            licenseFile: "ChaCha20"
        ),
        LicensedComponent(
            name: "KeePassX",
            role: L("Portions of the KDBX format code in KeePassKit"),
            license: "GPL-2.0 or GPL-3.0",
            copyright: "Copyright © 2012 Felix Geyer",
            sourceURL: nil,
            licenseFile: "KeePassX"
        ),
        LicensedComponent(
            name: "MiniKeePass",
            role: L("Portions of the KeePass format code in KeePassKit"),
            license: "GPL-3.0-or-later",
            copyright: "Copyright © MiniKeePass contributors",
            sourceURL: nil,
            licenseFile: "MiniKeePass"
        ),
        LicensedComponent(
            name: "AQToolkit",
            role: L("Data utilities, notice shipped with KeePassKit"),
            license: "BSD",
            copyright: "Copyright © 2009 Jim Dovey",
            sourceURL: nil,
            licenseFile: "AQToolkit"
        ),
        LicensedComponent(
            name: "ShortcutRecorder",
            role: L("Notice shipped with KeePassKit"),
            license: "BSD",
            copyright: "Copyright © 2006 ShortcutRecorder contributors",
            sourceURL: nil,
            licenseFile: "ShortcutRecorder"
        ),
        LicensedComponent(
            name: "EFF Large Wordlist",
            role: L("Words for generated passphrases"),
            license: "CC BY 3.0 US",
            copyright: "Copyright © 2016 Electronic Frontier Foundation",
            sourceURL: URL(string: "https://www.eff.org/dice"),
            licenseFile: "EFF-Wordlist"
        ),
        LicensedComponent(
            name: "TweetNaCl",
            role: L("Encryption for the KeePassXC-Browser connection"),
            license: "Public domain",
            copyright: "Daniel J. Bernstein, Wesley Janssen, Tanja Lange, Peter Schwabe, Matthew Dempsky, Sjaak Smetsers",
            sourceURL: URL(string: "https://tweetnacl.cr.yp.to/20140427/"),
            licenseFile: "TweetNaCl"
        ),
        LicensedComponent(
            name: "bcrypt_pbkdf, Blowfish (OpenSSH)",
            role: L("Opening passphrase-protected SSH keys"),
            license: "ISC, BSD-3-Clause",
            copyright: "Ted Unangst, Niels Provos",
            sourceURL: URL(string: "https://github.com/openssh/openssh-portable/tree/V_9_9_P1/openbsd-compat"),
            licenseFile: "OpenSSH-bcrypt"
        )
    ]

    /// Release builds (from a vX.Y.Z tag) show "Version 1.2.0 (45)"; any other build carries its commit instead.
    static var versionLine: String {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String else {
            return L("Development build")
        }
        guard version.wholeMatch(of: /\d+\.\d+\.\d+/) != nil else {
            return L("Development build \(version)")
        }
        if let build = info?["CFBundleVersion"] as? String {
            return L("Version \(version) (\(build))")
        }
        return L("Version \(version)")
    }
}

struct AboutView: View {
    @State private var expandedComponent: String?
    @State private var shownLicense: ShownLicense?

    private struct ShownLicense: Identifiable {
        let title: String
        let text: String

        var id: String { title }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text("KeeMac")
                        .font(.system(size: 20, weight: .bold))
                    Text(AboutLicenses.versionLine)
                        .font(.system(size: 12))
                        .foregroundStyle(KM.textSecondary)
                    Text(AboutLicenses.keeMacCopyright)
                        .font(.system(size: 11))
                        .foregroundStyle(KM.textTertiary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L("License"))
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.leading, 4)
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("KeeMac is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License, version 3 or (at your option) any later version."))
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L("It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE."))
                        .font(.system(size: 11))
                        .foregroundStyle(KM.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button(L("View GPLv3")) {
                            shownLicense = ShownLicense(title: "GNU General Public License v3", text: LicensedComponent.loadLicense("GPLv3"))
                        }
                        .buttonStyle(KMButtonStyle(kind: .raised, height: 26, horizontalPadding: 12, fontWeight: .regular, fontSize: 12))
                        Link(destination: AboutLicenses.repositoryURL) {
                            Label(L("Source Code"), systemImage: "arrow.up.forward.square")
                                .font(.system(size: 12))
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(KM.insetFill)
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L("Third-party software"))
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.leading, 4)
                VStack(spacing: 0) {
                    ForEach(Array(AboutLicenses.components.enumerated()), id: \.element.id) { index, component in
                        componentRow(component, isFirst: index == 0)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(KM.insetFill)
                )
                Text(L("Breach Check queries the Pwned Passwords service by Troy Hunt (haveibeenpwned.com). Only the first five characters of each password’s SHA-1 hash are sent."))
                    .font(.system(size: 11))
                    .foregroundStyle(KM.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
            }
        }
        .sheet(item: $shownLicense) { license in
            LicenseTextSheet(title: license.title, text: license.text)
        }
    }

    private func componentRow(_ component: LicensedComponent, isFirst: Bool) -> some View {
        let isExpanded = expandedComponent == component.id
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    expandedComponent = isExpanded ? nil : component.id
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(KM.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(component.name)
                            .font(.system(size: 13))
                        Text(component.role)
                            .font(.system(size: 11))
                            .foregroundStyle(KM.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(component.license)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(KM.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(KM.accent.opacity(0.12)))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(component.copyright)
                        .font(.system(size: 11))
                        .foregroundStyle(KM.textSecondary)
                        .textSelection(.enabled)
                    HStack(spacing: 12) {
                        Button(L("View License")) {
                            shownLicense = ShownLicense(title: "\(component.name) — \(component.license)", text: component.licenseText)
                        }
                        .buttonStyle(KMButtonStyle(kind: .raised, height: 24, horizontalPadding: 10, fontWeight: .regular, fontSize: 11))
                        if let sourceURL = component.sourceURL {
                            Link(destination: sourceURL) {
                                Label(L("Source"), systemImage: "arrow.up.forward.square")
                                    .font(.system(size: 11))
                            }
                        }
                    }
                }
                .padding(.leading, 20)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            if !isFirst {
                Rectangle()
                    .fill(KM.hairline)
                    .frame(height: 0.5)
                    .padding(.horizontal, 14)
            }
        }
    }
}

private struct LicenseTextSheet: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(L("Done")) {
                    dismiss()
                }
                .buttonStyle(KMButtonStyle(kind: .primary, height: 26, horizontalPadding: 14, fontSize: 12))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Rectangle().fill(KM.hairline).frame(height: 0.5)

            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }
        }
        .frame(width: 620, height: 520)
        .background(KM.sheetBackground)
    }
}
