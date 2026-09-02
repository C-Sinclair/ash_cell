// A POSIX filesystem stored entirely inside one SQLite database, served over FUSE.
//
// Content model, deliberately simple and worth stating up front: on open/create the whole
// file is read into a Vec<u8> tied to the file handle. read/write operate on that in-memory
// buffer. release/flush/fsync write the buffer back to SQLite in a single statement if it is
// dirty. This is a write-back, whole-file cache: a resident open file must fit in RAM, and a
// write is durable only at flush/release, not at the write() call itself. That trade is fine
// for a benchmark probe; it would not be for a real filesystem.
//
// Correctness over concurrency: one rusqlite::Connection behind a Mutex models a cell's
// single writer, not a filesystem built for parallel throughput.

use fuser::{
    consts::FOPEN_DIRECT_IO, FileAttr, FileType, Filesystem, MountOption, ReplyAttr,
    ReplyCreate, ReplyData, ReplyDirectory, ReplyEmpty, ReplyEntry, ReplyOpen, ReplyStatfs,
    ReplyWrite, Request, TimeOrNow,
};
use rusqlite::{params, Connection, OptionalExtension};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::ffi::OsStr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const TTL: Duration = Duration::from_secs(1);
const ROOT_INO: u64 = 1;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Mode {
    Inline,
    Cas,
}

struct Handle {
    ino: u64,
    data: Vec<u8>,
    dirty: bool,
}

struct FsInCell {
    conn: Mutex<Connection>,
    mode: Mode,
    next_fh: AtomicU64,
    handles: Mutex<HashMap<u64, Handle>>,
    uid: u32,
    gid: u32,
}

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64
}

fn kind_to_file_type(kind: i64) -> FileType {
    match kind {
        0 => FileType::RegularFile,
        1 => FileType::Directory,
        2 => FileType::Symlink,
        _ => FileType::RegularFile,
    }
}

struct InodeRow {
    kind: i64,
    mode: i64,
    size: i64,
    mtime: i64,
    nlink: i64,
}

impl FsInCell {
    fn init_schema(conn: &Connection, mode: Mode) {
        conn.execute_batch("PRAGMA page_size=8192;").unwrap();
        conn.execute_batch(
            "PRAGMA journal_mode=WAL;
             PRAGMA synchronous=NORMAL;
             PRAGMA cache_size=-65536;",
        )
        .unwrap();

        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS inodes (
                ino INTEGER PRIMARY KEY,
                kind INTEGER NOT NULL,
                mode INTEGER NOT NULL,
                size INTEGER NOT NULL,
                target TEXT,
                mtime INTEGER NOT NULL,
                nlink INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS dirents (
                parent INTEGER NOT NULL,
                name TEXT NOT NULL,
                ino INTEGER NOT NULL,
                PRIMARY KEY (parent, name)
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS dirents_ino ON dirents(ino);",
        )
        .unwrap();

        match mode {
            Mode::Inline => {
                conn.execute_batch(
                    "CREATE TABLE IF NOT EXISTS ino_content (
                        ino INTEGER PRIMARY KEY,
                        content BLOB NOT NULL
                    );",
                )
                .unwrap();
            }
            Mode::Cas => {
                conn.execute_batch(
                    "CREATE TABLE IF NOT EXISTS blobs (
                        hash BLOB PRIMARY KEY,
                        content BLOB NOT NULL
                    ) WITHOUT ROWID;
                    CREATE TABLE IF NOT EXISTS ino_content (
                        ino INTEGER PRIMARY KEY,
                        hash BLOB NOT NULL
                    );",
                )
                .unwrap();
            }
        }

