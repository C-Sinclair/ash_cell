//! The staging area.
//!
//! A blob is written to the object store the moment a path is staged, so a later commit is
//! independent of what happens to the working tree in between — that is the whole reason the
//! index holds an object id rather than a path.
//!
//! After a commit the index is reset *to the committed tree* rather than emptied. An empty
//! index would make every tracked file look untracked, and "cleared" in the sense that
//! matters — nothing shows as staged — is exactly what index-equals-HEAD gives.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

use crate::object::{ObjectId, Tree, TreeEntry};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IndexEntry {
    pub blob: ObjectId,
    pub size: u64,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Index {
    /// A `BTreeMap` so the file is stable and diffs are readable.
    #[serde(default)]
    pub entries: BTreeMap<String, IndexEntry>,
}

impl Index {
    pub fn stage(&mut self, path: impl Into<String>, blob: ObjectId, size: u64) {
        self.entries.insert(path.into(), IndexEntry { blob, size });
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn tree(&self) -> Tree {
        Tree::new(
            self.entries
                .iter()
                .map(|(path, entry)| TreeEntry {
                    path: path.clone(),
                    blob: entry.blob.clone(),
                    size: entry.size,
                })
                .collect(),
        )
    }

    pub fn from_tree(tree: &Tree) -> Self {
        Index {
            entries: tree
                .entries
                .iter()
                .map(|entry| {
                    (
                        entry.path.clone(),
                        IndexEntry {
                            blob: entry.blob.clone(),
                            size: entry.size,
                        },
                    )
                })
                .collect(),
        }
    }
}
