//! End-to-end CLI tests. Each one drives the real binary in a fresh temp directory.

use std::path::Path;
use std::process::{Command, Output};

fn vcs(dir: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_vcs"))
        .args(args)
        .current_dir(dir)
        .output()
        .expect("failed to run the vcs binary")
}

fn ok(dir: &Path, args: &[&str]) -> String {
    let output = vcs(dir, args);
    assert!(
        output.status.success(),
        "expected `vcs {}` to succeed, got {:?}\nstderr: {}",
        args.join(" "),
        output.status.code(),
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).to_string()
}

fn fails(dir: &Path, args: &[&str]) -> String {
    let output = vcs(dir, args);
    assert!(
        !output.status.success(),
        "expected `vcs {}` to fail, but it succeeded:\n{}",
        args.join(" "),
        String::from_utf8_lossy(&output.stdout)
    );
    String::from_utf8_lossy(&output.stderr).to_string()
}

fn write(dir: &Path, path: &str, contents: &str) {
    let full = dir.join(path);
    if let Some(parent) = full.parent() {
        std::fs::create_dir_all(parent).expect("failed to create parent directory");
    }
    std::fs::write(full, contents).expect("failed to write fixture file");
}

#[test]
fn the_whole_local_flow() {
    let temp = tempfile::tempdir().expect("failed to make a temp dir");
    let dir = temp.path();

    let init = ok(dir, &["init"]);
    assert!(init.contains(".vcs"), "{init}");
    assert!(dir.join(".vcs").join("HEAD").is_file());

    write(dir, "hello.txt", "first version\n");

    let untracked = ok(dir, &["status"]);
    assert!(untracked.contains("on branch main"), "{untracked}");
    assert!(untracked.contains("no commits yet"), "{untracked}");
    assert!(untracked.contains("untracked:"), "{untracked}");
    assert!(untracked.contains("hello.txt"), "{untracked}");

    ok(dir, &["add", "hello.txt"]);

    let staged = ok(dir, &["status"]);
    assert!(staged.contains("staged for commit"), "{staged}");
    assert!(staged.contains("new file  hello.txt"), "{staged}");
    assert!(!staged.contains("untracked:"), "{staged}");

    let first = ok(dir, &["commit", "-m", "add hello"]);
    assert!(first.contains("add hello"), "{first}");
    assert!(first.contains("1 path(s)"), "{first}");

    let clean = ok(dir, &["status"]);
    assert!(clean.contains("working tree clean"), "{clean}");

    write(dir, "hello.txt", "second version\n");

    let modified = ok(dir, &["status"]);
    assert!(modified.contains("not staged"), "{modified}");
    assert!(modified.contains("modified  hello.txt"), "{modified}");
    assert!(
        !modified.contains("staged for commit"),
        "a working-tree edit must not show as staged:\n{modified}"
    );

    ok(dir, &["add", "hello.txt"]);
    let staged_edit = ok(dir, &["status"]);
    assert!(staged_edit.contains("staged for commit"), "{staged_edit}");
    assert!(staged_edit.contains("modified  hello.txt"), "{staged_edit}");

    ok(dir, &["commit", "-m", "update hello"]);

    let log = ok(dir, &["log"]);
    let newer = log.find("update hello").expect("newest commit missing");
    let older = log.find("add hello").expect("first commit missing");
    assert!(newer < older, "log must be newest first:\n{log}");
    assert!(log.contains("(root commit)"), "{log}");

    // Each snapshot must reflect the content at that point in history, not now.
    let ids: Vec<String> = log
        .lines()
        .filter_map(|line| line.strip_prefix("commit "))
        .map(str::to_string)
        .collect();
    assert_eq!(ids.len(), 2, "{log}");

    let second_show = ok(dir, &["show", &ids[0]]);
    let first_show = ok(dir, &["show", &ids[1]]);

    assert!(second_show.contains("update hello"), "{second_show}");
    assert!(first_show.contains("add hello"), "{first_show}");
    assert!(first_show.contains("hello.txt"), "{first_show}");

    let first_blob = blob_line(&first_show);
    let second_blob = blob_line(&second_show);
    assert_ne!(
        first_blob, second_blob,
        "the two snapshots must point at different blobs"
    );

    // `show` with no argument is HEAD.
    let head_show = ok(dir, &["show"]);
    assert!(head_show.contains("update hello"), "{head_show}");

    // Abbreviated ids resolve.
    let short = &ids[1][..12];
    assert!(ok(dir, &["show", short]).contains("add hello"));
}

fn blob_line(show_output: &str) -> String {
    show_output
        .lines()
        .find(|line| line.trim_end().ends_with("hello.txt") && line.starts_with("  "))
        .unwrap_or_default()
        .to_string()
}

