import AppKit
import SwiftUI

/// What `/usr/local/bin/hostflip` currently is, probed before presenting.
enum CLIInstallLinkState: Equatable {
    case absent
    case linked(destination: String)
    case occupiedByFile
}

enum CLIInstallProbe {
    /// Reads the link without traversing it: `attributesOfItem` reports the
    /// symlink itself, so a broken link still counts as linked, not absent.
    static func linkState(at path: String) -> CLIInstallLinkState {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else {
            return .absent
        }
        guard attributes[.type] as? FileAttributeType == .typeSymbolicLink,
              let destination = try? fileManager.destinationOfSymbolicLink(atPath: path) else {
            return .occupiedByFile
        }
        return .linked(destination: destination)
    }
}

struct CLIInstallPresentation {
    static let linkPath = "/usr/local/bin/hostflip"

    let command: String
    let statusTitle: String
    let statusColor: Color

    init(cliPath: String, linkState: CLIInstallLinkState) {
        command = """
            sudo mkdir -p /usr/local/bin
            sudo ln -sf \(Self.shellQuoted(cliPath)) \(Self.linkPath)
            """
        switch linkState {
        case .absent:
            statusTitle = "Not linked yet"
            statusColor = .secondary
        case .linked(let destination) where destination == cliPath:
            statusTitle = "Linked at \(Self.linkPath)"
            statusColor = .green
        case .linked(let destination):
            statusTitle = "Links elsewhere: \(destination)"
            statusColor = .orange
        case .occupiedByFile:
            statusTitle = "Something else occupies \(Self.linkPath)"
            statusColor = .orange
        }
    }

    /// Quotes only when needed so the common /Applications path matches the
    /// README's install one-liner character for character.
    private static func shellQuoted(_ path: String) -> String {
        let safe = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-"
        )
        if path.unicodeScalars.allSatisfy(safe.contains) && !path.isEmpty {
            return path
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Settings > Command Line: the discoverable home of the CLI install command
/// (#58). It presents and copies the command instead of creating the link:
/// that needs root, and privileged work stays out of the app — the daemon's
/// XPC surface deliberately has exactly one operation (ADR-0009), so the user
/// runs the command in Terminal themselves. Homebrew installs never need it;
/// the cask links the CLI into the Homebrew bin directory on install.
struct CLIInstallSection: View {
    @State private var linkState: CLIInstallLinkState = .absent
    @State private var isShowingCopied = false

    private let cliPath = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Helpers/hostflip").path

    var body: some View {
        let presentation = CLIInstallPresentation(cliPath: cliPath, linkState: linkState)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Command-Line Tool", systemImage: "terminal")
                    .font(.subheadline.weight(.semibold))
                Text(
                    "The bundled hostflip command drives the same profiles and helper as the app. Homebrew puts it on your PATH automatically; for a direct download, run this once in Terminal:"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Text(presentation.command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(nil)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(presentation.statusColor)
                    Text(presentation.statusTitle)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button(isShowingCopied ? "Copied" : "Copy Command") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(presentation.command, forType: .string)
                    isShowingCopied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        isShowingCopied = false
                    }
                }
                .disabled(isShowingCopied)
            }
        }
        .task { linkState = CLIInstallProbe.linkState(at: CLIInstallPresentation.linkPath) }
    }
}