        let root_exists: Option<i64> = conn
            .query_row("SELECT ino FROM inodes WHERE ino=1", [], |r| r.get(0))
            .optional()
            .unwrap();
        if root_exists.is_none() {
            conn.execute(
                "INSERT INTO inodes (ino, kind, mode, size, target, mtime, nlink)
                 VALUES (1, 1, ?1, 0, NULL, ?2, 2)",
                params![0o755i64, now_secs()],
            )
            .unwrap();
        }
    }

    fn load_inode(conn: &Connection, ino: u64) -> Option<InodeRow> {
        conn.query_row(
            "SELECT kind, mode, size, mtime, nlink FROM inodes WHERE ino=?1",
            params![ino as i64],
            |r| {
                Ok(InodeRow {
                    kind: r.get(0)?,
                    mode: r.get(1)?,
                    size: r.get(2)?,
                    mtime: r.get(3)?,
                    nlink: r.get(4)?,
                })
            },
        )
        .optional()
        .unwrap()
    }

    fn attr_of(&self, conn: &Connection, ino: u64) -> Option<FileAttr> {
        Self::load_inode(conn, ino).map(|row| self.make_attr(ino, &row))
    }

    fn make_attr(&self, ino: u64, row: &InodeRow) -> FileAttr {
        let time = UNIX_EPOCH + Duration::from_secs(row.mtime.max(0) as u64);
        let size = row.size.max(0) as u64;
        FileAttr {
            ino,
            size,
            blocks: (size + 511) / 512,
            atime: time,
            mtime: time,
            ctime: time,
            crtime: time,
            kind: kind_to_file_type(row.kind),
            perm: (row.mode & 0o7777) as u16,
            nlink: row.nlink.max(0) as u32,
            uid: self.uid,
            gid: self.gid,
            rdev: 0,
            blksize: 4096,
            flags: 0,
        }
    }

    fn lookup_ino(conn: &Connection, parent: u64, name: &str) -> Option<u64> {
        conn.query_row(
            "SELECT ino FROM dirents WHERE parent=?1 AND name=?2",
            params![parent as i64, name],
            |r| r.get::<_, i64>(0),
        )
        .optional()
        .unwrap()
        .map(|v| v as u64)
    }

    fn parent_of(conn: &Connection, ino: u64) -> u64 {
        if ino == ROOT_INO {
            return ROOT_INO;
        }
        conn.query_row(
            "SELECT parent FROM dirents WHERE ino=?1 LIMIT 1",
            params![ino as i64],
            |r| r.get::<_, i64>(0),
        )
        .optional()
        .unwrap()
        .map(|v| v as u64)
        .unwrap_or(ROOT_INO)
    }

    fn has_children(conn: &Connection, ino: u64) -> bool {
        conn.query_row(
            "SELECT 1 FROM dirents WHERE parent=?1 LIMIT 1",
            params![ino as i64],
            |r| r.get::<_, i64>(0),
        )
        .optional()
        .unwrap()
        .is_some()
    }

    fn read_content(&self, conn: &Connection, ino: u64) -> Vec<u8> {
        match self.mode {
            Mode::Inline => conn
                .query_row(
                    "SELECT content FROM ino_content WHERE ino=?1",
                    params![ino as i64],
                    |r| r.get::<_, Vec<u8>>(0),
                )
                .optional()
                .unwrap()
                .unwrap_or_default(),
            Mode::Cas => {
                let hash: Option<Vec<u8>> = conn
                    .query_row(
                        "SELECT hash FROM ino_content WHERE ino=?1",
                        params![ino as i64],
                        |r| r.get(0),
                    )
                    .optional()
                    .unwrap();
                match hash {
                    Some(h) => conn
                        .query_row(
                            "SELECT content FROM blobs WHERE hash=?1",
                            params![h],
                            |r| r.get::<_, Vec<u8>>(0),
                        )
                        .optional()
                        .unwrap()
                        .unwrap_or_default(),
                    None => Vec::new(),
                }
            }
        }
    }

    fn write_content(&self, conn: &Connection, ino: u64, data: &[u8]) {
        match self.mode {
            Mode::Inline => {
                conn.execute(
                    "INSERT INTO ino_content (ino, content) VALUES (?1, ?2)
                     ON CONFLICT(ino) DO UPDATE SET content=excluded.content",
                    params![ino as i64, data],
                )
                .unwrap();
            }
            Mode::Cas => {
                let hash = Sha256::digest(data).to_vec();
                conn.execute(
                    "INSERT OR IGNORE INTO blobs (hash, content) VALUES (?1, ?2)",
                    params![hash, data],
                )
                .unwrap();
                conn.execute(
                    "INSERT INTO ino_content (ino, hash) VALUES (?1, ?2)
                     ON CONFLICT(ino) DO UPDATE SET hash=excluded.hash",
                    params![ino as i64, hash],
                )
                .unwrap();
            }
        }
        conn.execute(
            "UPDATE inodes SET size=?1, mtime=?2 WHERE ino=?3",
            params![data.len() as i64, now_secs(), ino as i64],
        )
        .unwrap();
    }

    fn delete_content(&self, conn: &Connection, ino: u64) {
        conn.execute("DELETE FROM ino_content WHERE ino=?1", params![ino as i64])
            .unwrap();
    }

    fn new_fh(&self) -> u64 {
        self.next_fh.fetch_add(1, Ordering::SeqCst)
    }

    fn flush_handle(&self, conn: &Connection, handle: &mut Handle) {
        if handle.dirty {
            self.write_content(conn, handle.ino, &handle.data);
            handle.dirty = false;
        }
    }

    fn handle_for_ino(&self, ino: u64) -> Option<u64> {
        let handles = self.handles.lock().unwrap();
        handles
            .iter()
            .find(|(_, h)| h.ino == ino)
            .map(|(fh, _)| *fh)
    }
}

