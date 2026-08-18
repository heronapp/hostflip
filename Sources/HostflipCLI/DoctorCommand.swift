import Darwin
import Foundation
import HostflipCore

/// `hostflip doctor <hostname>`: walks one hostname through the five diagnosis layers —
/// profiles, merge, file, resolver, guidance — and reports every layer's verdict (ADR-0014).
/// Contractually read-only and zero-XPC: the workspace is opened read-only, the resolver
/// layer asks the system resolver only (the getaddrinfo path every application takes), and
/// the daemon is never contacted, so doctor works identically while the daemon is unapproved.
/// No layer picks a "winner": the resolver returns every mapping and reorders mixed v4/v6
/// (the #66 measurements), so the report shows the sets side by side and only disagreement
/// between them is an inconsistency.
enum DoctorCommand {
    /// One hosts entry line naming the diagnosed hostname.
    struct Mapping: Encodable {
        /// The address field exactly as written.
        let ip: String
        /// The whole entry line, trimmed.
        let line: String
    }

    /// One place the hostname appears: Base Hosts or a profile.
    struct Appearance: Encodable {
        /// "Base Hosts", or the profile's reference (group/name for a member, the bare name
        /// for a standalone profile).
        let source: String
        /// The profile's unique ID; absent for Base Hosts.
        let id: String?
        /// Stable status code: base | active | active-paused | inactive.
        let status: String
        let mappings: [Mapping]
    }

    struct ProfilesLayer: Encodable {
        let layer = "profiles"
        /// found | not-found
        let code: String
        let appearances: [Appearance]
    }

    struct MergeLayer: Encodable {
        let layer = "merge"
        /// mapped | not-mapped | ambiguous (multiple different IPs within one address family)
        let code: String
        let mappings: [Mapping]
    }

    struct FileLayer: Encodable {
        let layer = "file"
        /// clean | drift
        let code: String
        /// Present only on drift: this hostname's entries in the expected merge output.
        let expected: [Mapping]?
        /// Present only on drift: this hostname's entries in the actual system hosts.
        let actual: [Mapping]?
    }

    struct ResolverLayer: Encodable {
        let layer = "resolver"
        /// match | mismatch | query-failed | no-mapping (nothing merged for this name;
        /// answers are DNS's)
        let code: String
        /// Numeric addresses in resolver order (RFC 6724 sorting, not file order).
        let addresses: [String]
        /// An answer fell in 198.18.0.0/15: a proxy's fake-IP DNS takeover (#66 measurement).
        let fakeIP: Bool
        let mixedFamilies: Bool
        /// Present when the query itself failed (not for an empty answer).
        let failure: String?
    }

    struct GuidanceLayer: Encodable {
        let layer = "guidance"
        /// system-consistent | system-inconsistent
        let code: String
        let advice: [String]
    }

    struct Payload: CommandPayload {
        let hostname: String
        let consistent: Bool
        let profiles: ProfilesLayer
        let merge: MergeLayer
        let file: FileLayer
        let resolver: ResolverLayer
        let guidance: GuidanceLayer

        var exitCode: ExitCode { consistent ? .success : .inconsistent }

        private enum CodingKeys: String, CodingKey {
            case hostname, consistent, layers
        }

        /// The layers are typed properties internally but one ordered array in the JSON
        /// contract, each element carrying its `layer` name and stable `code`.
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(hostname, forKey: .hostname)
            try container.encode(consistent, forKey: .consistent)
            var layers = container.nestedUnkeyedContainer(forKey: .layers)
            try layers.encode(profiles)
            try layers.encode(merge)
            try layers.encode(file)
            try layers.encode(resolver)
            try layers.encode(guidance)
        }

