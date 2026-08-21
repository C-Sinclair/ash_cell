//! The commands, as domain operations. No printing happens here.

use std::path::Path;

use crate::error::{Result, VcsError};
use crate::index::Index;
use crate::object::{Commit, Object, ObjectId, Tree};
use crate::repo::Repo;

/// What `add` did, so the CLI can report a deletion as a deletion.
pub struct Added {
    pub staged: Vec<String>,
    pub removed: Vec<String>,
}

/// Stages files. Directories are recursed; `.vcs` is skipped.
///
/// A path that is tracked but no longer on disk stages its *deletion*, the way `git add` does.
/// Without that there is no way to record a removal at all: the index would keep the entry
/// forever and every later commit would carry a file the working tree does not have.
///
/// Nothing is staged unless every argument resolves, so a typo in the third path does not leave
/// the first two half-staged.
pub fn add(repo: &Repo, paths: &[impl AsRef<Path>]) -> Result<Added> {
    let mut index = repo.index()?;
    let mut targets: Vec<String> = Vec::new();
    let mut removals: Vec<String> = Vec::new();

    for path in paths {
        let path = path.as_ref();
        let relative = repo.relative(path)?;
        let absolute = if relative.is_empty() {
            repo.root().to_path_buf()
        } else {
            repo.workdir_path(&relative)
        };
        let prefix = if relative.is_empty() {
            String::new()
        } else {
            format!("{relative}/")
        };

        if absolute.is_dir() {
            targets.extend(
                repo.walk_workdir()?
                    .into_iter()
                    .filter(|candidate| candidate.starts_with(&prefix)),
            );

            // Tracked files under this directory that are gone from disk.
            removals.extend(vanished(repo, &index, &prefix));
        } else if absolute.is_file() {
            targets.push(relative);
        } else if absolute.exists() {
            return Err(VcsError::NotARegularFile(path.to_path_buf()));
        } else if index.entries.contains_key(&relative) {
            removals.push(relative);
        } else {
            let under = vanished(repo, &index, &prefix);

            if under.is_empty() {
                return Err(VcsError::PathNotFound(path.to_path_buf()));
            }

            removals.extend(under);
        }
    }

    targets.sort();
    targets.dedup();
    removals.sort();
    removals.dedup();

    for relative in &targets {
        let file = repo.workdir_path(relative);
        let bytes = std::fs::read(&file).map_err(|e| VcsError::io(&file, e))?;
        let size = bytes.len() as u64;
        let blob = repo.write_object(&Object::Blob(bytes))?;

        index.stage(relative.clone(), blob, size);
    }

    for relative in &removals {
        index.entries.remove(relative);
    }

    repo.write_index(&index)?;

    Ok(Added {
        staged: targets,
        removed: removals,
    })
}

fn vanished(repo: &Repo, index: &Index, prefix: &str) -> Vec<String> {
    index
        .entries
        .keys()
        .filter(|path| path.starts_with(prefix))
        .filter(|path| !repo.workdir_path(path).is_file())
        .cloned()
        .collect()
}

pub struct Committed {
    pub id: ObjectId,
    pub commit: Commit,
    pub paths: usize,
}

