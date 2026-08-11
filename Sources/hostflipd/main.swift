import Foundation
import HostflipXPC
import os

// Entry point of the hostflip privileged daemon: publishes the Mach service and only accepts connections
// from a hostflip app signed with the same Team ID. All business logic lives in HostflipXPC.DaemonService
// (unit-testable); this file is only launchd/XPC glue.

/// Sets the code signing requirement before accepting a new connection; peers that fail it are rejected by the XPC runtime.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    // @unchecked: all stored properties are immutable
    private let service: DaemonService
    private let peerRequirement: String

    init(service: DaemonService, peerRequirement: String) {
        self.service = service
        self.peerRequirement = peerRequirement
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.setCodeSigningRequirement(peerRequirement)
        newConnection.exportedInterface = NSXPCInterface(with: DaemonXPC.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}

let logger = Logger(subsystem: ChannelIdentity.daemonIdentifier, category: "xpc")

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("hostflipd: \(message)\n".utf8))
    logger.fault("\(message, privacy: .public)")
    exit(code)
}

// If we are unsigned ourselves we cannot verify peers, so fail closed (EX_CONFIG; launchd will not restart endlessly).
guard let peerRequirement = try? SigningIdentity.peerRequirement(
    identifier: ChannelIdentity.appBundleID
) else {
    fail("Refusing to start: unsigned build or signing identity lacks a valid Team ID. See docs/signed-build-verification.md", code: 78)
}

// For signed-build integration verification: print the peer requirement that will be enforced, then exit.
if CommandLine.arguments.contains("--print-requirement") {
    print(peerRequirement)
    exit(0)
}

let delegate = ListenerDelegate(
    service: DaemonService(sink: SystemHostsWriter(), daemonVersion: HostflipBuild.version),
    peerRequirement: peerRequirement
)
let listener = NSXPCListener(machServiceName: ChannelIdentity.daemonIdentifier)
listener.delegate = delegate
listener.resume()
logger.info("hostflipd \(HostflipBuild.version, privacy: .public) listening on \(ChannelIdentity.daemonIdentifier, privacy: .public)")
RunLoop.main.run()