        var humanText: String {
            var lines = ["Doctor: \(hostname) — \(consistent ? "consistent" : "inconsistencies found")"]

            lines.append("")
            lines.append("Profiles:")
            if profiles.appearances.isEmpty {
                lines.append("  no entry in Base Hosts or any profile")
            }
            for appearance in profiles.appearances {
                lines.append("  \(appearance.source) (\(Self.statusText(appearance.status))):")
                lines.append(contentsOf: appearance.mappings.map { "    \($0.line)" })
            }

            lines.append("")
            lines.append("Merge:")
            if merge.mappings.isEmpty {
                lines.append("  no mapping in the merged output")
            }
            lines.append(contentsOf: merge.mappings.map { "  \($0.line)" })
            if merge.code == "ambiguous" {
                lines.append("  Warning: \(merge.mappings.count) mappings with different IPs — the resolver returns all of them; no entry wins over another.")
            }

            lines.append("")
            lines.append("File:")
            if file.code == "drift" {
                lines.append("  drift — the system hosts changed outside hostflip (reconcile in the Hostflip app)")
                lines.append("  Expected for this hostname:")
                lines.append(contentsOf: Self.entryLines(file.expected ?? []))
                lines.append("  Actual in the system hosts:")
                lines.append(contentsOf: Self.entryLines(file.actual ?? []))
            } else {
                lines.append("  no drift — the system hosts matches the last confirmed write")
            }

            lines.append("")
            lines.append("Resolver:")
            if let failure = resolver.failure {
                lines.append("  query failed: \(failure)")
            } else if resolver.addresses.isEmpty {
                lines.append("  returns no addresses (host not found)")
            } else {
                lines.append("  returns \(resolver.addresses.joined(separator: ", "))")
            }
            switch resolver.code {
            case "match":
                lines.append("  matches the merged mappings")
            case "mismatch":
                lines.append("  Mismatch: the resolver's answers do not match the merged mappings.")
            case "query-failed":
                lines.append("  the system resolver could not be queried, so the layers above could not be cross-checked")
            default:
                lines.append("  (no hosts mapping for this name — answers come from DNS)")
            }
            if resolver.mixedFamilies {
                lines.append("  Note: v4/v6 mixed — the system's address sorting (RFC 6724) decides the return order, not the hosts file.")
            }
            if resolver.fakeIP {
                lines.append("  Note: 198.18.0.0/15 addresses are fake-IP answers from a DNS-takeover proxy; hosts entries still win at the system resolver, but apps with built-in DNS/DoH bypass them.")
            }

            lines.append("")
            lines.append("Guidance:")
            if guidance.code == "system-consistent" {
                lines.append("  The system side is consistent. If an app still sees a different address, the cause is inside that app, beyond any hosts switcher's reach:")
                lines.append(contentsOf: guidance.advice.map { "  - \($0)" })
            } else {
                lines.append(contentsOf: guidance.advice.map { "  \($0)" })
            }
            return lines.joined(separator: "\n")
        }

        private static func statusText(_ status: String) -> String {
            switch status {
            case "base": return "always applied"
            case "active": return "active"
            case "active-paused": return "active, Paused — selection preserved, not applied"
            case "inactive": return "inactive — present, not applied"
            default: return status
            }
        }

