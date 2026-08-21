use std::path::PathBuf;

/// Everything that can go wrong in a way a user should hear about.
///
/// Variants describe situations, not plumbing: an `io::Error` on its own cannot say which
/// path failed, so every wrapped one carries it.
#[derive(Debug, thiserror::Error)]
pub enum VcsError {
    #[error("not a vcs repository (no .vcs directory here or in any parent)")]
    NotARepository,

    #[error("a vcs repository already exists at {0}")]
    AlreadyInitialised(PathBuf),

    #[error("path does not exist: {0}")]
    PathNotFound(PathBuf),

    #[error("path is outside the repository: {0}")]
    PathOutsideRepo(PathBuf),

    #[error("refusing to stage the repository metadata directory: {0}")]
    PathIsMetadata(PathBuf),

    #[error("cannot stage {0}: not a regular file")]
    NotARegularFile(PathBuf),

    #[error("nothing staged; use `vcs add <paths...>` first")]
    NothingStaged,

    #[error("nothing to commit: the staged tree matches HEAD (use --allow-empty to force)")]
    EmptyCommit,

    #[error("unknown revision: {0}")]
    UnknownRevision(String),

    #[error("ambiguous revision {0}: matches {1} objects")]
    AmbiguousRevision(String, usize),

    #[error("object {id} is corrupt: {why}")]
    CorruptObject { id: String, why: String },

    #[error("expected {id} to be a {expected}, found a {found}")]
    WrongObjectType {
        id: String,
        expected: &'static str,
        found: String,
    },

    #[error("no remote configured; use `vcs remote <url> <owner/name>`")]
    NoRemote,

    #[error(
        "refusing to overwrite local changes to {count} path(s); commit them, or pass --force \
         to discard them"
    )]
    DirtyWorkingTree { count: usize },

    #[error("refusing to check out {path}: a snapshot path must stay inside the repository")]
    UnsafeTreePath { path: String },

    #[error("{0} already exists and is not empty")]
    TargetNotEmpty(PathBuf),

    #[error("the server has no branches to clone")]
    NothingToClone,

    #[error(
        "non-fast-forward: the server has {server}, which is not an ancestor of {local}. \
         Fetch first."
    )]
    NonFastForward { server: String, local: String },

    #[error("nothing to push: the server already has {0}")]
    NothingToPush(String),

    #[error("server returned {status}: {message}")]
    Server { status: u16, message: String },

    #[error("could not reach the server at {url}: {source}")]
    Transport {
        url: String,
        #[source]
        source: Box<ureq::Error>,
    },

    #[error("{path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },

    #[error("malformed {what}: {source}")]
    Json {
        what: String,
        #[source]
        source: serde_json::Error,
    },
}

pub type Result<T> = std::result::Result<T, VcsError>;

impl VcsError {
    pub(crate) fn io(path: impl Into<PathBuf>, source: std::io::Error) -> Self {
        VcsError::Io {
            path: path.into(),
            source,
        }
    }

    pub(crate) fn json(what: impl Into<String>, source: serde_json::Error) -> Self {
        VcsError::Json {
            what: what.into(),
            source,
        }
    }
}
