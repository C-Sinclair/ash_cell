//! Repository discovery and the on-disk store.
//!
//! Nothing here knows about the CLI. Every write lands in a sibling temp file and is renamed
//! into place, so a crash leaves either the old file or the new one.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::path::{Component, Path, PathBuf};

use crate::error::{Result, VcsError};
use crate::object::{Object, ObjectId, Tree};

pub const META_DIR: &str = ".vcs";
pub const DEFAULT_BRANCH: &str = "main";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Head {
    /// A symbolic ref, always. Detached HEAD is out of scope.
    pub r#ref: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Config {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub remote: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub repo: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
}

#[derive(Debug, Clone)]
pub struct Repo {
    root: PathBuf,
}

impl Repo {
    /// Creates a repository at `root`, failing if one is already there.
    pub fn init(root: impl AsRef<Path>) -> Result<Self> {
        let root = root.as_ref();
        let meta = root.join(META_DIR);

        if meta.exists() {
            return Err(VcsError::AlreadyInitialised(meta));
        }

        for dir in [meta.join("objects"), meta.join("refs").join("heads")] {
            fs::create_dir_all(&dir).map_err(|e| VcsError::io(&dir, e))?;
        }

        let repo = Repo {
            root: root.to_path_buf(),
        };

        repo.write_head(&Head {
            r#ref: format!("refs/heads/{DEFAULT_BRANCH}"),
        })?;
        repo.write_index(&crate::index::Index::default())?;

        Ok(repo)
    }

    /// Walks up from `start` looking for `.vcs`, the way every VCS finds its root.
    pub fn discover(start: impl AsRef<Path>) -> Result<Self> {
        let start = start.as_ref();
        let start = fs::canonicalize(start).map_err(|e| VcsError::io(start, e))?;

        for candidate in start.ancestors() {
            if candidate.join(META_DIR).is_dir() {
                return Ok(Repo {
                    root: candidate.to_path_buf(),
                });
            }
        }

        Err(VcsError::NotARepository)
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn meta(&self) -> PathBuf {
        self.root.join(META_DIR)
    }

    // ---- objects -------------------------------------------------------------------

    fn object_path(&self, id: &ObjectId) -> PathBuf {
        let hex = id.as_str();
        self.meta().join("objects").join(&hex[..2]).join(&hex[2..])
    }

    pub fn has_object(&self, id: &ObjectId) -> bool {
        self.object_path(id).is_file()
    }

    /// Writes an object and returns its id. Idempotent: an object already present is left
    /// alone, because its bytes cannot differ from what we would have written.
    pub fn write_object(&self, object: &Object) -> Result<ObjectId> {
        let encoded = object.encode()?;
        self.write_object_bytes(&encoded)
    }

    pub fn write_object_bytes(&self, encoded: &[u8]) -> Result<ObjectId> {
        let id = crate::object::id_of(encoded);
        let path = self.object_path(&id);

        if path.is_file() {
            return Ok(id);
        }

        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|e| VcsError::io(parent, e))?;
        }
        atomic_write(&path, encoded)?;

