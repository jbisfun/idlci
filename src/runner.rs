//! Workers: run queued jobs as `idl` process groups, log to `logs/<id>.log`.

use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::os::unix::process::ExitStatusExt;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Result, bail};
use nix::sys::signal::{Signal, killpg};
use nix::unistd::Pid;
use serde::Serialize;
use tokio::sync::Notify;

use crate::db::{Job, Status, Store, name};

pub struct Runner {
    pub store: Arc<Store>,
    pub root: PathBuf,
    pub idl: PathBuf,
    pub executors: usize,
    notify: Notify,
    /// job id -> (process group id, executor index)
    running: Mutex<HashMap<i64, (i32, usize)>>,
    cancelling: Mutex<HashSet<i64>>,
}

#[derive(Serialize)]
pub struct Executor {
    pub number: usize,
    pub job: Option<Job>,
    /// Estimated progress 0..=100 from the last passed run of the same project + command.
    pub progress: Option<i64>,
}

impl Runner {
    pub fn new(store: Arc<Store>, root: PathBuf, idl: PathBuf, executors: usize) -> Arc<Self> {
        Arc::new(Self {
            store,
            root,
            idl,
            executors: executors.max(1),
            notify: Notify::new(),
            running: Mutex::default(),
            cancelling: Mutex::default(),
        })
    }

    /// Fail jobs a previous server left running and kill their leftover process groups.
    pub fn recover(&self) -> Result<()> {
        for (job, pid) in self.store.recover()? {
            if let Some(pid) = pid.filter(|&p| is_idl(p)) {
                eprintln!("idlci: killing leftover process group {pid} of job #{}", job.id);
                let _ = killpg(Pid::from_raw(pid), Signal::SIGTERM);
                tokio::spawn(async move {
                    tokio::time::sleep(Duration::from_secs(5)).await;
                    let _ = killpg(Pid::from_raw(pid), Signal::SIGKILL);
                });
            }
            append(&job, "\n[idlci] server restarted while this job was running; marked failed\n");
        }
        Ok(())
    }

    pub fn start(self: &Arc<Self>) {
        for n in 0..self.executors {
            tokio::spawn(self.clone().worker(n));
        }
    }

    /// Wake a worker after queueing.
    pub fn kick(&self) {
        self.notify.notify_one();
    }

    async fn worker(self: Arc<Self>, n: usize) {
        loop {
            match self.store.claim_next() {
                Ok(Some(job)) => self.run(job, n).await,
                Ok(None) => {
                    let _ = tokio::time::timeout(Duration::from_secs(5), self.notify.notified()).await;
                }
                Err(e) => {
                    eprintln!("idlci: worker {n}: {e:#}");
                    tokio::time::sleep(Duration::from_secs(5)).await;
                }
            }
        }
    }

    async fn run(&self, job: Job, executor: usize) {
        let args = job.command.idl_args(job.configuration, job.strict, &job.targets);
        let dir = self.root.join(&job.project);
        let header = format!(
            "[idlci] job #{} on executor #{} in {}\n[idlci] git {} {}@{}{}\n$ idl {}\n",
            job.id,
            executor + 1,
            dir.display(),
            job.git.repo.as_deref().unwrap_or("-"),
            job.git.branch.as_deref().unwrap_or("-"),
            job.git.head.as_deref().unwrap_or("-"),
            if job.git.dirty { " (dirty)" } else { "" },
            args.join(" ")
        );
        let spawned = std::fs::File::create(&job.log).and_then(|mut log| {
            log.write_all(header.as_bytes())?;
            let err = log.try_clone()?;
            tokio::process::Command::new(&self.idl)
                .args(&args)
                .current_dir(&dir)
                .env("PULL_ROOT", &self.root)
                .stdin(std::process::Stdio::null())
                .stdout(log)
                .stderr(err)
                .process_group(0)
                .spawn()
        });
        let mut child = match spawned {
            Ok(child) => child,
            Err(e) => {
                append(&job, &format!("[idlci] failed to start {}: {e}\n", self.idl.display()));
                let _ = self.store.finish(job.id, Status::Failed, None);
                return;
            }
        };
        let pid = child.id().map(|p| p as i32);
        if let Some(pid) = pid {
            self.running.lock().unwrap().insert(job.id, (pid, executor));
        }
        let _ = self.store.set_pid(job.id, pid);
        let result = child.wait().await;
        self.running.lock().unwrap().remove(&job.id);
        let cancelled = self.cancelling.lock().unwrap().remove(&job.id);
        let code = result.as_ref().ok().and_then(|s| s.code().or_else(|| s.signal().map(|s| 128 + s)));
        let status = match &result {
            _ if cancelled => Status::Cancelled,
            Ok(s) if s.success() => Status::Passed,
            _ => Status::Failed,
        };
        let took = job.started.map(|s| crate::db::now() - s).unwrap_or(0);
        append(
            &job,
            &format!("\n[idlci] finished: {} (exit {}) in {took}s\n", name(&status), code.map_or("-".into(), |c| c.to_string())),
        );
        if let Err(e) = self.store.finish(job.id, status, code) {
            eprintln!("idlci: job #{}: {e:#}", job.id);
        }
    }

    /// Cancel a queued job, or SIGTERM (then SIGKILL after 5s) a running job's process group.
    pub fn cancel(&self, id: i64) -> Result<()> {
        if self.store.cancel_queued(id)? {
            return Ok(());
        }
        let Some((pgid, _)) = self.running.lock().unwrap().get(&id).copied() else {
            bail!("job #{id} is not queued or running");
        };
        self.cancelling.lock().unwrap().insert(id);
        let _ = killpg(Pid::from_raw(pgid), Signal::SIGTERM);
        // Children (compilers) may outlive the group leader, so kill the group regardless.
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs(5)).await;
            let _ = killpg(Pid::from_raw(pgid), Signal::SIGKILL);
        });
        Ok(())
    }

    /// Kill every running job (server shutdown) and wait briefly for workers to record it.
    pub async fn shutdown(&self) {
        let ids: Vec<_> = self.running.lock().unwrap().keys().copied().collect();
        for id in ids {
            let _ = self.cancel(id);
        }
        for _ in 0..30 {
            if self.running.lock().unwrap().is_empty() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        for (pgid, _) in self.running.lock().unwrap().values() {
            let _ = killpg(Pid::from_raw(*pgid), Signal::SIGKILL);
        }
    }

    pub fn executors(&self) -> Vec<Executor> {
        let running = self.running.lock().unwrap().clone();
        (0..self.executors)
            .map(|n| {
                let job = running
                    .iter()
                    .find(|(_, (_, e))| *e == n)
                    .and_then(|(id, _)| self.store.get(*id).ok().flatten());
                let progress = job.as_ref().and_then(|j| {
                    let total = self.store.last_duration(&j.project, j.command).ok()??;
                    let spent = crate::db::now() - j.started?;
                    Some((spent * 100 / total.max(1)).min(99))
                });
                Executor { number: n + 1, job, progress }
            })
            .collect()
    }
}

fn append(job: &Job, text: &str) {
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&job.log) {
        let _ = f.write_all(text.as_bytes());
    }
}

/// Whether `pid` is still alive and an `idl` process (guards against pid reuse).
fn is_idl(pid: i32) -> bool {
    std::fs::read(format!("/proc/{pid}/cmdline"))
        .map(|c| {
            let argv0 = c.split(|&b| b == 0).next().unwrap_or_default();
            argv0.ends_with(b"idl")
        })
        .unwrap_or(false)
}
