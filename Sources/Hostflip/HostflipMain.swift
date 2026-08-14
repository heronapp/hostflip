import Foundation
import HostflipCore
import HostflipXPC

/// App entry point: with no arguments, runs as the menu bar app; with arguments, runs a
/// one-shot diagnostic command for signed-build integration verification (docs/signed-build-verification.md).
@main
enum HostflipMain {
    static func main() async {
        switch CommandLine.arguments.dropFirst().first {
        case nil:
            HostflipApp.main()
        case "--status":
            print(DaemonRegistrationStatus.current().rawValue)
        case "--print-requirement":
            do {
                // The requirement the app enforces when connecting to the daemon (same Team ID + daemon identifier)
                print(try SigningIdentity.peerRequirement(identifiers: [ChannelIdentity.daemonIdentifier]))
            } catch {
                fail("Cannot construct peer requirement: \(error)")
            }
        case "--handshake":
            do {
                let reply = try await DaemonClient().handshake()
                print("protocolVersion=\(reply.protocolVersion) daemonVersion=\(reply.daemonVersion)")
            } catch {
                fail("Handshake failed: \(error)")
            }
        case "--switch":
            await performSwitch()
        case "--heal":
            // Launch self-heal path (re-registers on version change); print the rechecked status
            print(await DaemonRegistrar().healOnLaunch().rawValue)
        case "--unregister":
            do {
                try await DaemonRegistrar().unregister()
                print(DaemonRegistrationStatus.current().rawValue)
            } catch {
                fail("Unregister failed: \(error)")
            }
        case let flag?:
            fail("Unknown argument \(flag). Available: --status | --print-requirement | --handshake | --switch | --heal | --unregister")
        }
    }

    /// The real switch path: open the default workspace, merge, and write the system hosts through the gate.
    /// A first run imports Base Hosts from /etc/hosts (at which point the merged output matches the current system state).
    private static func performSwitch() async {
        do {
            let workspace = Workspace(rootDirectory: Workspace.defaultRootDirectory)
            let model = try workspace.open(systemHosts: {
                try String(contentsOf: URL(fileURLWithPath: "/etc/hosts"), encoding: .utf8)
            })
            let coordinator = SwitchCoordinator(
                registrar: DaemonRegistrar(),
                coordinator: MergeCoordinator(workspace: workspace, client: DaemonClient())
            )
            let outcome = try await coordinator.performSwitch(model.mergedHosts)
            // This is a diagnostic entry point: guidance picks the path, but
            // channel failures keep printing the underlying error and the
            // post-error status re-check, and always exit non-zero.
            switch outcome.guidance(targetHash: model.mergedHosts.hash) {
            case .merged(let hash):
                print("merged hash=\(hash)")
            case .needsApproval:
                if case .channelFailed(let error, let status) = outcome {
                    fail("Channel failed: \(error) (status after recheck: \(status.rawValue)); allow Hostflip in System Settings > General > Login Items & Extensions, then retry")
                }
                print("blocked=needsApproval")
                print("System approval requested: allow Hostflip in System Settings > General > Login Items & Extensions, then retry")
            case .unavailable:
                print("blocked=unavailable")
                print("Helper unavailable: make sure the app is fully installed (in Applications), then retry")
            case .hostsDrift:
                fail("System hosts changed outside hostflip; open the app, review the drift, then retry")
            case .writtenButFlushFailed(let failure):
                fail("System hosts was updated, but DNS refresh failed: \(failure.message)")
            case .failed(let error):
                var message = "Channel failed: \(error)"
                if case .channelFailed(_, let status) = outcome {
                    message += " (status after recheck: \(status.rawValue))"
                }
                fail(message)
            }
        } catch {
            fail("Switch failed: \(error)")
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Hostflip: \(message)\n".utf8))
        exit(1)
    }
}
