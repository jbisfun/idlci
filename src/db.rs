//! Job model and the SQLite store (`$ROOT/.pull/idlci/idlci.db`).

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use anyhow::{Context, Result};
use rusqlite::{Connection, OptionalExtension, Row, params};
use serde::{Deserialize, Serialize, de::DeserializeOwned};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema, clap::ValueEnum, Default)]
#[serde(rename_all = "kebab-case")]
pub enum Command {
    #[default]
    Build,
    Test,
    Lint,
    FmtCheck,
    Check,
    Clean,
}

impl Command {
    pub const ALL: [Command; 6] = [
        Command::Build,
        Command::Test,
        Command::Lint,
        Command::FmtCheck,
        Command::Check,
        Command::Clean,
    ];

    /// Arguments for `idl`, run from the project directory.
    pub fn idl_args(self, cfg: Configuration, strict: bool, targets: &[String]) -> Vec<String> {
        let mut args: Vec<String> = match self {
            Command::FmtCheck => vec!["fmt".into(), "--check".into()],
            _ => vec![name(&self)],
        };
        let cfg_flag = matches!(self, Command::Build | Command::Test | Command::Clean);
        if cfg_flag && cfg != Configuration::None {
            args.extend(["-c".into(), name(&cfg)]);
        }
        if strict && matches!(self, Command::Build | Command::Check) {
            args.push("--strict".into());
        }
        args.extend(targets.iter().cloned());
        args
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema, clap::ValueEnum)]
#[serde(rename_all = "lowercase")]
pub enum Status {
    Queued,
    Running,
    Passed,
    Failed,
    Cancelled,
}

