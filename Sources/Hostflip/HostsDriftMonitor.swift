import Darwin
import Foundation
import HostflipCore
import HostflipXPC

protocol HostsDriftMonitoring: Sendable {
    func start(onChange: @escaping @MainActor @Sendable (Bool) -> Void)
}

/// Watches the system hosts while the app is resident. All file descriptors and state are
/// confined to a serial queue; callbacks are only delivered to the MainActor and never
/// activate the app or open a window on their own.
final class HostsDriftMonitor:
    HostsDriftMonitoring,
    ConfirmedHostsWriteTracking,
    ExpectedHostsWriteObserving,
    @unchecked Sendable {
    private let workspace: Workspace
    private let hostsURL: URL
    private let queue = DispatchQueue(label: "com.heronapp.hostflip.hosts-drift-monitor")

    private var source: DispatchSourceFileSystemObject?
    private var isStarted = false
    private var retryScheduled = false
    private var pendingTargetWriteHashes: [String: Int] = [:]
    /// The latest target hash the daemon has confirmed but the manifest may not yet have successfully recorded.
    private var confirmedTargetHash: String?
    private var lastReportedDrift: Bool?
    private var lastReportedActualHash: String?
    private var onChange: (@MainActor @Sendable (Bool) -> Void)?

    init(
        workspace: Workspace,
        hostsURL: URL = URL(fileURLWithPath: "/etc/hosts")
    ) {
        self.workspace = workspace
        self.hostsURL = hostsURL
    }

    /// Idempotent start: arms the watcher first and then checks immediately, so no modification slips between the initial check and the watch.
    func start(onChange: @escaping @MainActor @Sendable (Bool) -> Void) {
        queue.async { [self] in
            self.onChange = onChange
            guard !isStarted else {
                checkNow()
                return
            }
            isStarted = true
            armSource()
            checkNow()
        }
    }

    func stop() {
        queue.sync { [self] in
            isStarted = false
            retryScheduled = false
            source?.cancel()
            source = nil
        }
    }

    /// Registers the target hash before the merge is sent. If the file event arrives before the
    /// daemon's reply, the target content is still recognized as our own expected write and no
    /// transient drift alert fires.
    func expectedWriteWillBegin(
        _ targetHash: String,
        replacingObservedHash: String? = nil
    ) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let actualHash = (try? Data(contentsOf: hostsURL)).map(MergedHosts.hash(of:))
                let persistedHash = try? workspace.expectedSystemHostsHash()
                let expectedHash = confirmedTargetHash ?? persistedHash
                // A regular write suppresses the target event only while the on-disk state is still
                // trusted; a reconcile write requires that state to still equal the hash the user
                // reviewed, so a different drifted version cannot enter the expected-write window.
                let isTrusted = actualHash == expectedHash
                    || actualHash.map { pendingTargetWriteHashes[$0] != nil } == true
                    || replacingObservedHash.map { actualHash == $0 } == true
                if isTrusted {
                    pendingTargetWriteHashes[targetHash, default: 0] += 1
                }
                continuation.resume()
            }
        }
    }

    /// Closes the expected-write window after a full merge finishes, then rechecks; if recording
    /// to the manifest failed, the target hash confirmed by this process is kept as the baseline.
    func expectedWriteDidEnd(_ targetHash: String) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if let count = pendingTargetWriteHashes[targetHash] {
                    if count == 1 {
                        pendingTargetWriteHashes.removeValue(forKey: targetHash)
                    } else {
                        pendingTargetWriteHashes[targetHash] = count - 1
                    }
                }
                if let persistedHash = try? workspace.expectedSystemHostsHash(),
                   persistedHash == confirmedTargetHash {
                    confirmedTargetHash = nil
                }
                checkNow()
                continuation.resume()
            }
        }
    }

    func expectedCurrentHash(persistedHash: String) async -> String {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: confirmedTargetHash ?? persistedHash)
            }
        }
    }

    func hostsWriteDidConfirm(_ targetHash: String) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                confirmedTargetHash = targetHash
                continuation.resume()
            }
        }
    }

    private func armSource() {
        guard isStarted, source == nil else { return }
        let descriptor = open(hostsURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            scheduleRearm()
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .revoke, .extend, .attrib],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.handleFileEvent()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        self.source = source
        source.resume()
    }

    private func handleFileEvent() {
        guard let source else { return }
        let event = source.data
        let needsRearm = !event.intersection([.delete, .rename, .revoke]).isEmpty

        checkNow()
        if needsRearm {
            source.cancel()
            self.source = nil
            armSource()
        }
    }

    private func scheduleRearm() {
        guard isStarted, !retryScheduled else { return }
        retryScheduled = true
        queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [self] in
            retryScheduled = false
            guard isStarted, source == nil else { return }
            armSource()
            checkNow()
        }
    }

    private func checkNow() {
        let actualHash = (try? Data(contentsOf: hostsURL)).map(MergedHosts.hash(of:))
        let persistedHash = try? workspace.expectedSystemHostsHash()
        let expectedHash = confirmedTargetHash ?? persistedHash
        let hasDrift: Bool
        if let actualHash, pendingTargetWriteHashes[actualHash] != nil {
            hasDrift = false
        } else if let actualHash, let expectedHash {
            hasDrift = actualHash != expectedHash
        } else {
            // Fail closed when the actual state or the baseline cannot be read: the content could not be safely confirmed before a write either.
            hasDrift = true
        }

        // Drift-free self-writes also need a notification so the read-only System Hosts page can update in real time.
        let shouldReport = hasDrift != lastReportedDrift
            || actualHash != lastReportedActualHash
        lastReportedDrift = hasDrift
        lastReportedActualHash = actualHash
        guard shouldReport else { return }
        guard let onChange else { return }
        Task { @MainActor in
            onChange(hasDrift)
        }
    }
}