pub fn commit(repo: &Repo, message: &str, author: &str, allow_empty: bool) -> Result<Committed> {
    let index = repo.index()?;
    let parent = repo.head_commit()?;

    if index.is_empty() && parent.is_none() && !allow_empty {
        return Err(VcsError::NothingStaged);
    }

    let tree = index.tree();
    let tree_id = repo.write_object(&Object::Tree(tree.clone()))?;

    if !allow_empty {
        if let Some(parent) = &parent {
            if repo.read_commit(parent)?.tree == tree_id {
                return Err(VcsError::EmptyCommit);
            }
        }
    }

    let commit = Commit {
        tree: tree_id,
        parent,
        message: message.to_string(),
        timestamp: now_rfc3339(),
        author: author.to_string(),
    };

    let id = repo.write_object(&Object::Commit(commit.clone()))?;
    repo.write_ref(&repo.head()?.r#ref, &id)?;
    // Reset rather than empty: see the note on `Index`.
    repo.write_index(&Index::from_tree(&tree))?;

    Ok(Committed {
        id,
        commit,
        paths: tree.entries.len(),
    })
}

/// HEAD first, then each parent. Stops at the root, or at `limit` commits.
pub fn log(
    repo: &Repo,
    start: Option<&str>,
    limit: Option<usize>,
) -> Result<Vec<(ObjectId, Commit)>> {
    let mut next = match start {
        Some(revision) => Some(repo.resolve(revision)?),
        None => repo.head_commit()?,
    };
    let mut history = Vec::new();

    while let Some(id) = next {
        if limit.is_some_and(|limit| history.len() >= limit) {
            break;
        }

        let commit = repo.read_commit(&id)?;
        next = commit.parent.clone();
        history.push((id, commit));
    }

    Ok(history)
}

pub fn show(repo: &Repo, revision: Option<&str>) -> Result<(ObjectId, Commit, Tree)> {
    let id = match revision {
        Some(revision) => repo.resolve(revision)?,
        None => repo
            .head_commit()?
            .ok_or_else(|| VcsError::UnknownRevision("HEAD".into()))?,
    };

    let commit = repo.read_commit(&id)?;
    let tree = repo.read_tree(&commit.tree)?;

    Ok((id, commit, tree))
}

/// Every object reachable from `id`: the commit chain, each tree, and every blob in it.
pub fn reachable(repo: &Repo, id: &ObjectId, stop_at: &[ObjectId]) -> Result<Vec<ObjectId>> {
    let mut found = Vec::new();
    let mut next = Some(id.clone());

    while let Some(commit_id) = next {
        if stop_at.contains(&commit_id) {
            break;
        }

        let commit = repo.read_commit(&commit_id)?;
        let tree = repo.read_tree(&commit.tree)?;

        found.push(commit_id);
        found.push(commit.tree.clone());
        found.extend(tree.entries.iter().map(|entry| entry.blob.clone()));

        next = commit.parent.clone();
    }

    found.sort();
    found.dedup();
    Ok(found)
}

fn now_rfc3339() -> String {
    let now = time::OffsetDateTime::now_utc()
        .replace_nanosecond(0)
        .unwrap_or_else(|_| time::OffsetDateTime::now_utc());

    now.format(&time::format_description::well_known::Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_string())
}

pub struct Checkout {
    pub id: ObjectId,
    pub commit: Commit,
    pub written: Vec<String>,
    pub removed: Vec<String>,
}

/// Materialises a commit's snapshot into the working tree.
///
/// With no branches there is nothing to distinguish this from `git reset --hard`, so it does
/// both jobs: the files land on disk, the index is set to that tree, and the current branch is
/// pointed at the commit. Calling it `checkout` is the honest name for what a user wants from
/// it; the difference only starts to matter once branching exists, which is a non-goal.
///
/// Refuses to run when it would destroy work, unless `force`. What counts as work: a staged
/// change, an edit or deletion of a tracked file, or an untracked file the snapshot would
/// overwrite. Everything else in the working tree is left alone.
pub fn checkout(repo: &Repo, revision: Option<&str>, force: bool) -> Result<Checkout> {
    let (id, commit, tree) = show(repo, revision)?;

    // Validate every path before writing any of them, so a bad entry cannot leave the working
    // tree half-updated.
    let destinations = tree
        .entries
        .iter()
        .map(|entry| repo.checkout_path(&entry.path).map(|path| (entry, path)))
        .collect::<Result<Vec<_>>>()?;

    if !force {
        let at_risk = endangered(repo, &tree)?;

        if !at_risk.is_empty() {
            return Err(VcsError::DirtyWorkingTree {
                count: at_risk.len(),
            });
        }
    }

    let mut written = Vec::new();
    for (entry, destination) in destinations {
        let bytes = repo.read_object(&entry.blob)?.into_blob(&entry.blob)?;

        if let Some(parent) = destination.parent() {
            std::fs::create_dir_all(parent).map_err(|e| VcsError::io(parent, e))?;
        }

        crate::repo::atomic_write(&destination, &bytes)?;
        written.push(entry.path.clone());
    }

    // Tracked files the target does not have are removals, not leftovers.
    let mut removed = Vec::new();
    for path in repo.index()?.entries.keys() {
        if tree.get(path).is_none() {
            let file = repo.workdir_path(path);

            if file.is_file() {
                std::fs::remove_file(&file).map_err(|e| VcsError::io(&file, e))?;
                prune_empty_parents(repo, &file);
            }

            removed.push(path.clone());
        }
    }

    repo.write_index(&Index::from_tree(&tree))?;
    repo.write_ref(&repo.head()?.r#ref, &id)?;

    written.sort();
    removed.sort();

    Ok(Checkout {
        id,
        commit,
        written,
        removed,
    })
}

/// Paths a checkout would destroy: local work that exists in no commit.
fn endangered(repo: &Repo, target: &Tree) -> Result<Vec<String>> {
    let state = crate::status::status(repo)?;
    let mut at_risk: Vec<String> = state
        .staged
        .iter()
        .chain(state.unstaged.iter())
        .map(|(path, _)| path.clone())
        .collect();

    // An untracked file is only at risk if the snapshot has something to put in its place.
    for path in &state.untracked {
        if target.get(path).is_some() {
            at_risk.push(path.clone());
        }
    }

    at_risk.sort();
    at_risk.dedup();
    Ok(at_risk)
}

// A directory that only existed to hold a removed file is itself part of the removal.
fn prune_empty_parents(repo: &Repo, from: &Path) {
    let mut dir = from.parent().map(Path::to_path_buf);

    while let Some(candidate) = dir {
        if candidate == repo.root() || !candidate.starts_with(repo.root()) {
            break;
        }

        match std::fs::remove_dir(&candidate) {
            // Non-empty, or gone already: nothing above it can be empty either.
            Err(_) => break,
            Ok(()) => dir = candidate.parent().map(Path::to_path_buf),
        }
    }
}
