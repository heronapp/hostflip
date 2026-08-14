import Foundation
import Security

public enum CodeSigningRequirementError: Error, Equatable, Sendable {
    case invalidIdentifier(String)
    case invalidTeamID(String)
}

public enum CodeSigningRequirement {
    /// The requirement the peer must satisfy: one of the given signing identifiers,
    /// certificate chain anchored to Apple, matching Team ID. Inputs admit only the
    /// bundle-id character set and a 10-character uppercase alphanumeric Team ID,
    /// ruling out requirement syntax injection.
    ///
    /// The form is anchor apple generic + leaf[subject.OU]: in Apple developer
    /// certificates the Team ID is bound by Apple and cannot be spoofed; tightening
    /// further by certificate class (the Developer ID OID) would also reject builds
    /// signed with development certificates, so that is left for the release pipeline
    /// (M5 #27) to evaluate.
    public static func peerRequirement(identifiers: [String], teamID: String) throws -> String {
        guard !identifiers.isEmpty else {
            throw CodeSigningRequirementError.invalidIdentifier("")
        }
        for identifier in identifiers {
            guard !identifier.isEmpty, identifier.allSatisfy(identifierAlphabet.contains) else {
                throw CodeSigningRequirementError.invalidIdentifier(identifier)
            }
        }
        guard teamID.count == 10, teamID.allSatisfy(teamIDAlphabet.contains) else {
            throw CodeSigningRequirementError.invalidTeamID(teamID)
        }
        let identifierClause = identifiers.map { #"identifier "\#($0)""# }.joined(separator: " or ")
        // "or" binds looser than "and" in the requirement language, so the alternation
        // must be parenthesized to keep the anchor/Team ID constraints on every branch.
        let alternation = identifiers.count > 1 ? "(\(identifierClause))" : identifierClause
        return #"\#(alternation) and anchor apple generic and certificate leaf[subject.OU] = "\#(teamID)""#
    }

    private static let identifierAlphabet =
        Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
    private static let teamIDAlphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
}

/// The current process's own signing identity.
public struct SigningIdentity: Sendable {
    public let teamID: String

    /// Builds the peer requirement from this process's own signing identity (the peer
    /// must share this process's Team ID); an unsigned process fails closed. Both
    /// sides of the channel share this entry point.
    public static func peerRequirement(identifiers: [String]) throws -> String {
        guard let identity = current() else {
            throw DaemonChannelError.selfSigningUnavailable
        }
        return try CodeSigningRequirement.peerRequirement(identifiers: identifiers, teamID: identity.teamID)
    }

    /// Reads the Team ID from the current process's signature; returns nil when
    /// unsigned or ad-hoc signed (no certificate chain), which both sides of the
    /// channel treat as fail closed.
    public static func current() -> SigningIdentity? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else {
            return nil
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &info
        ) == errSecSuccess,
            let info = info as? [String: Any],
            let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
        else {
            return nil
        }
        return SigningIdentity(teamID: teamID)
    }
}