#[test]
fn directories_are_recursed_and_metadata_is_never_staged() {
    let temp = tempfile::tempdir().expect("failed to make a temp dir");
    let dir = temp.path();

    ok(dir, &["init"]);
    write(dir, "src/a.txt", "a\n");
    write(dir, "src/nested/b.txt", "b\n");
    write(dir, "top.txt", "top\n");

    let staged = ok(dir, &["add", "src"]);
    assert!(staged.contains("src/a.txt"), "{staged}");
    assert!(staged.contains("src/nested/b.txt"), "{staged}");
    assert!(!staged.contains("top.txt"), "{staged}");

    // Staging the whole repo must skip .vcs rather than swallow it.
    ok(dir, &["add", "."]);
    let show = {
        ok(dir, &["commit", "-m", "everything"]);
        ok(dir, &["show"])
    };
    assert!(!show.contains(".vcs"), "{show}");
    assert!(show.contains("3 path(s)"), "{show}");

    let error = fails(dir, &["add", ".vcs/HEAD"]);
    assert!(error.contains("metadata"), "{error}");
}

#[test]
fn commands_outside_a_repository_fail_helpfully() {
    let temp = tempfile::tempdir().expect("failed to make a temp dir");
    let dir = temp.path();

    for args in [
        vec!["status"],
        vec!["log"],
        vec!["show"],
        vec!["add", "anything.txt"],
        vec!["commit", "-m", "nope"],
        vec!["push"],
        vec!["fetch"],
    ] {
        let error = fails(dir, &args);
        assert!(
            error.contains("not a vcs repository"),
            "`vcs {}` said: {error}",
            args.join(" ")
        );
    }
}

#[test]
fn commit_with_nothing_staged_fails_helpfully() {
    let temp = tempfile::tempdir().expect("failed to make a temp dir");
    let dir = temp.path();

    ok(dir, &["init"]);

    let error = fails(dir, &["commit", "-m", "empty"]);
    assert!(error.contains("nothing staged"), "{error}");

    // And once there is history, an unchanged tree is refused too.
    write(dir, "a.txt", "a\n");
    ok(dir, &["add", "a.txt"]);
    ok(dir, &["commit", "-m", "first"]);

    let second = fails(dir, &["commit", "-m", "again"]);
    assert!(second.contains("nothing to commit"), "{second}");

    let forced = ok(dir, &["commit", "-m", "again", "--allow-empty"]);
    assert!(forced.contains("again"), "{forced}");
}

#[test]
fn duplicate_init_fails_safely() {
    let temp = tempfile::tempdir().expect("failed to make a temp dir");
    let dir = temp.path();

    ok(dir, &["init"]);
    write(dir, "a.txt", "a\n");
    ok(dir, &["add", "a.txt"]);
    ok(dir, &["commit", "-m", "first"]);

    let error = fails(dir, &["init"]);
    assert!(error.contains("already exists"), "{error}");

    // The existing repository must be untouched.
    assert!(ok(dir, &["log"]).contains("first"));
}

#[test]
fn missing_paths_passed_to_add_fail_clearly_and_stage_nothing() {
    let temp = tempfile::tempdir().expect("failed to make a temp dir");
    let dir = temp.path();

    ok(dir, &["init"]);
    write(dir, "real.txt", "real\n");

    let error = fails(dir, &["add", "real.txt", "ghost.txt"]);
    assert!(error.contains("ghost.txt"), "{error}");
    assert!(error.contains("does not exist"), "{error}");

    let status = ok(dir, &["status"]);
    assert!(
        !status.contains("staged for commit"),
        "a failed add must stage nothing:\n{status}"
    );
}

#[test]
fn paths_outside_the_repository_are_refused() {
    let temp = tempfile::tempdir().expect("failed to make a temp dir");
    let dir = temp.path().join("repo");
    std::fs::create_dir_all(&dir).expect("failed to create the repo dir");
    std::fs::write(temp.path().join("outside.txt"), "nope\n").expect("failed to write fixture");

    ok(&dir, &["init"]);

    let error = fails(&dir, &["add", "../outside.txt"]);
    assert!(error.contains("outside the repository"), "{error}");
}

#[test]
fn push_without_a_remote_fails_helpfully() {
    let temp = tempfile::tempdir().expect("failed to make a temp dir");
    let dir = temp.path();

    ok(dir, &["init"]);

    let error = fails(dir, &["push"]);
    assert!(error.contains("no remote configured"), "{error}");

    ok(dir, &["remote", "http://localhost:4000", "conor/demo"]);
    let unreachable = fails(dir, &["fetch"]);
    assert!(
        unreachable.contains("could not reach the server"),
        "{unreachable}"
    );
}

