//! idlci: a local CI service for idl projects in a pull workspace.

mod client;
mod db;
mod mcp;
mod projects;
mod runner;
mod watch;
mod web;

use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};

use client::Client;
use db::{Command, Configuration, Enqueued, Job, NewJob, RequestedBy, Status, name};

#[derive(Parser)]
#[command(version, about)]
struct Cli {
    /// Workspace root (default: $PULL_ROOT, else the nearest parent with pullfile.plist).
    #[arg(long, global = true, env = "PULL_ROOT")]
    root: Option<PathBuf>,
    /// Server address (serve: listen address, default 127.0.0.1:8737; clients: default from
    /// .pull/idlci/serve.addr).
    #[arg(long, global = true, env = "IDLCI_ADDR")]
    addr: Option<String>,
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Web UI + JSON API + job workers.
    Serve {
        /// Concurrent jobs (builds are CPU-heavy).
        #[arg(long, default_value_t = 1)]
        jobs: usize,
        /// Queue build + test when a project's git HEAD changes.
        #[arg(long)]
        watch: bool,
        /// Seconds between HEAD polls with --watch.
        #[arg(long, default_value_t = 15)]
        watch_interval: u64,
    },
    /// MCP server on stdio (starts `idlci serve` if it isn't running).
    Mcp,
    /// Queue a job.
    Queue {
        project: String,
        command: Command,
        targets: Vec<String>,
        #[arg(short, long, value_enum, default_value_t = Configuration::None)]
        configuration: Configuration,
        #[arg(long)]
        strict: bool,
        /// Follow the log until the job finishes; exit nonzero unless it passed.
        #[arg(short, long)]
        wait: bool,
    },
    /// List jobs.
    Jobs {
        #[arg(long, value_enum)]
        status: Option<Status>,
        #[arg(long)]
        project: Option<String>,
        #[arg(long, default_value_t = 20)]
        limit: usize,
    },
    /// Print a job's log.
    Log {
        id: i64,
        /// Follow until the job finishes.
        #[arg(short, long)]
        follow: bool,
    },
    /// Cancel a queued or running job.
    Cancel { id: i64 },
    /// Queue a job again.
    Retry { id: i64 },
}

fn find_root(arg: Option<PathBuf>) -> Result<PathBuf> {
    let root = match arg {
        Some(r) => r,
        None => {
            let cwd = std::env::current_dir()?;
            cwd.ancestors()
                .find(|d| d.join("pullfile.plist").is_file())
                .map(Path::to_path_buf)
                .context("no workspace root: pass --root, set PULL_ROOT, or run inside a pull workspace")?
        }
    };
    root.canonicalize().with_context(|| format!("workspace root {}", root.display()))
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let root = find_root(cli.root)?;
    let rt = tokio::runtime::Builder::new_multi_thread().enable_all().build()?;
    rt.block_on(async move {
        let client = || Client::connect(&root, cli.addr.as_deref(), true);
        match cli.cmd {
            Cmd::Serve { jobs, watch, watch_interval } => {
                let addr = cli.addr.clone().unwrap_or_else(|| client::DEFAULT_ADDR.into());
                web::serve(root.clone(), &addr, jobs, watch.then_some(watch_interval)).await
            }
            Cmd::Mcp => mcp::serve(root.clone(), cli.addr.clone()).await,
            Cmd::Queue { project, command, targets, configuration, strict, wait } => {
                let c = client().await?;
                let new = NewJob { project, command, targets, configuration, strict, requested_by: RequestedBy::Cli, retry_of: None };
                let e: Enqueued = c.post("/api/jobs", &new).await?;
                println!("{}{}", e.job.summary(), if e.deduplicated { " (already queued)" } else { "" });
                if wait {
                    let job = follow(&c, e.job.id).await?;
                    if job.status != Status::Passed {
                        bail!("job #{} {}", job.id, name(&job.status));
                    }
                }
                Ok(())
            }
            Cmd::Jobs { status, project, limit } => {
                let mut q = vec![("limit", limit.to_string())];
                q.extend(status.map(|s| ("status", name(&s))));
                q.extend(project.map(|p| ("project", p)));
                let jobs: Vec<Job> = client().await?.get_query("/api/jobs", &q).await?;
                jobs.iter().for_each(|j| println!("{}", j.summary()));
                Ok(())
            }
            Cmd::Log { id, follow: true } => follow(&client().await?, id).await.map(drop),
            Cmd::Log { id, follow: false } => {
                let l: web::LogChunk = client().await?.get(&format!("/api/jobs/{id}/log?tail=1000000")).await?;
                println!("{}", l.text);
                Ok(())
            }
            Cmd::Cancel { id } => {
                let job: Job = client().await?.post(&format!("/api/jobs/{id}/cancel"), &()).await?;
                println!("{}", job.summary());
                Ok(())
            }
            Cmd::Retry { id } => {
                let e: Enqueued = client().await?.post(&format!("/api/jobs/{id}/retry?by=cli"), &()).await?;
                println!("{}", e.job.summary());
                Ok(())
            }
        }
    })
}

/// Stream a job's log to stdout until it finishes.
async fn follow(c: &Client, id: i64) -> Result<Job> {
    use std::io::Write;
    let mut offset = 0;
    loop {
        let l: web::LogChunk = c.get(&format!("/api/jobs/{id}/log?offset={offset}")).await?;
        print!("{}", l.text);
        std::io::stdout().flush()?;
        offset = l.next_offset;
        if l.status.is_final() && offset >= l.size {
            return c.get(&format!("/api/jobs/{id}")).await;
        }
        if l.text.is_empty() {
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
    }
}
