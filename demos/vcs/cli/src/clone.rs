//! `clone`: the only command that creates a repository from someone else's.
//!
//! It is a composition, deliberately — init, then remote, then fetch, then adopt a branch, then
//! check it out. Each of those already exists and is already tested, so clone adds one genuinely
//! new decision: *which* branch a fresh repository should start on.

use std::path::{Path, PathBuf};

use crate::error::{Result, VcsError};
use crate::object::ObjectId;
use crate::remote::Remote;
use crate::repo::{Config, Head, Repo, DEFAULT_BRANCH};

pub struct Cloned {
    pub root: PathBuf,
    pub branch: String,
    pub commit: ObjectId,
    pub objects: usize,
    pub files: usize,
}

/// Clones `name` from `url` into `into`.
///
/// Refuses a target that already has anything in it. An empty directory is fine — that is the
/// normal case when someone has already made the directory they want to clone into.
pub fn clone(url: &str, name: &str, into: &Path) -> Result<Cloned> {
    if into.exists() {
        let mut entries = std::fs::read_dir(into).map_err(|e| VcsError::io(into, e))?;

        if entries.next().is_some() {
            return Err(VcsError::TargetNotEmpty(into.to_path_buf()));
        }
    } else {
        std::fs::create_dir_all(into).map_err(|e| VcsError::io(into, e))?;
    }

    let repo = Repo::init(into)?;

    repo.write_config(&Config {
        remote: Some(url.to_string()),
        repo: Some(name.to_string()),
        author: None,
    })?;

    let remote = Remote::from_config(&repo)?;
    let fetched = remote.fetch(&repo)?;
    let (branch, commit) = choose_branch(&fetched.refs)?;

    // The local branch starts where the remote one is. `fetch` on its own deliberately never
    // does this — it is a clone that gets to decide, because there is no local work to lose.
    repo.write_head(&Head {
        r#ref: format!("refs/heads/{branch}"),
    })?;
    repo.write_ref(&format!("refs/heads/{branch}"), &commit)?;

    let checkout = crate::ops::checkout(&repo, None, true)?;

    Ok(Cloned {
        root: repo.root().to_path_buf(),
        branch,
        commit,
        objects: fetched.objects_received,
        files: checkout.written.len(),
    })
}

/// Prefers the default branch, then a lone branch, and otherwise refuses to guess.
fn choose_branch(
    refs: &std::collections::BTreeMap<String, ObjectId>,
) -> Result<(String, ObjectId)> {
    let branches: Vec<(String, ObjectId)> = refs
        .iter()
        .filter_map(|(reference, id)| {
            reference
                .strip_prefix("refs/heads/")
                .map(|branch| (branch.to_string(), id.clone()))
        })
        .collect();

    if let Some(found) = branches.iter().find(|(branch, _)| branch == DEFAULT_BRANCH) {
        return Ok(found.clone());
    }

    match branches.len() {
        0 => Err(VcsError::NothingToClone),
        1 => Ok(branches.into_iter().next().expect("length checked")),
        // Choosing for the user here would be choosing wrong some of the time, and there is no
        // `checkout <branch>` yet to recover with.
        _ => Err(VcsError::AmbiguousRevision(
            "default branch".to_string(),
            branches.len(),
        )),
    }
}
