//! The CLI: argument parsing and presentation only. All behaviour lives in the library.

use anyhow::Result;
use clap::{Parser, Subcommand};
use std::path::PathBuf;

use vcs::object::{Commit, ObjectId, Tree};
use vcs::repo::{Config, Repo};
use vcs::{ops, remote::Remote, status};

#[derive(Parser)]
#[command(
    name = "vcs",
    version,
    about = "A small version control system with an AshCell server"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Create a repository in the current directory
    Init,
    /// Copy a repository from a server into a new directory
    Clone {
        /// Base URL, e.g. http://localhost:4000
        url: String,
        /// Repository name on the server, e.g. conor/demo
        repo: String,
        /// Where to put it; defaults to the repository's own name
        directory: Option<PathBuf>,
    },
    /// Restore the working tree to a commit's snapshot
    Checkout {
        /// Defaults to HEAD
        revision: Option<String>,
        /// Discard local changes that would otherwise block the checkout
        #[arg(long)]
        force: bool,
    },
    /// Summarise the working tree
    Status,
    /// Stage files or directories
    Add {
        #[arg(required = true, value_name = "PATH")]
        paths: Vec<PathBuf>,
    },
    /// Record the staged state as a commit
    Commit {
        #[arg(short, long)]
        message: String,
        /// Commit even when nothing changed
        #[arg(long)]
        allow_empty: bool,
        /// Recorded on the commit; defaults to the configured author, then $USER
        #[arg(long)]
        author: Option<String>,
    },
    /// Show history, newest first
    Log {
        /// Start from this revision instead of HEAD
        revision: Option<String>,
        #[arg(short = 'n', long)]
        limit: Option<usize>,
    },
    /// Show one commit and its snapshot
    Show { revision: Option<String> },
    /// Point this repository at a server
    Remote {
        /// Base URL, e.g. http://localhost:4000
        url: String,
        /// Repository name on the server, e.g. conor/demo
        repo: String,
    },
    /// Send the current branch to the server
    Push,
    /// Retrieve objects and refs from the server
    Fetch,
}

