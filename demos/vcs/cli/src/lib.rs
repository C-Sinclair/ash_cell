//! `vcs` — the domain half. Nothing in here prints, reads argv, or exits.

pub mod clone;
pub mod error;
pub mod index;
pub mod object;
pub mod ops;
pub mod remote;
pub mod repo;
pub mod status;

pub use error::{Result, VcsError};
pub use repo::Repo;