        Ok(id)
    }

    pub fn read_object_bytes(&self, id: &ObjectId) -> Result<Vec<u8>> {
        let path = self.object_path(id);
        fs::read(&path).map_err(|e| match e.kind() {
            std::io::ErrorKind::NotFound => VcsError::UnknownRevision(id.short().to_string()),
            _ => VcsError::io(&path, e),
        })
    }

    pub fn read_object(&self, id: &ObjectId) -> Result<Object> {
        Object::decode(&self.read_object_bytes(id)?)
    }

    pub fn read_commit(&self, id: &ObjectId) -> Result<crate::object::Commit> {
        self.read_object(id)?.into_commit(id)
    }

    pub fn read_tree(&self, id: &ObjectId) -> Result<Tree> {
        self.read_object(id)?.into_tree(id)
    }

    /// Resolves a revision: a full id, a unique abbreviated id, `HEAD`, or a branch name.
    pub fn resolve(&self, revision: &str) -> Result<ObjectId> {
        let revision = revision.trim();

        if revision.eq_ignore_ascii_case("HEAD") {
            return self
                .head_commit()?
                .ok_or_else(|| VcsError::UnknownRevision("HEAD".into()));
        }

        if let Some(id) = self.read_ref(&format!("refs/heads/{revision}"))? {
            return Ok(id);
        }

        // Remote-tracking refs, so `checkout origin/main` can move a branch forward to what a
        // fetch brought in. Without this the only way back to the tip after checking out an
        // older commit would be to know its id.
        if let Some(id) = self.read_ref(&format!("refs/remotes/{revision}"))? {
            return Ok(id);
        }

        if revision.len() == 64 {
            let id = ObjectId::parse(revision)?;
            return if self.has_object(&id) {
                Ok(id)
            } else {
                Err(VcsError::UnknownRevision(revision.to_string()))
            };
        }

        self.resolve_prefix(revision)
    }

    fn resolve_prefix(&self, prefix: &str) -> Result<ObjectId> {
        let short = prefix.to_ascii_lowercase();
        let valid = short.len() >= 4 && short.bytes().all(|b| b.is_ascii_hexdigit());

        if !valid {
            return Err(VcsError::UnknownRevision(prefix.to_string()));
        }

        let matches: Vec<ObjectId> = self
            .all_object_ids()?
            .into_iter()
            .filter(|id| id.as_str().starts_with(&short))
            .collect();

        match matches.len() {
            0 => Err(VcsError::UnknownRevision(prefix.to_string())),
            1 => Ok(matches.into_iter().next().expect("length checked")),
            n => Err(VcsError::AmbiguousRevision(prefix.to_string(), n)),
        }
    }

    pub fn all_object_ids(&self) -> Result<Vec<ObjectId>> {
        let objects = self.meta().join("objects");
        let mut ids = Vec::new();

        let shards = match fs::read_dir(&objects) {
            Ok(shards) => shards,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(ids),
            Err(e) => return Err(VcsError::io(&objects, e)),
        };

        for shard in shards {
            let shard = shard.map_err(|e| VcsError::io(&objects, e))?;
            let prefix = shard.file_name().to_string_lossy().to_string();

            if !shard.path().is_dir() {
                continue;
            }

            for entry in fs::read_dir(shard.path()).map_err(|e| VcsError::io(shard.path(), e))? {
                let entry = entry.map_err(|e| VcsError::io(shard.path(), e))?;
                let name = entry.file_name().to_string_lossy().to_string();

                if let Ok(id) = ObjectId::parse(&format!("{prefix}{name}")) {
                    ids.push(id);
                }
            }
        }

        ids.sort();
        Ok(ids)
    }

    // ---- refs and HEAD -------------------------------------------------------------

    pub fn head(&self) -> Result<Head> {
        read_json(&self.meta().join("HEAD"), "HEAD")
    }

    pub fn write_head(&self, head: &Head) -> Result<()> {
        write_json(&self.meta().join("HEAD"), head, "HEAD")
    }

    /// The short name of the branch HEAD points at.
    pub fn current_branch(&self) -> Result<String> {
        let head = self.head()?;
        Ok(head
            .r#ref
            .strip_prefix("refs/heads/")
            .unwrap_or(&head.r#ref)
            .to_string())
    }

    pub fn head_commit(&self) -> Result<Option<ObjectId>> {
        self.read_ref(&self.head()?.r#ref)
    }

    fn ref_path(&self, name: &str) -> PathBuf {
        let mut path = self.meta();
        for part in name.split('/') {
            path.push(part);
        }
        path
    }

    pub fn read_ref(&self, name: &str) -> Result<Option<ObjectId>> {
        let path = self.ref_path(name);

        match fs::read_to_string(&path) {
            Ok(text) => Ok(Some(ObjectId::parse(&text)?)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(VcsError::io(&path, e)),
        }
    }

    pub fn write_ref(&self, name: &str, id: &ObjectId) -> Result<()> {
        let path = self.ref_path(name);

        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|e| VcsError::io(parent, e))?;
        }

        atomic_write(&path, format!("{id}\n").as_bytes())
    }

    /// Every remote-tracking ref we know of, keyed by full ref name.
    pub fn remote_refs(&self) -> Result<BTreeMap<String, ObjectId>> {
        let base = self.meta().join("refs").join("remotes").join("origin");
        let mut refs = BTreeMap::new();

        let entries = match fs::read_dir(&base) {
            Ok(entries) => entries,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(refs),
            Err(e) => return Err(VcsError::io(&base, e)),
        };

        for entry in entries {
            let entry = entry.map_err(|e| VcsError::io(&base, e))?;
            let name = entry.file_name().to_string_lossy().to_string();

            if let Some(id) = self.read_ref(&format!("refs/remotes/origin/{name}"))? {
                refs.insert(format!("refs/heads/{name}"), id);
            }
        }

        Ok(refs)
    }

    // ---- index and config ----------------------------------------------------------

    pub fn index(&self) -> Result<crate::index::Index> {
        read_json(&self.meta().join("index.json"), "index")
    }

    pub fn write_index(&self, index: &crate::index::Index) -> Result<()> {
        write_json(&self.meta().join("index.json"), index, "index")
    }

    pub fn config(&self) -> Result<Config> {
        let path = self.meta().join("config.json");

        if path.exists() {
            read_json(&path, "config")
        } else {
            Ok(Config::default())
        }
    }

    pub fn write_config(&self, config: &Config) -> Result<()> {
        write_json(&self.meta().join("config.json"), config, "config")
    }

    // ---- working tree --------------------------------------------------------------

    /// Turns any user-supplied path into a repo-relative one, refusing anything that escapes
    /// the repository or reaches into its metadata.
    pub fn relative(&self, path: &Path) -> Result<String> {
        let absolute = if path.is_absolute() {
            path.to_path_buf()
        } else {
            std::env::current_dir()
                .map_err(|e| VcsError::io(path, e))?
                .join(path)
        };

        // Resolve `.` and `..` without touching the filesystem, so a missing path still gets
        // the containment check rather than a confusing io error.
        let mut normalised = PathBuf::new();
        for component in absolute.components() {
            match component {
                Component::ParentDir => {
                    normalised.pop();
                }
                Component::CurDir => {}
                other => normalised.push(other),
            }
        }

        let root = fs::canonicalize(&self.root).map_err(|e| VcsError::io(&self.root, e))?;
        let relative = normalised
            .strip_prefix(&root)
            .map_err(|_| VcsError::PathOutsideRepo(path.to_path_buf()))?;

        if relative.components().next() == Some(Component::Normal(META_DIR.as_ref())) {
            return Err(VcsError::PathIsMetadata(path.to_path_buf()));
        }

        Ok(slashed(relative))
    }

    /// The working-tree path for a snapshot entry, refusing anything that escapes.
    ///
    /// Checkout is the one place a *remote* decides which files get written to a local disk, so
    /// a path is validated before it is joined, not after. A tree claiming `../../.ssh/authorized_keys`
    /// or `.vcs/HEAD` is refused rather than normalised into something harmless-looking.
    pub fn checkout_path(&self, relative: &str) -> Result<PathBuf> {
        let unsafe_path = || VcsError::UnsafeTreePath {
            path: relative.to_string(),
        };

        if relative.is_empty() || relative.starts_with('/') || relative.contains('\\') {
            return Err(unsafe_path());
        }

        for part in relative.split('/') {
            match part {
                "" | "." | ".." => return Err(unsafe_path()),
                META_DIR => return Err(unsafe_path()),
                _ => {}
            }
        }

        Ok(self.workdir_path(relative))
    }

    pub fn workdir_path(&self, relative: &str) -> PathBuf {
        let mut path = self.root.clone();
        for part in relative.split('/') {
            path.push(part);
        }
        path
    }

    /// Every regular file in the working tree, repo-relative, sorted. Skips `.vcs`.
    pub fn walk_workdir(&self) -> Result<Vec<String>> {
        let mut found = Vec::new();
        walk(&self.root, &self.root, &mut found)?;
        found.sort();
        Ok(found)
    }
}

