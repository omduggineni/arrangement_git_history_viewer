import Foundation

let workingTreeRef = "WORKING"

struct CommitInfo: Equatable {
    var sha: String
    var shortSha: String
    var author: String
    var date: String
    var subject: String
}

enum FileStatus: String {
    case new, modified, deleted
}

/// Any uncommitted change in the working tree (not just .mscz files).
struct ChangedFile: Equatable {
    var path: String
    var status: FileStatus
    var isScore: Bool { path.hasSuffix(".mscz") }
}

struct BranchInfo: Equatable {
    /// e.g. "main", or "origin/feature" for a remote-only branch
    var name: String
    var isRemote: Bool
    var isCurrent: Bool
}

/// Where the current branch stands relative to its remote.
struct SyncStatus: Equatable {
    var branch = ""
    var isUnborn = false
    var hasRemote = false
    var upstream: String?
    var ahead = 0
    var behind = 0
}

/// One contiguous cluster of changed measures, rendered independently for each
/// side by measure number (not by page).
struct Excerpt {
    var label: String
    var start: Int
    var end: Int
    var svg1: String?
    var svg2: String?
}

struct DiffResult {
    var cost = 0
    var text = ""
    var excerpts: [Excerpt] = []
    var error: String?
}