impl Status {
    pub fn is_final(self) -> bool {
        !matches!(self, Status::Queued | Status::Running)
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema, clap::ValueEnum)]
#[serde(rename_all = "lowercase")]
pub enum Configuration {
    Debug,
    Release,
    #[default]
    None,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RequestedBy {
    Web,
    Mcp,
    Watch,
    #[default]
    Cli,
}

/// The serde name of a unit enum variant ("fmt-check", "queued", ...).
pub fn name<T: Serialize>(v: &T) -> String {
    match serde_json::to_value(v) {
        Ok(serde_json::Value::String(s)) => s,
        _ => String::new(),
    }
}

pub fn parse<T: DeserializeOwned>(s: &str) -> Result<T> {
    serde_json::from_value(serde_json::Value::String(s.into())).with_context(|| format!("invalid value {s:?}"))
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct GitInfo {
    pub repo: Option<String>,
    pub branch: Option<String>,
    pub head: Option<String>,
    pub dirty: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Job {
    pub id: i64,
    pub project: String,
    pub command: Command,
    pub targets: Vec<String>,
    pub configuration: Configuration,
    pub strict: bool,
    pub status: Status,
    pub exit_code: Option<i32>,
    /// Unix seconds.
    pub created: i64,
    pub started: Option<i64>,
    pub finished: Option<i64>,
    #[serde(flatten)]
    pub git: GitInfo,
    pub requested_by: RequestedBy,
    pub retry_of: Option<i64>,
    pub log: PathBuf,
}

impl Job {
    /// One line for the CLI and MCP tools.
    pub fn summary(&self) -> String {
        let mut s = format!("#{} {} {} {}", self.id, name(&self.status), name(&self.command), self.project);
        if !self.targets.is_empty() {
            s += &format!(" [{}]", self.targets.join(" "));
        }
        if self.configuration != Configuration::None {
            s += &format!(" -c {}", name(&self.configuration));
        }
        if self.strict {
            s += " --strict";
        }
        if let Some(code) = self.exit_code {
            s += &format!(" exit={code}");
        }
        if let (Some(a), Some(b)) = (self.started, self.finished) {
            s += &format!(" {}s", b - a);
        }
        if let Some(head) = &self.git.head {
            let dirty = if self.git.dirty { "+dirty" } else { "" };
            s += &format!(" @{}{head}{dirty}", self.git.branch.as_deref().map(|b| format!("{b}:")).unwrap_or_default());
        }
        s + &format!(" by {}", name(&self.requested_by))
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Enqueued {
    #[serde(flatten)]
    pub job: Job,
    /// An identical job was already queued; this is that job.
    pub deduplicated: bool,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, schemars::JsonSchema)]
pub struct NewJob {
    /// Project path relative to the workspace root (e.g. `fossify-ios/calculator-ios`) or pull repo name.
    pub project: String,
    pub command: Command,
    #[serde(default)]
    pub targets: Vec<String>,
    #[serde(default)]
    pub configuration: Configuration,
    #[serde(default)]
    pub strict: bool,
    #[serde(default)]
    #[schemars(skip)]
    pub requested_by: RequestedBy,
    #[serde(default)]
    #[schemars(skip)]
    pub retry_of: Option<i64>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct JobFilter {
    pub status: Option<Status>,
    pub project: Option<String>,
    pub limit: Option<usize>,
}

pub fn now() -> i64 {
    chrono::Utc::now().timestamp()
}

const COLS: &str = "id, project, command, targets, configuration, strict, status, exit_code, created, \
                    started, finished, repo, branch, head, dirty, requested_by, retry_of, log";

fn row(r: &Row) -> rusqlite::Result<Job> {
    let enum_col = |i: usize| -> rusqlite::Result<String> { r.get(i) };
    let bad = |i, e: anyhow::Error| rusqlite::Error::FromSqlConversionFailure(i, rusqlite::types::Type::Text, e.into());
    Ok(Job {
        id: r.get(0)?,
        project: r.get(1)?,
        command: parse(&enum_col(2)?).map_err(|e| bad(2, e))?,
        targets: serde_json::from_str(&enum_col(3)?).unwrap_or_default(),
        configuration: parse(&enum_col(4)?).map_err(|e| bad(4, e))?,
        strict: r.get(5)?,
        status: parse(&enum_col(6)?).map_err(|e| bad(6, e))?,
        exit_code: r.get(7)?,
        created: r.get(8)?,
        started: r.get(9)?,
        finished: r.get(10)?,
        git: GitInfo { repo: r.get(11)?, branch: r.get(12)?, head: r.get(13)?, dirty: r.get(14)? },
        requested_by: parse(&enum_col(15)?).map_err(|e| bad(15, e))?,
        retry_of: r.get(16)?,
        log: PathBuf::from(r.get::<_, String>(17)?),
    })
}

pub struct Store {
    conn: Mutex<Connection>,
    pub dir: PathBuf,
}

impl Store {
    /// Open (creating) the store under `$ROOT/.pull/idlci`.
    pub fn open(root: &Path) -> Result<Self> {
        let dir = data_dir(root);
        std::fs::create_dir_all(dir.join("logs"))?;
        let conn = Connection::open(dir.join("idlci.db"))?;
        conn.busy_timeout(std::time::Duration::from_secs(5))?;
        conn.execute_batch(
            "PRAGMA journal_mode=WAL;
             CREATE TABLE IF NOT EXISTS jobs (
               id INTEGER PRIMARY KEY AUTOINCREMENT,
               project TEXT NOT NULL, command TEXT NOT NULL, targets TEXT NOT NULL,
               configuration TEXT NOT NULL, strict INTEGER NOT NULL, status TEXT NOT NULL,
               exit_code INTEGER, created INTEGER NOT NULL, started INTEGER, finished INTEGER,
               repo TEXT, branch TEXT, head TEXT, dirty INTEGER NOT NULL DEFAULT 0,
               requested_by TEXT NOT NULL, retry_of INTEGER, log TEXT NOT NULL DEFAULT '',
               pid INTEGER);
             CREATE INDEX IF NOT EXISTS jobs_project ON jobs(project, command);
             CREATE INDEX IF NOT EXISTS jobs_status ON jobs(status);",
        )?;
        Ok(Self { conn: Mutex::new(conn), dir })
    }

    fn conn(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.conn.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Queue a job, or return the identical job that is already queued (`false`).
    pub fn insert(&self, new: &NewJob, git: &GitInfo) -> Result<(Job, bool)> {
        let conn = self.conn();
        let targets = serde_json::to_string(&new.targets)?;
        let (command, cfg) = (name(&new.command), name(&new.configuration));
        let existing = conn
            .query_row(
                &format!(
                    "SELECT {COLS} FROM jobs WHERE status = 'queued' AND project = ?1 AND command = ?2 \
                     AND targets = ?3 AND configuration = ?4 AND strict = ?5 ORDER BY id LIMIT 1"
                ),
                params![new.project, command, targets, cfg, new.strict],
                row,
            )
            .optional()?;
        if let Some(job) = existing {
            return Ok((job, false));
        }
        conn.execute(
            "INSERT INTO jobs (project, command, targets, configuration, strict, status, created, \
             repo, branch, head, dirty, requested_by, retry_of) \
             VALUES (?1, ?2, ?3, ?4, ?5, 'queued', ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
            params![
                new.project,
                command,
                targets,
                cfg,
                new.strict,
                now(),
                git.repo,
                git.branch,
                git.head,
                git.dirty,
                name(&new.requested_by),
                new.retry_of
            ],
        )?;
        let id = conn.last_insert_rowid();
        let log = self.dir.join("logs").join(format!("{id}.log"));
        conn.execute("UPDATE jobs SET log = ?1 WHERE id = ?2", params![log.to_string_lossy(), id])?;
        let job = conn.query_row(&format!("SELECT {COLS} FROM jobs WHERE id = ?1"), [id], row)?;
        Ok((job, true))
    }

    pub fn get(&self, id: i64) -> Result<Option<Job>> {
        Ok(self
            .conn()
            .query_row(&format!("SELECT {COLS} FROM jobs WHERE id = ?1"), [id], row)
            .optional()?)
    }

    pub fn list(&self, f: &JobFilter) -> Result<Vec<Job>> {
        let conn = self.conn();
        let mut stmt = conn.prepare(&format!(
            "SELECT {COLS} FROM jobs WHERE (?1 IS NULL OR status = ?1) AND (?2 IS NULL OR project = ?2) \
             ORDER BY id DESC LIMIT ?3"
        ))?;
        let status = f.status.map(|s| name(&s));
        let limit = f.limit.unwrap_or(100) as i64;
        let jobs = stmt.query_map(params![status, f.project, limit], row)?;
        Ok(jobs.collect::<rusqlite::Result<_>>()?)
    }

    /// Queued and running jobs, oldest first.
    pub fn active(&self) -> Result<Vec<Job>> {
        let conn = self.conn();
        let mut stmt = conn.prepare(&format!(
            "SELECT {COLS} FROM jobs WHERE status IN ('queued', 'running') ORDER BY id"
        ))?;
        let jobs = stmt.query_map([], row)?;
        Ok(jobs.collect::<rusqlite::Result<_>>()?)
    }

    /// Mark the oldest queued job running and return it.
    pub fn claim_next(&self) -> Result<Option<Job>> {
        Ok(self
            .conn()
            .query_row(
                &format!(
                    "UPDATE jobs SET status = 'running', started = ?1 WHERE id = \
                     (SELECT id FROM jobs WHERE status = 'queued' ORDER BY id LIMIT 1) RETURNING {COLS}"
                ),
                [now()],
                row,
            )
            .optional()?)
    }

    pub fn set_pid(&self, id: i64, pid: Option<i32>) -> Result<()> {
        self.conn().execute("UPDATE jobs SET pid = ?1 WHERE id = ?2", params![pid, id])?;
        Ok(())
    }

    pub fn finish(&self, id: i64, status: Status, exit_code: Option<i32>) -> Result<()> {
        self.conn().execute(
            "UPDATE jobs SET status = ?1, exit_code = ?2, finished = ?3, pid = NULL WHERE id = ?4",
            params![name(&status), exit_code, now(), id],
        )?;
        Ok(())
    }

    /// Cancel a job that hasn't started; false if it isn't queued.
    pub fn cancel_queued(&self, id: i64) -> Result<bool> {
        let n = self.conn().execute(
            "UPDATE jobs SET status = 'cancelled', finished = ?1 WHERE id = ?2 AND status = 'queued'",
            params![now(), id],
        )?;
        Ok(n > 0)
    }

    /// Jobs left `running` by a previous server: mark them failed, return (job, pid).
    pub fn recover(&self) -> Result<Vec<(Job, Option<i32>)>> {
        let conn = self.conn();
        let mut stmt = conn.prepare(&format!("SELECT {COLS}, pid FROM jobs WHERE status = 'running'"))?;
        let jobs = stmt.query_map([], |r| Ok((row(r)?, r.get(18)?)))?.collect::<rusqlite::Result<_>>()?;
        conn.execute(
            "UPDATE jobs SET status = 'failed', finished = ?1, pid = NULL WHERE status = 'running'",
            [now()],
        )?;
        Ok(jobs)
    }

    /// Newest finished jobs per project (for the dashboard), newest first.
    pub fn finished_per_project(&self, per_project: usize) -> Result<Vec<Job>> {
        let conn = self.conn();
        let mut stmt = conn.prepare(&format!(
            "SELECT {COLS} FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY project ORDER BY id DESC) AS n \
             FROM jobs WHERE status IN ('passed', 'failed', 'cancelled')) WHERE n <= ?1 ORDER BY id DESC"
        ))?;
        let jobs = stmt.query_map([per_project as i64], row)?;
        Ok(jobs.collect::<rusqlite::Result<_>>()?)
    }

    /// Latest job per (project, command).
    pub fn latest_per_command(&self) -> Result<Vec<Job>> {
        let conn = self.conn();
        let mut stmt = conn.prepare(&format!(
            "SELECT {COLS} FROM jobs WHERE id IN (SELECT MAX(id) FROM jobs GROUP BY project, command)"
        ))?;
        let jobs = stmt.query_map([], row)?;
        Ok(jobs.collect::<rusqlite::Result<_>>()?)
    }

    /// Duration of the last passed run of the same project + command (progress estimate).
    pub fn last_duration(&self, project: &str, command: Command) -> Result<Option<i64>> {
        Ok(self
            .conn()
            .query_row(
                "SELECT finished - started FROM jobs WHERE project = ?1 AND command = ?2 \
                 AND status = 'passed' ORDER BY id DESC LIMIT 1",
                params![project, name(&command)],
                |r| r.get(0),
            )
            .optional()?)
    }
}

pub fn data_dir(root: &Path) -> PathBuf {
    root.join(".pull").join("idlci")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn queue_dedupe_claim_finish() {
        let tmp = tempfile::tempdir().unwrap();
        let store = Store::open(tmp.path()).unwrap();
        let new = NewJob {
            project: "a/b".into(),
            command: Command::Build,
            targets: vec!["App".into()],
            ..Default::default()
        };
        let (j1, created) = store.insert(&new, &GitInfo::default()).unwrap();
        assert!(created);
        assert!(j1.log.ends_with(format!("logs/{}.log", j1.id)));
        let (j2, created) = store.insert(&new, &GitInfo::default()).unwrap();
        assert!(!created);
        assert_eq!(j1.id, j2.id);
        let claimed = store.claim_next().unwrap().unwrap();
        assert_eq!(claimed.status, Status::Running);
        assert!(store.claim_next().unwrap().is_none());
        // A running job doesn't block a new identical one.
        assert!(store.insert(&new, &GitInfo::default()).unwrap().1);
        store.finish(j1.id, Status::Passed, Some(0)).unwrap();
        let latest = store.latest_per_command().unwrap();
        assert_eq!(latest.len(), 1);
        assert_eq!(store.finished_per_project(5).unwrap().len(), 1);
        assert!(store.last_duration("a/b", Command::Build).unwrap().is_some());
        let queued = store.list(&JobFilter { status: Some(Status::Queued), ..Default::default() }).unwrap();
        assert_eq!(queued.len(), 1);
        assert!(store.cancel_queued(queued[0].id).unwrap());
        assert!(store.recover().unwrap().is_empty());
        store.insert(&new, &GitInfo::default()).unwrap();
        let running = store.claim_next().unwrap().unwrap();
        store.set_pid(running.id, Some(4242)).unwrap();
        let recovered = store.recover().unwrap();
        assert_eq!(recovered.len(), 1);
        assert_eq!(recovered[0].1, Some(4242));
        assert_eq!(store.get(running.id).unwrap().unwrap().status, Status::Failed);
    }

    #[test]
    fn idl_args() {
        let t = vec!["X".to_string()];
        assert_eq!(Command::FmtCheck.idl_args(Configuration::Release, true, &t), ["fmt", "--check", "X"]);
        assert_eq!(
            Command::Build.idl_args(Configuration::Release, true, &t),
            ["build", "-c", "release", "--strict", "X"]
        );
        assert_eq!(Command::Test.idl_args(Configuration::None, true, &[]), ["test"]);
    }
}