fn walk(root: &Path, dir: &Path, found: &mut Vec<String>) -> Result<()> {
    for entry in fs::read_dir(dir).map_err(|e| VcsError::io(dir, e))? {
        let entry = entry.map_err(|e| VcsError::io(dir, e))?;
        let path = entry.path();
        let kind = entry.file_type().map_err(|e| VcsError::io(&path, e))?;

        if kind.is_dir() {
            if entry.file_name() == META_DIR {
                continue;
            }
            walk(root, &path, found)?;
        } else if kind.is_file() {
            if let Ok(relative) = path.strip_prefix(root) {
                found.push(slashed(relative));
            }
        }
        // Symlinks and everything else are out of scope, and skipping them beats guessing.
    }

    Ok(())
}

fn slashed(path: &Path) -> String {
    path.components()
        .map(|c| c.as_os_str().to_string_lossy())
        .collect::<Vec<_>>()
        .join("/")
}

/// Write to a temp file in the same directory, then rename. Same-directory matters: rename is
/// only atomic within a filesystem.
pub(crate) fn atomic_write(path: &Path, bytes: &[u8]) -> Result<()> {
    let parent = path.parent().unwrap_or(Path::new("."));
    let temp = parent.join(format!(
        ".{}.tmp{}",
        path.file_name().unwrap_or_default().to_string_lossy(),
        std::process::id()
    ));

    {
        let mut file = fs::File::create(&temp).map_err(|e| VcsError::io(&temp, e))?;
        file.write_all(bytes).map_err(|e| VcsError::io(&temp, e))?;
        file.sync_all().map_err(|e| VcsError::io(&temp, e))?;
    }

    fs::rename(&temp, path).map_err(|e| {
        let _ = fs::remove_file(&temp);
        VcsError::io(path, e)
    })
}

fn read_json<T: serde::de::DeserializeOwned>(path: &Path, what: &str) -> Result<T> {
    let bytes = fs::read(path).map_err(|e| match e.kind() {
        std::io::ErrorKind::NotFound => VcsError::NotARepository,
        _ => VcsError::io(path, e),
    })?;

    serde_json::from_slice(&bytes).map_err(|e| VcsError::json(what, e))
}

fn write_json<T: Serialize>(path: &Path, value: &T, what: &str) -> Result<()> {
    let mut bytes = serde_json::to_vec_pretty(value).map_err(|e| VcsError::json(what, e))?;
    bytes.push(b'\n');
    atomic_write(path, &bytes)
}
