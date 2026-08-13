/// Signing identities and service names for the app and the daemon (shared constants
/// on the Swift side). The two plists under Packaging/ and scripts/build-app.sh cannot
/// reference this file, so changing any identity string requires updating all three
/// places in sync (layout in ADR 0003).
public enum ChannelIdentity {
    /// The app's bundle identifier, which is also its code-signing identifier.
    public static let appBundleID = "com.heronapp.hostflip"
    /// The daemon's code-signing identifier, which is also the launchd Label and the Mach service name.
    public static let daemonIdentifier = "com.heronapp.hostflip.daemon"
    /// Name of the plist used for SMAppService registration (in the app bundle's Contents/Library/LaunchDaemons/).
    public static let daemonPlistName = "com.heronapp.hostflip.daemon.plist"
}

public enum HostflipBuild {
    /// Kept in sync with CFBundleShortVersionString in Packaging/HostflipApp-Info.plist.
    public static let version = "0.1.6"
}