fn main() {
    if let Err(error) = run() {
        eprintln!("error: {error}");

        for cause in error.chain().skip(1) {
            eprintln!("  caused by: {cause}");
        }

        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let cli = Cli::parse();
    let here = std::env::current_dir()?;

    match cli.command {
        Command::Init => {
            let repo = Repo::init(&here)?;
            println!(
                "initialised empty vcs repository in {}",
                repo.meta().display()
            );
        }

        Command::Clone {
            url,
            repo: name,
            directory,
        } => {
            let into = directory.unwrap_or_else(|| {
                // `owner/name` would nest a directory nobody asked for, so clone into the last
                // segment, the way every other VCS does.
                PathBuf::from(name.rsplit('/').next().unwrap_or(&name))
            });
            let cloned = vcs::clone::clone(&url, &name, &here.join(&into))?;

            println!("cloned {name} into {}", cloned.root.display());
            println!(
                "  {} object(s), {} file(s); on branch {} at {}",
                cloned.objects,
                cloned.files,
                cloned.branch,
                cloned.commit.short()
            );
        }

        Command::Checkout { revision, force } => {
            let repo = Repo::discover(&here)?;
            let checkout = ops::checkout(&repo, revision.as_deref(), force)?;

            println!(
                "checked out {} on branch {}",
                checkout.id.short(),
                repo.current_branch()?
            );
            println!("    {}", first_line(&checkout.commit.message));
            println!(
                "  {} file(s) written, {} removed",
                checkout.written.len(),
                checkout.removed.len()
            );
        }

        Command::Status => print_status(&status::status(&Repo::discover(&here)?)?),

        Command::Add { paths } => {
            let repo = Repo::discover(&here)?;
            let added = ops::add(&repo, &paths)?;

            if added.staged.is_empty() && added.removed.is_empty() {
                println!("nothing to stage");
            }

            for path in &added.staged {
                println!("staged {path}");
            }

            for path in &added.removed {
                println!("staged deletion of {path}");
            }
        }

        Command::Commit {
            message,
            allow_empty,
            author,
        } => {
            let repo = Repo::discover(&here)?;
            let author = author.unwrap_or_else(|| default_author(&repo));
            let committed = ops::commit(&repo, &message, &author, allow_empty)?;

            println!(
                "[{} {}] {}",
                repo.current_branch()?,
                committed.id.short(),
                first_line(&committed.commit.message)
            );
            println!("  {} path(s) in snapshot", committed.paths);
        }

        Command::Log { revision, limit } => {
            let repo = Repo::discover(&here)?;
            let history = ops::log(&repo, revision.as_deref(), limit)?;

            if history.is_empty() {
                println!("no commits yet");
            }

            for (index, (id, commit)) in history.iter().enumerate() {
                if index > 0 {
                    println!();
                }
                print_commit_header(id, commit);
            }
        }

        Command::Show { revision } => {
            let repo = Repo::discover(&here)?;
            let (id, commit, tree) = ops::show(&repo, revision.as_deref())?;

            print_commit_header(&id, &commit);
            print_tree(&tree);
        }

        Command::Remote { url, repo: name } => {
            let repo = Repo::discover(&here)?;
            let existing = repo.config()?;

            repo.write_config(&Config {
                remote: Some(url.clone()),
                repo: Some(name.clone()),
                author: existing.author,
            })?;

            println!("remote set to {url} ({name})");
        }

        Command::Push => {
            let repo = Repo::discover(&here)?;
            let branch = repo.current_branch()?;
            let outcome = Remote::from_config(&repo)?.push(&repo, &branch)?;

            println!(
                "pushed {} objects; {} is now {}",
                outcome.objects_sent,
                outcome.reference,
                outcome.commit.short()
            );
        }

        Command::Fetch => {
            let repo = Repo::discover(&here)?;
            let outcome = Remote::from_config(&repo)?.fetch(&repo)?;

            println!("fetched {} objects", outcome.objects_received);

            if outcome.refs.is_empty() {
                println!("  the server has no refs yet");
            }

            for (reference, id) in &outcome.refs {
                println!("  {reference} -> {}", id.short());
            }
        }
    }

    Ok(())
}

fn print_status(status: &status::Status) {
    println!("on branch {}", status.branch);

    match &status.head {
        Some(id) => println!("head {}", id.short()),
        None => println!("head (no commits yet)"),
    }

    let section = |title: &str, entries: &[(String, status::Change)]| {
        if entries.is_empty() {
            return;
        }

        println!("\n{title}:");
        for (path, change) in entries {
            println!("  {:<9} {path}", change.label());
        }
    };

    section("staged for commit", &status.staged);
    section("not staged", &status.unstaged);

    if !status.untracked.is_empty() {
        println!("\nuntracked:");
        for path in &status.untracked {
            println!("  {path}");
        }
    }

    if status.is_clean() {
        println!("\nnothing to commit, working tree clean");
    }
}

fn print_commit_header(id: &ObjectId, commit: &Commit) {
    println!("commit {id}");
    println!("author {}", commit.author);
    println!("date   {}", commit.timestamp);

    if let Some(parent) = &commit.parent {
        println!("parent {}", parent.short());
    } else {
        println!("parent (root commit)");
    }

    println!();
    for line in commit.message.lines() {
        println!("    {line}");
    }
}

fn print_tree(tree: &Tree) {
    println!("\nsnapshot ({} path(s)):", tree.entries.len());

    for entry in &tree.entries {
        println!(
            "  {}  {:>8}  {}",
            entry.blob.short(),
            entry.size,
            entry.path
        );
    }
}

fn first_line(message: &str) -> &str {
    message.lines().next().unwrap_or("")
}

fn default_author(repo: &Repo) -> String {
    repo.config()
        .ok()
        .and_then(|config| config.author)
        .or_else(|| std::env::var("USER").ok())
        .unwrap_or_else(|| "unknown".to_string())
}
