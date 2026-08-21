//! The object model: content-addressed, typed, length-prefixed.
//!
//! An object's bytes on disk are `<kind> <payload-len>\0<payload>` and its id is the SHA-256
//! of that whole string. The header is why an id commits to the *type* as well as the
//! content — a blob and a tree with identical payloads get different ids — and why a
//! truncated object is detectable rather than merely wrong.
//!
//! SHA-256 rather than BLAKE3, which was the first choice and the wrong one. BLAKE3 is faster
//! and just as sound, but the server has to recompute every id it is sent — content addressing
//! is only a guarantee if somebody checks — and the server runs on the BEAM, where SHA-256 is
//! in `:crypto` and BLAKE3 is a Rust NIF that did not build. A hash both halves can compute
//! from their standard library beats a marginally faster one that only the client has.

use serde::{Deserialize, Serialize};
use std::fmt;

use crate::error::{Result, VcsError};

pub const ABBREV: usize = 12;

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ObjectId(String);

impl ObjectId {
    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn short(&self) -> &str {
        &self.0[..ABBREV.min(self.0.len())]
    }

    /// Accepts a hex digest read back from disk or the wire.
    pub fn parse(text: &str) -> Result<Self> {
        let text = text.trim();
        let valid = text.len() == 64 && text.bytes().all(|b| b.is_ascii_hexdigit());

        if valid {
            Ok(ObjectId(text.to_ascii_lowercase()))
        } else {
            Err(VcsError::UnknownRevision(text.to_string()))
        }
    }
}

impl fmt::Display for ObjectId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ObjectKind {
    Blob,
    Tree,
    Commit,
}

impl ObjectKind {
    pub fn as_str(self) -> &'static str {
        match self {
            ObjectKind::Blob => "blob",
            ObjectKind::Tree => "tree",
            ObjectKind::Commit => "commit",
        }
    }

    fn from_str(text: &str) -> Option<Self> {
        match text {
            "blob" => Some(ObjectKind::Blob),
            "tree" => Some(ObjectKind::Tree),
            "commit" => Some(ObjectKind::Commit),
            _ => None,
        }
    }
}

impl fmt::Display for ObjectKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// One entry in a tree: a repo-relative path and the blob holding its bytes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TreeEntry {
    pub path: String,
    pub blob: ObjectId,
    pub size: u64,
}

/// A flat snapshot of every tracked path.
///
/// Git nests trees so an untouched subdirectory is one shared id, which makes a commit cost
/// O(changed paths). We keep one flat tree per commit, so a commit costs O(tracked paths).
/// That is the wrong trade for a real system and the right one for a POC: the whole snapshot
/// is one readable JSON document.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Tree {
    pub entries: Vec<TreeEntry>,
}

impl Tree {
    /// Entries are sorted on construction, so an identical set of paths always hashes alike.
    pub fn new(mut entries: Vec<TreeEntry>) -> Self {
        entries.sort_by(|a, b| a.path.cmp(&b.path));
        Tree { entries }
    }

    pub fn get(&self, path: &str) -> Option<&TreeEntry> {
        self.entries.iter().find(|entry| entry.path == path)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Commit {
    pub tree: ObjectId,
    pub parent: Option<ObjectId>,
    pub message: String,
    /// RFC3339, UTC. Readable, and sorts lexically.
    pub timestamp: String,
    pub author: String,
}

/// A parsed object, ready to be hashed or written.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Object {
    Blob(Vec<u8>),
    Tree(Tree),
    Commit(Commit),
}

impl Object {
    pub fn kind(&self) -> ObjectKind {
        match self {
            Object::Blob(_) => ObjectKind::Blob,
            Object::Tree(_) => ObjectKind::Tree,
            Object::Commit(_) => ObjectKind::Commit,
        }
    }

    fn payload(&self) -> Result<Vec<u8>> {
        match self {
            Object::Blob(bytes) => Ok(bytes.clone()),
            // serde_json emits struct fields in declaration order, so this is canonical for
            // a given schema: same value in, same bytes out, same id.
            Object::Tree(tree) => {
                serde_json::to_vec(&tree.entries).map_err(|e| VcsError::json("tree", e))
            }
            Object::Commit(commit) => {
                serde_json::to_vec(commit).map_err(|e| VcsError::json("commit", e))
            }
        }
    }

    /// The full on-disk bytes, header included.
    pub fn encode(&self) -> Result<Vec<u8>> {
        let payload = self.payload()?;
        let mut bytes = format!("{} {}\0", self.kind().as_str(), payload.len()).into_bytes();
        bytes.extend_from_slice(&payload);
        Ok(bytes)
    }

    pub fn id(&self) -> Result<ObjectId> {
        Ok(id_of(&self.encode()?))
    }

    /// Parses bytes produced by [`Object::encode`], verifying the declared length.
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        let id = id_of(bytes).to_string();
        let corrupt = |why: &str| VcsError::CorruptObject {
            id: id.clone(),
            why: why.to_string(),
        };