#[test]
fn deleting_a_tracked_file_shows_as_unstaged_deletion() {
    let temp = tempfile::tempdir().expect("failed to make a temp dir");
    let dir = temp.path();

    ok(dir, &["init"]);
    write(dir, "a.txt", "a\n");
    ok(dir, &["add", "a.txt"]);
    ok(dir, &["commit", "-m", "first"]);

    std::fs::remove_file(dir.join("a.txt")).expect("failed to remove the fixture");

    let status = ok(dir, &["status"]);
    assert!(status.contains("deleted   a.txt"), "{status}");
}

#[test]
fn checkout_restores_an_earlier_snapshot() {
    let temp = tempfile::tempdir().expect("failed to make a temp dir");
    let dir = temp.path();

    ok(dir, &["init"]);
    write(dir, "a.txt", "version one\n");
    write(dir, "lib/b.txt", "b\n");
    ok(dir, &["add", "."]);
    ok(dir, &["commit", "-m", "first"]);

    write(dir, "a.txt", "version two\n");
    std::fs::remove_file(dir.join("lib/b.txt")).expect("failed to remove the fixture");
    ok(dir, &["add", "a.txt"]);

    // The removal has to be staged like any other change; `add` on a tracked path that is gone
    // stages its deletion.
    let staged_removal = ok(dir, &["add", "lib/b.txt"]);
    assert!(
        staged_removal.contains("staged deletion of lib/b.txt"),
        "{staged_removal}"
    );

    ok(dir, &["commit", "-m", "second"]);

    let ids: Vec<String> = ok(dir, &["log"])
        .lines()
        .filter_map(|line| line.strip_prefix("commit "))
        .map(str::to_string)
        .collect();

    // The second commit dropped lib/b.txt from the index but the file is already gone, so the
    // interesting direction is backwards: checking out the first must bring it back.
    assert_eq!(
        std::fs::read_to_string(dir.join("a.txt")).unwrap(),
        "version two\n"
    );
    assert!(!dir.join("lib/b.txt").exists());

    let out = ok(dir, &["checkout", &ids[1]]);
    assert!(out.contains("first"), "{out}");
    assert!(out.contains("2 file(s) written"), "{out}");

    assert_eq!(
        std::fs::read_to_string(dir.join("a.txt")).unwrap(),
        "version one\n"
    );
    assert_eq!(
        std::fs::read_to_string(dir.join("lib/b.txt")).unwrap(),
        "b\n",
        "checkout must restore a file the later commit dropped"
    );

    // The branch moved with it, and nothing is left looking dirty.
    let status = ok(dir, &["status"]);
    assert!(status.contains("working tree clean"), "{status}");
    assert!(status.contains(&ids[1][..12]), "{status}");
}

#[test]
fn checkout_removes_files_the_target_snapshot_does_not_have() {
    let temp = tempfile::tempdir().expect("failed to make a temp dir");
    let dir = temp.path();

    ok(dir, &["init"]);
    write(dir, "keep.txt", "keep\n");
    ok(dir, &["add", "keep.txt"]);
    ok(dir, &["commit", "-m", "first"]);

    write(dir, "nested/gone.txt", "gone\n");
    ok(dir, &["add", "nested"]);
    ok(dir, &["commit", "-m", "second"]);

    let ids: Vec<String> = ok(dir, &["log"])
        .lines()
        .filter_map(|line| line.strip_prefix("commit "))
        .map(str::to_string)
        .collect();

    let out = ok(dir, &["checkout", &ids[1]]);
    assert!(out.contains("1 removed"), "{out}");
    assert!(!dir.join("nested/gone.txt").exists());
    assert!(
        !dir.join("nested").exists(),
        "a directory that only held a removed file should go too"
    );
    assert!(dir.join("keep.txt").exists());
}

#[test]
fn checkout_refuses_to_destroy_work_without_force() {
    let temp = tempfile::tempdir().expect("failed to make a temp dir");
    let dir = temp.path();

    ok(dir, &["init"]);
    write(dir, "a.txt", "committed\n");
    ok(dir, &["add", "a.txt"]);
    ok(dir, &["commit", "-m", "first"]);

    write(dir, "a.txt", "uncommitted work\n");

    let error = fails(dir, &["checkout"]);
    assert!(error.contains("refusing to overwrite"), "{error}");
    assert_eq!(
        std::fs::read_to_string(dir.join("a.txt")).unwrap(),
        "uncommitted work\n",
        "a refused checkout must change nothing"
    );

    ok(dir, &["checkout", "--force"]);
    assert_eq!(
        std::fs::read_to_string(dir.join("a.txt")).unwrap(),
        "committed\n"
    );
}

