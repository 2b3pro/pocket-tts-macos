//
//  BuildInfo.swift — build/version stamp for the pockettts daemon.
//
//  These DEFAULT values represent an UNSTAMPED dev build (a bare `swift build`).
//  `scripts/deploy-daemon.sh` rewrites this file with the real git SHA, branch,
//  dirty flag and timestamp immediately before a release build, then restores it
//  afterward (from a backup copy). So any *deployed* binary reports its exact
//  provenance via `pockettts --version` and `GET /health` — which is how we tell
//  whether the running daemon matches source HEAD.
//

// MARK: - BuildInfo

nonisolated enum BuildInfo {
    /// Short git SHA the binary was built from ("unknown" for a bare dev build).
    static let gitSHA  = "unknown"
    /// Branch the binary was built from.
    static let branch  = "unknown"
    /// Whether the working tree had uncommitted changes at build time.
    static let dirty   = true
    /// ISO-8601 UTC timestamp when the version was stamped ("dev" if unstamped).
    static let builtAt = "dev"
    /// Human-facing tag, e.g. a release name; defaults to the short SHA at deploy.
    static let version = "dev"

    /// One-line provenance string for `--version` and logs.
    static var summary: String {
        "pockettts \(version) (\(gitSHA)\(dirty ? "-dirty" : "") · \(branch) · built \(builtAt))"
    }
    // /health builds its provenance dict inline from the scalar statics above —
    // a [String: Any] property can't cross the daemon's MainActor boundary.
}