        let nul = bytes
            .iter()
            .position(|&b| b == 0)
            .ok_or_else(|| corrupt("no header terminator"))?;
        let header =
            std::str::from_utf8(&bytes[..nul]).map_err(|_| corrupt("header is not utf-8"))?;
        let (kind, declared) = header
            .split_once(' ')
            .ok_or_else(|| corrupt("header has no length"))?;
        let kind =
            ObjectKind::from_str(kind).ok_or_else(|| corrupt(&format!("unknown type {kind}")))?;
        let declared: usize = declared
            .parse()
            .map_err(|_| corrupt("length is not a number"))?;

        let payload = &bytes[nul + 1..];
        if payload.len() != declared {
            return Err(corrupt(&format!(
                "declares {declared} bytes but carries {}",
                payload.len()
            )));
        }

        match kind {
            ObjectKind::Blob => Ok(Object::Blob(payload.to_vec())),
            ObjectKind::Tree => {
                let entries = serde_json::from_slice(payload)
                    .map_err(|e| corrupt(&format!("tree payload: {e}")))?;
                Ok(Object::Tree(Tree { entries }))
            }
            ObjectKind::Commit => {
                let commit = serde_json::from_slice(payload)
                    .map_err(|e| corrupt(&format!("commit payload: {e}")))?;
                Ok(Object::Commit(commit))
            }
        }
    }

    pub fn into_tree(self, id: &ObjectId) -> Result<Tree> {
        match self {
            Object::Tree(tree) => Ok(tree),
            other => Err(VcsError::WrongObjectType {
                id: id.to_string(),
                expected: "tree",
                found: other.kind().as_str().to_string(),
            }),
        }
    }

    pub fn into_commit(self, id: &ObjectId) -> Result<Commit> {
        match self {
            Object::Commit(commit) => Ok(commit),
            other => Err(VcsError::WrongObjectType {
                id: id.to_string(),
                expected: "commit",
                found: other.kind().as_str().to_string(),
            }),
        }
    }

    pub fn into_blob(self, id: &ObjectId) -> Result<Vec<u8>> {
        match self {
            Object::Blob(bytes) => Ok(bytes),
            other => Err(VcsError::WrongObjectType {
                id: id.to_string(),
                expected: "blob",
                found: other.kind().as_str().to_string(),
            }),
        }
    }
}

pub fn id_of(encoded: &[u8]) -> ObjectId {
    use sha2::Digest;

    let digest = sha2::Sha256::digest(encoded);
    let mut hex = String::with_capacity(64);

    for byte in digest {
        use std::fmt::Write;
        let _ = write!(hex, "{byte:02x}");
    }

    ObjectId(hex)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn id_commits_to_the_type_not_just_the_bytes() {
        let blob = Object::Blob(b"[]".to_vec());
        let tree = Object::Tree(Tree::default());

        assert_eq!(blob.payload().unwrap(), tree.payload().unwrap());
        assert_ne!(blob.id().unwrap(), tree.id().unwrap());
    }

    #[test]
    fn ids_are_stable_across_runs() {
        let blob = Object::Blob(b"hello\n".to_vec());
        assert_eq!(
            blob.id().unwrap(),
            Object::Blob(b"hello\n".to_vec()).id().unwrap()
        );
    }

    #[test]
    fn round_trips_every_kind() {
        let cases = vec![
            Object::Blob(b"\x00\xff binary is fine".to_vec()),
            Object::Tree(Tree::new(vec![TreeEntry {
                path: "a.txt".into(),
                blob: Object::Blob(b"a".to_vec()).id().unwrap(),
                size: 1,
            }])),
            Object::Commit(Commit {
                tree: Object::Tree(Tree::default()).id().unwrap(),
                parent: None,
                message: "first".into(),
                timestamp: "2026-08-20T00:00:00Z".into(),
                author: "someone".into(),
            }),
        ];

        for object in cases {
            let encoded = object.encode().unwrap();
            assert_eq!(Object::decode(&encoded).unwrap(), object);
        }
    }

    #[test]
    fn tree_entries_sort_so_order_does_not_change_the_id() {
        let entry = |path: &str| TreeEntry {
            path: path.into(),
            blob: Object::Blob(path.as_bytes().to_vec()).id().unwrap(),
            size: path.len() as u64,
        };

        let one = Tree::new(vec![entry("b"), entry("a")]);
        let two = Tree::new(vec![entry("a"), entry("b")]);

        assert_eq!(
            Object::Tree(one).id().unwrap(),
            Object::Tree(two).id().unwrap()
        );
    }

    #[test]
    fn truncation_is_detected() {
        let encoded = Object::Blob(b"twelve bytes".to_vec()).encode().unwrap();
        let err = Object::decode(&encoded[..encoded.len() - 3]).unwrap_err();
        assert!(matches!(err, VcsError::CorruptObject { .. }), "{err}");
    }

    #[test]
    fn a_tree_is_not_a_commit() {
        let id = ObjectId("0".repeat(64));
        let err = Object::Tree(Tree::default()).into_commit(&id).unwrap_err();
        assert!(matches!(err, VcsError::WrongObjectType { .. }), "{err}");
    }
}