impl Filesystem for FsInCell {
    fn lookup(&mut self, _req: &Request<'_>, parent: u64, name: &OsStr, reply: ReplyEntry) {
        let name = match name.to_str() {
            Some(s) => s,
            None => {
                reply.error(libc::EINVAL);
                return;
            }
        };
        let conn = self.conn.lock().unwrap();
        match Self::lookup_ino(&conn, parent, name) {
            Some(ino) => match self.attr_of(&conn, ino) {
                Some(attr) => reply.entry(&TTL, &attr, 0),
                None => reply.error(libc::ENOENT),
            },
            None => reply.error(libc::ENOENT),
        }
    }

    fn getattr(&mut self, _req: &Request<'_>, ino: u64, reply: ReplyAttr) {
        let conn = self.conn.lock().unwrap();
        match self.attr_of(&conn, ino) {
            Some(attr) => reply.attr(&TTL, &attr),
            None => reply.error(libc::ENOENT),
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn setattr(
        &mut self,
        _req: &Request<'_>,
        ino: u64,
        mode: Option<u32>,
        _uid: Option<u32>,
        _gid: Option<u32>,
        size: Option<u64>,
        _atime: Option<TimeOrNow>,
        _mtime: Option<TimeOrNow>,
        _ctime: Option<SystemTime>,
        fh: Option<u64>,
        _crtime: Option<SystemTime>,
        _chgtime: Option<SystemTime>,
        _bkuptime: Option<SystemTime>,
        _flags: Option<u32>,
        reply: ReplyAttr,
    ) {
        let conn = self.conn.lock().unwrap();
        if Self::load_inode(&conn, ino).is_none() {
            reply.error(libc::ENOENT);
            return;
        }

        if let Some(new_size) = size {
            let target_fh = fh.or_else(|| self.handle_for_ino(ino));
            if let Some(target_fh) = target_fh {
                let mut handles = self.handles.lock().unwrap();
                if let Some(handle) = handles.get_mut(&target_fh) {
                    handle.data.resize(new_size as usize, 0);
                    handle.dirty = true;
                    self.flush_handle(&conn, handle);
                }
            } else {
                let mut data = self.read_content(&conn, ino);
                data.resize(new_size as usize, 0);
                self.write_content(&conn, ino, &data);
            }
        }

        if let Some(mode) = mode {
            conn.execute(
                "UPDATE inodes SET mode=?1, mtime=?2 WHERE ino=?3",
                params![(mode & 0o7777) as i64, now_secs(), ino as i64],
            )
            .unwrap();
        } else {
            conn.execute(
                "UPDATE inodes SET mtime=?1 WHERE ino=?2",
                params![now_secs(), ino as i64],
            )
            .unwrap();
        }

        match self.attr_of(&conn, ino) {
            Some(attr) => reply.attr(&TTL, &attr),
            None => reply.error(libc::ENOENT),
        }
    }

    fn read(
        &mut self,
        _req: &Request<'_>,
        _ino: u64,
        fh: u64,
        offset: i64,
        size: u32,
        _flags: i32,
        _lock_owner: Option<u64>,
        reply: ReplyData,
    ) {
        let handles = self.handles.lock().unwrap();
        match handles.get(&fh) {
            Some(handle) => {
                let offset = offset.max(0) as usize;
                if offset >= handle.data.len() {
                    reply.data(&[]);
                    return;
                }
                let end = (offset + size as usize).min(handle.data.len());
                reply.data(&handle.data[offset..end]);
            }
            None => reply.error(libc::EBADF),
        }
    }

    fn write(
        &mut self,
        _req: &Request<'_>,
        _ino: u64,
        fh: u64,
        offset: i64,
        data: &[u8],
        _write_flags: u32,
        _flags: i32,
        _lock_owner: Option<u64>,
        reply: ReplyWrite,
    ) {
        let mut handles = self.handles.lock().unwrap();
        match handles.get_mut(&fh) {
            Some(handle) => {
                let offset = offset.max(0) as usize;
                let end = offset + data.len();
                if handle.data.len() < end {
                    handle.data.resize(end, 0);
                }
                handle.data[offset..end].copy_from_slice(data);
                handle.dirty = true;
                reply.written(data.len() as u32);
            }
            None => reply.error(libc::EBADF),
        }
    }

    fn create(
        &mut self,
        _req: &Request<'_>,
        parent: u64,
        name: &OsStr,
        mode: u32,
        _umask: u32,
        _flags: i32,
        reply: ReplyCreate,
    ) {
        let name = match name.to_str() {
            Some(s) => s,
            None => {
                reply.error(libc::EINVAL);
                return;
            }
        };
        let conn = self.conn.lock().unwrap();
        if Self::lookup_ino(&conn, parent, name).is_some() {
            reply.error(libc::EEXIST);
            return;
        }
        let perm = mode & 0o777;
        conn.execute(
            "INSERT INTO inodes (kind, mode, size, target, mtime, nlink)
             VALUES (0, ?1, 0, NULL, ?2, 1)",
            params![perm as i64, now_secs()],
        )
        .unwrap();
        let ino = conn.last_insert_rowid() as u64;
        conn.execute(
            "INSERT INTO dirents (parent, name, ino) VALUES (?1, ?2, ?3)",
            params![parent as i64, name, ino as i64],
        )
        .unwrap();
        self.write_content(&conn, ino, &[]);

        let fh = self.new_fh();
        self.handles.lock().unwrap().insert(
            fh,
            Handle {
                ino,
                data: Vec::new(),
                dirty: false,
            },
        );

        match self.attr_of(&conn, ino) {
            Some(attr) => reply.created(&TTL, &attr, 0, fh, FOPEN_DIRECT_IO),
            None => reply.error(libc::EIO),
        }
    }

    fn open(&mut self, _req: &Request<'_>, ino: u64, _flags: i32, reply: ReplyOpen) {
        let conn = self.conn.lock().unwrap();
        if Self::load_inode(&conn, ino).is_none() {
            reply.error(libc::ENOENT);
            return;
        }
        let data = self.read_content(&conn, ino);
        let fh = self.new_fh();
        self.handles.lock().unwrap().insert(
            fh,
            Handle {
                ino,
                data,
                dirty: false,
            },
        );
        // FOPEN_DIRECT_IO: the kernel page cache would otherwise short-circuit reads
        // against a cached (possibly stale, TTL-bound) inode size instead of asking us --
        // we already hold the whole file in RAM per handle, so bypassing the page cache
        // costs nothing and keeps every read/write honest.
        reply.opened(fh, FOPEN_DIRECT_IO);
    }

    fn release(
        &mut self,
        _req: &Request<'_>,
        _ino: u64,
        fh: u64,
        _flags: i32,
        _lock_owner: Option<u64>,
        _flush: bool,
        reply: ReplyEmpty,
    ) {
        let conn = self.conn.lock().unwrap();
        let mut handles = self.handles.lock().unwrap();
        if let Some(mut handle) = handles.remove(&fh) {
            self.flush_handle(&conn, &mut handle);
        }
        reply.ok();
    }

    fn flush(
        &mut self,
        _req: &Request<'_>,
        _ino: u64,
        fh: u64,
        _lock_owner: u64,
        reply: ReplyEmpty,
    ) {
        let conn = self.conn.lock().unwrap();
        let mut handles = self.handles.lock().unwrap();
        if let Some(handle) = handles.get_mut(&fh) {
            self.flush_handle(&conn, handle);
        }
        reply.ok();
    }

    fn fsync(
        &mut self,
        _req: &Request<'_>,
        _ino: u64,
        fh: u64,
        _datasync: bool,
        reply: ReplyEmpty,
    ) {
        let conn = self.conn.lock().unwrap();
        let mut handles = self.handles.lock().unwrap();
        if let Some(handle) = handles.get_mut(&fh) {
            self.flush_handle(&conn, handle);
        }
        reply.ok();
    }

    fn mkdir(
        &mut self,
        _req: &Request<'_>,
        parent: u64,
        name: &OsStr,
        mode: u32,
        _umask: u32,
        reply: ReplyEntry,
    ) {
        let name = match name.to_str() {
            Some(s) => s,
            None => {
                reply.error(libc::EINVAL);
                return;
            }
        };
        let conn = self.conn.lock().unwrap();
        if Self::lookup_ino(&conn, parent, name).is_some() {
            reply.error(libc::EEXIST);
            return;
        }
        let perm = mode & 0o777;
        conn.execute(
            "INSERT INTO inodes (kind, mode, size, target, mtime, nlink)
             VALUES (1, ?1, 0, NULL, ?2, 2)",
            params![perm as i64, now_secs()],
        )
        .unwrap();
        let ino = conn.last_insert_rowid() as u64;
        conn.execute(
            "INSERT INTO dirents (parent, name, ino) VALUES (?1, ?2, ?3)",
            params![parent as i64, name, ino as i64],
        )
        .unwrap();
        match self.attr_of(&conn, ino) {
            Some(attr) => reply.entry(&TTL, &attr, 0),
            None => reply.error(libc::EIO),
        }
    }

    fn rmdir(&mut self, _req: &Request<'_>, parent: u64, name: &OsStr, reply: ReplyEmpty) {
        let name = match name.to_str() {
            Some(s) => s,
            None => {
                reply.error(libc::EINVAL);
                return;
            }
        };
        let conn = self.conn.lock().unwrap();
        let ino = match Self::lookup_ino(&conn, parent, name) {
            Some(i) => i,
            None => {
                reply.error(libc::ENOENT);
                return;
            }
        };
        if Self::has_children(&conn, ino) {
            reply.error(libc::ENOTEMPTY);
            return;
        }
        conn.execute(
            "DELETE FROM dirents WHERE parent=?1 AND name=?2",
            params![parent as i64, name],
        )
        .unwrap();
        conn.execute("DELETE FROM inodes WHERE ino=?1", params![ino as i64])
            .unwrap();
        reply.ok();
    }

    fn unlink(&mut self, _req: &Request<'_>, parent: u64, name: &OsStr, reply: ReplyEmpty) {
        let name = match name.to_str() {
            Some(s) => s,
            None => {
                reply.error(libc::EINVAL);
                return;
            }
        };
        let conn = self.conn.lock().unwrap();
        let ino = match Self::lookup_ino(&conn, parent, name) {
            Some(i) => i,
            None => {
                reply.error(libc::ENOENT);
                return;
            }
        };
        conn.execute(
            "DELETE FROM dirents WHERE parent=?1 AND name=?2",
            params![parent as i64, name],
        )
        .unwrap();
        conn.execute("DELETE FROM inodes WHERE ino=?1", params![ino as i64])
            .unwrap();
        self.delete_content(&conn, ino);
        self.handles.lock().unwrap().retain(|_, h| h.ino != ino);
        reply.ok();
    }

    fn rename(
        &mut self,
        _req: &Request<'_>,
        parent: u64,
        name: &OsStr,
        newparent: u64,
        newname: &OsStr,
        _flags: u32,
        reply: ReplyEmpty,
    ) {
        let name = match name.to_str() {
            Some(s) => s,
            None => {
                reply.error(libc::EINVAL);
                return;
            }
        };
        let newname = match newname.to_str() {
            Some(s) => s,
            None => {
                reply.error(libc::EINVAL);
                return;
            }
        };
        let conn = self.conn.lock().unwrap();
        let ino = match Self::lookup_ino(&conn, parent, name) {
            Some(i) => i,
            None => {
                reply.error(libc::ENOENT);
                return;
            }
        };

        if let Some(target_ino) = Self::lookup_ino(&conn, newparent, newname) {
            if target_ino == ino {
                reply.ok();
                return;
            }
            if let Some(row) = Self::load_inode(&conn, target_ino) {
                if row.kind == 1 && Self::has_children(&conn, target_ino) {
                    reply.error(libc::ENOTEMPTY);
                    return;
                }
            }
            conn.execute(
                "DELETE FROM dirents WHERE parent=?1 AND name=?2",
                params![newparent as i64, newname],
            )
            .unwrap();
            conn.execute("DELETE FROM inodes WHERE ino=?1", params![target_ino as i64])
                .unwrap();
            self.delete_content(&conn, target_ino);
        }

        conn.execute(
            "DELETE FROM dirents WHERE parent=?1 AND name=?2",
            params![parent as i64, name],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO dirents (parent, name, ino) VALUES (?1, ?2, ?3)",
            params![newparent as i64, newname, ino as i64],
        )
        .unwrap();
        reply.ok();
    }

    fn readdir(
        &mut self,
        _req: &Request<'_>,
        ino: u64,
        _fh: u64,
        offset: i64,
        mut reply: ReplyDirectory,
    ) {
        let conn = self.conn.lock().unwrap();
        if Self::load_inode(&conn, ino).is_none() {
            reply.error(libc::ENOENT);
            return;
        }
        let parent = Self::parent_of(&conn, ino);

        let mut entries: Vec<(u64, FileType, String)> = vec![
            (ino, FileType::Directory, ".".to_string()),
            (parent, FileType::Directory, "..".to_string()),
        ];

        let mut stmt = conn
            .prepare("SELECT ino, name FROM dirents WHERE parent=?1 ORDER BY name")
            .unwrap();
        let rows = stmt
            .query_map(params![ino as i64], |r| {
                Ok((r.get::<_, i64>(0)? as u64, r.get::<_, String>(1)?))
            })
            .unwrap();
        for row in rows {
            let (child_ino, name) = row.unwrap();
            let kind = Self::load_inode(&conn, child_ino)
                .map(|r| kind_to_file_type(r.kind))
                .unwrap_or(FileType::RegularFile);
            entries.push((child_ino, kind, name));
        }

        for (i, (e_ino, kind, name)) in entries.into_iter().enumerate().skip(offset as usize) {
            if reply.add(e_ino, (i + 1) as i64, kind, name) {
                break;
            }
        }
        reply.ok();
    }

    fn symlink(
        &mut self,
        _req: &Request<'_>,
        parent: u64,
        name: &OsStr,
        link: &std::path::Path,
        reply: ReplyEntry,
    ) {
        let name = match name.to_str() {
            Some(s) => s,
            None => {
                reply.error(libc::EINVAL);
                return;
            }
        };
        let target = match link.to_str() {
            Some(s) => s,
            None => {
                reply.error(libc::EINVAL);
                return;
            }
        };
        let conn = self.conn.lock().unwrap();
        if Self::lookup_ino(&conn, parent, name).is_some() {
            reply.error(libc::EEXIST);
            return;
        }
        conn.execute(
            "INSERT INTO inodes (kind, mode, size, target, mtime, nlink)
             VALUES (2, ?1, ?2, ?3, ?4, 1)",
            params![0o777i64, target.len() as i64, target, now_secs()],
        )
        .unwrap();
        let ino = conn.last_insert_rowid() as u64;
        conn.execute(
            "INSERT INTO dirents (parent, name, ino) VALUES (?1, ?2, ?3)",
            params![parent as i64, name, ino as i64],
        )
        .unwrap();
        match self.attr_of(&conn, ino) {
            Some(attr) => reply.entry(&TTL, &attr, 0),
            None => reply.error(libc::EIO),
        }
    }

    fn readlink(&mut self, _req: &Request<'_>, ino: u64, reply: ReplyData) {
        let conn = self.conn.lock().unwrap();
        let target: Option<String> = conn
            .query_row(
                "SELECT target FROM inodes WHERE ino=?1",
                params![ino as i64],
                |r| r.get(0),
            )
            .optional()
            .unwrap()
            .flatten();
        match target {
            Some(t) => reply.data(t.as_bytes()),
            None => reply.error(libc::ENOENT),
        }
    }

    fn statfs(&mut self, _req: &Request<'_>, _ino: u64, reply: ReplyStatfs) {
        let total_blocks: u64 = 1 << 30;
        reply.statfs(
            total_blocks,
            total_blocks - (1 << 20),
            total_blocks - (1 << 20),
            1 << 24,
            1 << 24,
            4096,
            255,
            4096,
        );
    }

    fn access(&mut self, _req: &Request<'_>, _ino: u64, _mask: i32, reply: ReplyEmpty) {
        reply.ok();
    }

    fn opendir(&mut self, _req: &Request<'_>, _ino: u64, _flags: i32, reply: ReplyOpen) {
        reply.opened(0, 0);
    }

    fn releasedir(
        &mut self,
        _req: &Request<'_>,
        _ino: u64,
        _fh: u64,
        _flags: i32,
        reply: ReplyEmpty,
    ) {
        reply.ok();
    }
}

fn parse_args() -> (String, Mode, String) {
    let args: Vec<String> = std::env::args().collect();
    let mut db_path = None;
    let mut mode_str = None;
    let mut mount_path = None;
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--db" => {
                db_path = args.get(i + 1).cloned();
                i += 2;
            }
            "--mode" => {
                mode_str = args.get(i + 1).cloned();
                i += 2;
            }
            "--mount" => {
                mount_path = args.get(i + 1).cloned();
                i += 2;
            }
            _ => {
                i += 1;
            }
        }
    }
    let db_path = db_path.expect("--db <path> is required");
    let mode = match mode_str.expect("--mode <cas|inline> is required").as_str() {
        "cas" => Mode::Cas,
        "inline" => Mode::Inline,
        other => panic!("unknown mode: {other}"),
    };
    let mount_path = mount_path.expect("--mount <dir> is required");
    (db_path, mode, mount_path)
}

fn main() {
    let (db_path, mode, mount_path) = parse_args();

    let conn = Connection::open(&db_path).expect("open sqlite db");
    FsInCell::init_schema(&conn, mode);

    let uid = unsafe { libc::getuid() };
    let gid = unsafe { libc::getgid() };

    let fs = FsInCell {
        conn: Mutex::new(conn),
        mode,
        next_fh: AtomicU64::new(1),
        handles: Mutex::new(HashMap::new()),
        uid,
        gid,
    };

    let options = vec![
        MountOption::FSName("fs_in_cell".to_string()),
        MountOption::AutoUnmount,
        MountOption::DefaultPermissions,
    ];

    fuser::mount2(fs, &mount_path, &options).expect("fuse mount failed");
}