        private static func entryLines(_ mappings: [Mapping]) -> [String] {
            mappings.isEmpty ? ["    (none)"] : mappings.map { "    \($0.line)" }
        }
    }

    static func run(
        hostname rawHostname: String,
        workspace: Workspace,
        systemHostsURL: URL,
        resolveHostname: (String) -> ResolverReply
    ) throws -> Payload {
        let hostname = normalize(hostname: rawHostname)
        guard !hostname.isEmpty else {
            throw CLIError.usage("'\(rawHostname)' is not a hostname")
        }
        let model = try workspace.openReadOnly()

        // ① Profiles: every place the hostname appears, with why it does or does not apply.
        var appearances: [Appearance] = []
        let baseMappings = mappings(for: hostname, in: model.baseHosts.content)
        if !baseMappings.isEmpty {
            appearances.append(Appearance(source: "Base Hosts", id: nil, status: "base", mappings: baseMappings))
        }
        func appendAppearance(of profile: Profile, group: String?) {
            let found = mappings(for: hostname, in: profile.content)
            guard !found.isEmpty else { return }
            let status = !model.activeProfileIDs.contains(profile.id) ? "inactive"
                : model.isPaused ? "active-paused"
                : "active"
            appearances.append(Appearance(
                source: group.map { "\($0)/\(profile.name)" } ?? profile.name,
                id: profile.id.rawValue,
                status: status,
                mappings: found
            ))
        }
        for profile in model.standaloneProfiles {
            appendAppearance(of: profile, group: nil)
        }
        for group in model.groups {
            for profile in group.profiles {
                appendAppearance(of: profile, group: group.name)
            }
        }
        let profilesLayer = ProfilesLayer(
            code: appearances.isEmpty ? "not-found" : "found",
            appearances: appearances
        )

        // ② Merge: every mapping in the merge output (which is Base Hosts alone while
        // paused); multiple different IPs are flagged, never adjudicated. Ambiguity is
        // judged per address family — a dual-stack v4+v6 pair (every macOS hosts file
        // carries one for localhost) is normal, not a duplicate-domain conflict.
        let mergedMappings = mappings(for: hostname, in: model.mergedHosts.content)
        let mergedIPs = Set(mergedMappings.map { canonicalAddress($0.ip) })
        let ambiguous = Dictionary(grouping: mergedIPs, by: addressFamily)
            .values.contains { $0.count > 1 }
        let mergeLayer = MergeLayer(
            code: mergedMappings.isEmpty ? "not-mapped" : ambiguous ? "ambiguous" : "mapped",
            mappings: mergedMappings
        )

        // ③ File: the shared drift verdict; on drift, this hostname's entries on both sides.
        let observation = try SystemHostsDrift.observe(workspace: workspace, systemHostsURL: systemHostsURL)
        let fileLayer = observation.drifted
            ? FileLayer(
                code: "drift",
                expected: mergedMappings,
                actual: mappings(for: hostname, in: observation.actualContent)
            )
            : FileLayer(code: "clean", expected: nil, actual: nil)

        // ④ Resolver: what the system actually returns, compared as sets against the merge.
        var addresses: [String] = []
        var failure: String?
        switch resolveHostname(hostname) {
        case .addresses(let list):
            addresses = list
        case .noSuchHost:
            break
        case .failed(let message):
            failure = message
        }
        // A failed query is its own finding, never a "mismatch" (the answers were not
        // observed) and never a silent pass: a broken system resolver is exactly the kind
        // of problem doctor exists to surface.
        let resolverCode = failure != nil ? "query-failed"
            : mergedMappings.isEmpty ? "no-mapping"
            : Set(addresses.map(canonicalAddress)) == mergedIPs ? "match"
            : "mismatch"
        let families = Set(addresses.map(isIPv4))
        let resolverLayer = ResolverLayer(
            code: resolverCode,
            addresses: addresses,
            fakeIP: addresses.contains(where: isFakeIP),
            mixedFamilies: families.count > 1,
            failure: failure
        )

        // ⑤ Guidance, by exclusion: doctor cannot observe other processes, so it only ever
        // points past the system side once everything it can observe agrees (ADR-0014
        // forbids any "detected a browser problem" claim).
        // The ambiguity warning never reaches the exit code: per ADR-0014 only set
        // disagreement between layers is an anomaly, and same-family multi-IP setups are
        // legitimate (round-robin test entries). Strict integrations gate on the stable
        // `merge.code` instead.
        let consistent = fileLayer.code == "clean"
            && resolverCode != "mismatch"
            && resolverCode != "query-failed"
        let guidanceLayer = consistent
            ? GuidanceLayer(code: "system-consistent", advice: [
                "Browsers keep a private DNS cache and reuse open connections for minutes; restart the browser, or clear its host cache and flush its socket pools.",
                "DNS-over-HTTPS (\"secure DNS\") bypasses the hosts file entirely; while it is on, hosts entries never take effect in that app.",
            ])
            : GuidanceLayer(code: "system-inconsistent", advice: [
                "Inconsistencies were found above; resolve them before suspecting a browser or app.",
            ])

        return Payload(
            hostname: hostname,
            consistent: consistent,
            profiles: profilesLayer,
            merge: mergeLayer,
            file: fileLayer,
            resolver: resolverLayer,
            guidance: guidanceLayer
        )
    }

    // MARK: - Hostname matching

    /// The matching rule: case-insensitive with one trailing (FQDN) dot stripped, applied to
    /// the query and to every name token alike; IDN forms are not translated.
    private static func normalize(hostname: String) -> String {
        var normalized = hostname.lowercased()
        if normalized.hasSuffix(".") {
            normalized.removeLast()
        }
        return normalized
    }

    /// Every entry line in `text` whose name tokens match `hostname` — all tokens count,
    /// alias positions included. Comments run from the first `#`; before that, the first
    /// field is the address and the rest are names (the HostsSyntax line rules).
    private static func mappings(for hostname: String, in text: String) -> [Mapping] {
        text.components(separatedBy: "\n").compactMap { line in
            let fields = line.prefix(while: { $0 != "#" })
                .split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2,
                  fields.dropFirst().contains(where: { normalize(hostname: String($0)) == hostname })
            else { return nil }
            return Mapping(
                ip: String(fields[0]),
                line: line.trimmingCharacters(in: .whitespaces)
            )
        }
    }

    // MARK: - Address forms

    /// Canonical textual form for set comparison ("0:0:0:0:0:0:0:1" == "::1"); text neither
    /// address family parses is compared lowercased as written.
    private static func canonicalAddress(_ text: String) -> String {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            _ = inet_ntop(AF_INET, &v4, &buffer, socklen_t(buffer.count))
            return CBuffer.string(buffer)
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            _ = inet_ntop(AF_INET6, &v6, &buffer, socklen_t(buffer.count))
            return CBuffer.string(buffer)
        }
        return text.lowercased()
    }

    private static func isIPv4(_ text: String) -> Bool {
        var v4 = in_addr()
        return inet_pton(AF_INET, text, &v4) == 1
    }

    private static func addressFamily(_ text: String) -> Int32 {
        if isIPv4(text) { return AF_INET }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 { return AF_INET6 }
        return AF_UNSPEC
    }

    /// 198.18.0.0/15 — the benchmarking block proxy software answers from when it takes
    /// over DNS with fake IPs (#66 measurement).
    private static func isFakeIP(_ text: String) -> Bool {
        var v4 = in_addr()
        guard inet_pton(AF_INET, text, &v4) == 1 else { return false }
        return UInt32(bigEndian: v4.s_addr) & 0xFFFE_0000 == 0xC612_0000
    }
}
