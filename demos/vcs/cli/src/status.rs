//! Working-tree status: three comparisons, and nothing more.
//!
//! `HEAD tree ↔ index` gives what is staged. `index ↔ working tree` gives what is modified
//! but not staged. Anything in the working tree that the index has never heard of is
//! untracked. Every comparison is by content hash — no mtime heuristics, because in a POC a
//! wrong answer costs more than a re-read.

use crate::error::Result;
use crate::object::{Object, Tree};
use crate::repo::Repo;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Change {
    Added,
    Modified,
    Deleted,
}

impl Change {
    pub fn label(self) -> &'static str {
        match self {
            Change::Added => "new file",
            Change::Modified => "modified",
            Change::Deleted => "deleted",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Status {
    pub branch: String,
    pub head: Option<crate::object::ObjectId>,
    pub staged: Vec<(String, Change)>,
    pub unstaged: Vec<(String, Change)>,
    pub untracked: Vec<String>,
}

impl Status {
    pub fn is_clean(&self) -> bool {
        self.staged.is_empty() && self.unstaged.is_empty() && self.untracked.is_empty()
    }
}

pub fn status(repo: &Repo) -> Result<Status> {
    let index = repo.index()?;
    let head = repo.head_commit()?;

    let head_tree = match &head {
        Some(id) => repo.read_tree(&repo.read_commit(id)?.tree)?,
        None => Tree::default(),
    };

    let mut staged = Vec::new();
    for (path, entry) in &index.entries {
        match head_tree.get(path) {
            None => staged.push((path.clone(), Change::Added)),
            Some(committed) if committed.blob != entry.blob => {
                staged.push((path.clone(), Change::Modified))
            }
            Some(_) => {}
        }
    }
    for committed in &head_tree.entries {
        if !index.entries.contains_key(&committed.path) {
            staged.push((committed.path.clone(), Change::Deleted));
        }
    }

    let mut unstaged = Vec::new();
    for (path, entry) in &index.entries {
        let file = repo.workdir_path(path);

        if !file.is_file() {
            unstaged.push((path.clone(), Change::Deleted));
            continue;
        }

        let bytes = std::fs::read(&file).map_err(|e| crate::error::VcsError::io(&file, e))?;
        if Object::Blob(bytes).id()? != entry.blob {
            unstaged.push((path.clone(), Change::Modified));
        }
    }

    let untracked = repo
        .walk_workdir()?
        .into_iter()
        .filter(|path| !index.entries.contains_key(path))
        .collect();

    staged.sort();
    unstaged.sort();

    Ok(Status {
        branch: repo.current_branch()?,
        head,
        staged,
        unstaged,
        untracked,
    })
}
