import Foundation
import HostflipCore

/// One user-facing way to address a profile: a bare name or `group/profile` path exactly as
/// typed, or the globally unique ID (`--id`) as the last-resort disambiguator.
enum ProfileReference: Equatable {
    case nameOrPath(String)
    case id(String)
}

/// Resolves a profile reference against the model. Names are not unique in any scope (only the
/// global ID is), so resolution finds exactly one profile or fails — it never silently picks one.
enum ProfileResolver {
    struct Match: Equatable {
        let profile: Profile
        /// The containing group's name; nil for a standalone profile.
        let groupName: String?
    }

    /// A profile a reference could mean, in the shape the ambiguity contract exposes: the `--json`
    /// error's `candidates` entries and the human candidate listing are both built from this.
    struct Candidate: Encodable, Equatable {
        let id: String
        let name: String
        /// The containing group's name; absent for a standalone profile.
        let group: String?

        /// The reference form shown to humans: `group/name` for a member, the bare name for a
        /// standalone profile (whose lack of a path prefix is exactly what --id exists for).
        var reference: String {
            group.map { "\($0)/\(name)" } ?? name
        }
    }

    enum Failure: Error, Equatable {
        case notFound(reference: String)
        /// The reference matched no name or path but is exactly some profile's unique ID: the
        /// caller pasted an ID (e.g. from an ambiguity listing) positionally, and the error
        /// must point at `--id` instead of a bare not-found. Name matching always wins first —
        /// names are arbitrary strings, so this fires only when nothing is named that way.
        case idPassedAsName(reference: String)
        case ambiguous(reference: String, candidates: [Candidate])
    }

    static func resolve(_ reference: ProfileReference, in model: ActivationModel) throws -> Match {
        let raw: String
        let matches: [Match]
        switch reference {
        case .id(let id):
            raw = id
            matches = entries(in: model).filter { $0.profile.id.rawValue == id }
        case .nameOrPath(let text):
            raw = text
            if let path = splitPath(text) {
                matches = entries(in: model).filter {
                    $0.groupName == path.group && $0.profile.name == path.name
                }
            } else {
                matches = entries(in: model).filter { $0.profile.name == text }
            }
        }
        guard let match = matches.first else {
            if case .nameOrPath = reference,
               entries(in: model).contains(where: { $0.profile.id.rawValue == raw }) {
                throw Failure.idPassedAsName(reference: raw)
            }
            throw Failure.notFound(reference: raw)
        }
        guard matches.count == 1 else {
            throw Failure.ambiguous(reference: raw, candidates: matches.map {
                Candidate(id: $0.profile.id.rawValue, name: $0.profile.name, group: $0.groupName)
            })
        }
        return match
    }

    /// The one path rule, shared with `create`'s target parsing: any slash makes the text a
    /// `group/profile` path, split on the first slash so member names may contain slashes
    /// themselves. A standalone profile or a group whose own name contains a slash is
    /// therefore reachable only through --id. Returns nil for a slashless bare name.
    static func splitPath(_ text: String) -> (group: String, name: String)? {
        guard let slash = text.firstIndex(of: "/") else { return nil }
        return (
            group: String(text[..<slash]),
            name: String(text[text.index(after: slash)...])
        )
    }

    /// Every profile in model order — standalone first, then each group's members.
    private static func entries(in model: ActivationModel) -> [Match] {
        model.standaloneProfiles.map { Match(profile: $0, groupName: nil) }
            + model.groups.flatMap { group in
                group.profiles.map { Match(profile: $0, groupName: group.name) }
            }
    }
}