#[test]
fn checkout_leaves_unrelated_untracked_files_alone() {
    let temp = tempfile::tempdir().expect("failed to make a temp dir");
    let dir = temp.path();

    ok(dir, &["init"]);
    write(dir, "a.txt", "a\n");
    ok(dir, &["add", "a.txt"]);
    ok(dir, &["commit", "-m", "first"]);

    write(dir, "scratch.txt", "my notes\n");

    // The snapshot has nothing to put at scratch.txt, so there is nothing to overwrite and no
    // reason to refuse.
    ok(dir, &["checkout"]);
    assert_eq!(
        std::fs::read_to_string(dir.join("scratch.txt")).unwrap(),
        "my notes\n"
    );
}

#[test]
fn checkout_refuses_to_overwrite_an_untracked_file_in_its_way() {
    let temp = tempfile::tempdir().expect("failed to make a temp dir");
    let dir = temp.path();

    ok(dir, &["init"]);
    write(dir, "a.txt", "committed\n");
    ok(dir, &["add", "a.txt"]);
    ok(dir, &["commit", "-m", "first"]);

    // Remove it from tracking by committing a tree without it, then recreate it by hand.
    write(dir, "b.txt", "b\n");
    std::fs::remove_file(dir.join("a.txt")).expect("failed to remove the fixture");
    ok(dir, &["add", "b.txt"]);
    ok(dir, &["commit", "-m", "second", "--allow-empty"]);
    write(dir, "a.txt", "untracked, and in the way\n");

    let ids: Vec<String> = ok(dir, &["log"])
        .lines()
        .filter_map(|line| line.strip_prefix("commit "))
        .map(str::to_string)
        .collect();

    let error = fails(dir, &["checkout", &ids[1]]);
    assert!(error.contains("refusing to overwrite"), "{error}");
    assert_eq!(
        std::fs::read_to_string(dir.join("a.txt")).unwrap(),
        "untracked, and in the way\n"
    );
}

#[test]
fn clone_without_a_reachable_server_fails_helpfully() {
    let temp = tempfile::tempdir().expect("failed to make a temp dir");
    let into = temp.path().join("target");

    let error = fails(
        temp.path(),
        &["clone", "http://127.0.0.1:1", "someone/nothing"],
    );
    assert!(error.contains("could not reach the server"), "{error}");
    // A failed clone still leaves the directory it made; what matters is that it is not
    // presented as a working repository.
    assert!(!into
        .join(".vcs")
        .join("refs")
        .join("heads")
        .join("main")
        .exists());
}

#[test]
fn clone_refuses_a_non_empty_target() {
    let temp = tempfile::tempdir().expect("failed to make a temp dir");
    write(temp.path(), "occupied/something.txt", "in the way\n");

    let error = fails(
        temp.path(),
        &["clone", "http://127.0.0.1:1", "someone/nothing", "occupied"],
    );
    assert!(error.contains("not empty"), "{error}");
}

#[test]
fn a_deletion_can_be_staged_committed_and_undone() {
    let temp = tempfile::tempdir().expect("failed to make a temp dir");
    let dir = temp.path();

    ok(dir, &["init"]);
    write(dir, "keep.txt", "keep\n");
    write(dir, "doomed.txt", "doomed\n");
    ok(dir, &["add", "."]);
    ok(dir, &["commit", "-m", "both files"]);

    std::fs::remove_file(dir.join("doomed.txt")).expect("failed to remove the fixture");

    // Staging the whole repo picks up the removal too, not just the surviving files.
    let staged = ok(dir, &["add", "."]);
    assert!(staged.contains("staged deletion of doomed.txt"), "{staged}");

    let status = ok(dir, &["status"]);
    assert!(status.contains("deleted   doomed.txt"), "{status}");
    assert!(status.contains("staged for commit"), "{status}");

    let committed = ok(dir, &["commit", "-m", "drop doomed"]);
    assert!(committed.contains("1 path(s)"), "{committed}");

    let show = ok(dir, &["show"]);
    assert!(!show.contains("doomed.txt"), "{show}");
    assert!(ok(dir, &["status"]).contains("working tree clean"));

    // And the earlier snapshot still has it, which is the point of keeping history.
    let ids: Vec<String> = ok(dir, &["log"])
        .lines()
        .filter_map(|line| line.strip_prefix("commit "))
        .map(str::to_string)
        .collect();

    let out = ok(dir, &["checkout", &ids[1]]);
    assert!(out.contains("2 file(s) written"), "{out}");
    assert_eq!(
        std::fs::read_to_string(dir.join("doomed.txt")).unwrap(),
        "doomed\n"
    );
}

#[test]
fn adding_a_path_that_never_existed_still_fails() {
    let temp = tempfile::tempdir().expect("failed to make a temp dir");
    let dir = temp.path();

    ok(dir, &["init"]);

    // The deletion-staging path must not swallow a genuine typo.
    let error = fails(dir, &["add", "typo.txt"]);
    assert!(error.contains("does not exist"), "{error}");
}
