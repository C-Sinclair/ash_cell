//! The client half of push and fetch.
//!
//! Whole-object JSON over HTTP: chatty, uncompressed, and `curl`-able. A real protocol would
//! negotiate and send a packfile; the interesting part of this POC is the server, so the wire
//! stays boring on purpose.

use base64::Engine;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

use crate::error::{Result, VcsError};
use crate::object::{Object, ObjectId};
use crate::repo::Repo;

const B64: base64::engine::general_purpose::GeneralPurpose =
    base64::engine::general_purpose::STANDARD;

pub struct Remote {
    url: String,
    repo: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct WireObject {
    pub id: ObjectId,
    pub kind: String,
    pub encoded_b64: String,
}

#[derive(Debug, Deserialize)]
struct RefsResponse {
    refs: BTreeMap<String, ObjectId>,
}

#[derive(Debug, Deserialize)]
struct MissingResponse {
    missing: Vec<ObjectId>,
}

#[derive(Debug, Deserialize)]
struct ObjectsResponse {
    objects: Vec<WireObject>,
}

#[derive(Debug, Deserialize)]
struct PushResponse {
    #[serde(rename = "ref")]
    _reference: String,
    commit: ObjectId,
}

pub struct PushOutcome {
    pub reference: String,
    pub commit: ObjectId,
    pub objects_sent: usize,
}

pub struct FetchOutcome {
    pub refs: BTreeMap<String, ObjectId>,
    pub objects_received: usize,
}

impl Remote {
    pub fn from_config(repo: &Repo) -> Result<Self> {
        let config = repo.config()?;

        match (config.remote, config.repo) {
            (Some(url), Some(name)) => Ok(Remote {
                url: url.trim_end_matches('/').to_string(),
                repo: name,
            }),
            _ => Err(VcsError::NoRemote),
        }
    }

    fn endpoint(&self, suffix: &str) -> String {
        format!("{}/api/repos/{}/{}", self.url, self.repo, suffix)
    }

    /// The server's refs, or nothing at all.
    ///
    /// A repository the server has never heard of is a 404, and that is the correct answer to
    /// "does this exist" — the server deliberately does not create one to satisfy a read. To a
    /// first push it means the same thing as an empty ref list, so translate it here rather
    /// than making every caller handle it.
    pub fn list_refs(&self) -> Result<BTreeMap<String, ObjectId>> {
        match self.get::<RefsResponse>(&self.endpoint("refs")) {
            Ok(response) => Ok(response.refs),
            Err(VcsError::Server { status: 404, .. }) => Ok(BTreeMap::new()),
            Err(other) => Err(other),
        }
    }

    /// Pushes `branch`, fast-forward only.
    ///
    /// Objects first, then the ref. Objects are content-addressed and idempotent, so a crash
    /// between the two steps leaves unreferenced objects and no corruption — the same failure
    /// mode Git has, since neither system can make the pair atomic.
    pub fn push(&self, repo: &Repo, branch: &str) -> Result<PushOutcome> {
        let reference = format!("refs/heads/{branch}");
        let local = repo
            .read_ref(&reference)?
            .ok_or_else(|| VcsError::UnknownRevision(reference.clone()))?;

        let server_refs = self.list_refs()?;
        let expected = server_refs.get(&reference).cloned();

        if expected.as_ref() == Some(&local) {
            return Err(VcsError::NothingToPush(local.short().to_string()));
        }

        // A fast-forward means the server's tip is somewhere in our own history. Checking it
        // here gives a good local error; the server checks again, because it is the authority.
        if let Some(server) = &expected {
            let ours = crate::ops::reachable(repo, &local, &[])?;

            if !ours.contains(server) {
                return Err(VcsError::NonFastForward {
                    server: server.short().to_string(),
                    local: local.short().to_string(),
                });
            }
        }

        let candidates = crate::ops::reachable(repo, &local, &[])?;
        let missing: MissingResponse = self.post(
            &self.endpoint("missing"),
            &serde_json::json!({ "ids": candidates }),
        )?;

        let mut wire = Vec::with_capacity(missing.missing.len());
        for id in &missing.missing {
            let encoded = repo.read_object_bytes(id)?;
            wire.push(WireObject {
                id: id.clone(),
                kind: Object::decode(&encoded)?.kind().as_str().to_string(),
                encoded_b64: B64.encode(&encoded),
            });
        }

        let objects_sent = wire.len();
        let _: serde_json::Value = self.post(
            &self.endpoint("objects"),
            &serde_json::json!({ "objects": wire }),
        )?;

        let outcome: PushResponse = self.post(
            &self.endpoint("push"),
            &serde_json::json!({
                "ref": reference,
                "expected": expected,
                "new": local,
            }),
        )?;

        repo.write_ref(
            &format!("refs/remotes/origin/{branch}"),
            &outcome.commit.clone(),
        )?;

        Ok(PushOutcome {
            reference,
            commit: outcome.commit,
            objects_sent,
        })
    }

    /// Downloads whatever the server has that we lack, and records its refs. Does not touch
    /// the working tree or any local branch — merging is out of scope.
    pub fn fetch(&self, repo: &Repo) -> Result<FetchOutcome> {
        let refs = self.list_refs()?;
        let have: Vec<ObjectId> = repo.all_object_ids()?;
        let want: Vec<ObjectId> = refs.values().cloned().collect();

        let mut received = 0;

        if !want.is_empty() {
            let response: ObjectsResponse = self.post(
                &self.endpoint("fetch"),
                &serde_json::json!({ "want": want, "have": have }),
            )?;

            for object in response.objects {
                let encoded = B64.decode(object.encoded_b64.as_bytes()).map_err(|e| {
                    VcsError::CorruptObject {
                        id: object.id.to_string(),
                        why: format!("bad base64 from server: {e}"),
                    }
                })?;

                let written = repo.write_object_bytes(&encoded)?;

                if written != object.id {
                    return Err(VcsError::CorruptObject {
                        id: object.id.to_string(),
                        why: format!("server sent bytes hashing to {written}"),
                    });
                }

                received += 1;
            }
        }

        for (reference, id) in &refs {
            if let Some(branch) = reference.strip_prefix("refs/heads/") {
                repo.write_ref(&format!("refs/remotes/origin/{branch}"), id)?;
            }
        }

        Ok(FetchOutcome {
            refs,
            objects_received: received,
        })
    }

    fn get<T: serde::de::DeserializeOwned>(&self, url: &str) -> Result<T> {
        self.read(url, ureq::get(url).call())
    }

    fn post<T: serde::de::DeserializeOwned>(
        &self,
        url: &str,
        body: &serde_json::Value,
    ) -> Result<T> {
        self.read(url, ureq::post(url).send_json(body))
    }

    fn read<T: serde::de::DeserializeOwned>(
        &self,
        url: &str,
        result: std::result::Result<ureq::Response, ureq::Error>,
    ) -> Result<T> {
        match result {
            Ok(response) => response
                .into_json()
                .map_err(|e| VcsError::io(std::path::PathBuf::from(url), e)),
            // The server's own message is the useful one, so surface it rather than the status.
            Err(ureq::Error::Status(status, response)) => {
                let message = response
                    .into_json::<serde_json::Value>()
                    .ok()
                    .and_then(|body| {
                        body.get("error")
                            .and_then(|error| error.as_str())
                            .map(str::to_string)
                    })
                    .unwrap_or_else(|| "no detail".to_string());

                Err(VcsError::Server { status, message })
            }
            Err(other) => Err(VcsError::Transport {
                url: url.to_string(),
                source: Box::new(other),
            }),
        }
    }
}
