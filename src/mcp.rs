//! `idlci mcp`: stdio MCP server for agents, a thin layer over the `idlci serve` HTTP API
//! (started on demand).

use std::fmt::Write as _;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use rmcp::{
    ServerHandler, ServiceExt,
    handler::server::{router::tool::ToolRouter, wrapper::Parameters},
    model::{ServerCapabilities, ServerConfig},
    schemars, tool, tool_handler, tool_router,
};
use serde::Deserialize;

use crate::client::Client;
use crate::db::{Command, Configuration, Enqueued, Job, NewJob, RequestedBy, Status, name};
use crate::web::{LogChunk, ProjectView};

type ToolResult = Result<String, String>;

fn err(e: impl std::fmt::Display) -> String {
    format!("{e:#}")
}

#[derive(Deserialize, schemars::JsonSchema)]
struct QueueArgs {
    /// Project path relative to the workspace root (e.g. `fossify-ios/calculator-ios`), pull repo name, or last path segment.
    project: String,
    command: Command,
    /// Targets (default: all).
    targets: Option<Vec<String>>,
    /// debug | release (default: idl's default).
    configuration: Option<Configuration>,
    /// --strict (build/check only).
    strict: Option<bool>,
}

#[derive(Deserialize, schemars::JsonSchema)]
struct JobsArgs {
    status: Option<Status>,
    project: Option<String>,
    /// Default 20.
    limit: Option<usize>,
}

#[derive(Deserialize, schemars::JsonSchema)]
struct JobArgs {
    id: i64,
    /// Log lines to include from the end (default 40).
    lines: Option<usize>,
}

#[derive(Deserialize, schemars::JsonSchema)]
struct LogArgs {
    id: i64,
    /// Byte offset to read from (use the returned next_offset to continue).
    offset: Option<u64>,
    /// Only the last N lines (overrides offset).
    tail: Option<usize>,
}

#[derive(Deserialize, schemars::JsonSchema)]
struct WaitArgs {
    id: i64,
    /// Seconds to wait (default 300, max 600).
    timeout_s: Option<u64>,
    /// Log lines to include from the end (default 40).
    lines: Option<usize>,
}

#[derive(Deserialize, schemars::JsonSchema)]
struct IdArgs {
    id: i64,
}

#[derive(Clone)]
pub struct IdlciMcp {
    root: PathBuf,
    addr: Option<String>,
    tool_router: ToolRouter<Self>,
}

impl IdlciMcp {
    async fn client(&self) -> Result<Client, String> {
        Client::connect(&self.root, self.addr.as_deref(), true).await.map_err(err)
    }

    async fn with_tail(&self, c: &Client, job: &Job, lines: Option<usize>) -> ToolResult {
        let n = lines.unwrap_or(40);
        let log: LogChunk = c.get(&format!("/api/jobs/{}/log?tail={n}", job.id)).await.map_err(err)?;
        Ok(format!("{}\nlog: {}\n--- last {n} log lines ---\n{}", job.summary(), job.log.display(), log.text))
    }
}

#[tool_router]
impl IdlciMcp {
    #[tool(description = "List idl projects in the workspace with git state, targets and the latest job per command.")]
    async fn projects(&self) -> ToolResult {
        let c = self.client().await?;
        let projects: Vec<ProjectView> = c.get("/api/projects").await.map_err(err)?;
        let mut out = String::new();
        for p in projects {
            let git = format!(
                "{}@{}{}",
                p.git.branch.as_deref().unwrap_or("-"),
                p.git.head.as_deref().unwrap_or("-"),
                if p.git.dirty { " dirty" } else { "" }
            );
            let last: Vec<String> =
                p.last.iter().map(|(cmd, b)| format!("{cmd}:{}#{}", name(&b.status), b.id)).collect();
            let _ = writeln!(out, "{}  (repo {}, {git})  {}", p.path, p.git.repo.as_deref().unwrap_or("-"), last.join(" "));
            let targets: Vec<String> = p.targets.iter().map(|t| format!("{}({})", t.name, t.kind)).collect();
            let _ = writeln!(out, "    targets: {}", targets.join(" "));
        }
        Ok(out)
    }

    #[tool(
        description = "Queue an idl job (build|test|lint|fmt-check|check|clean) for a project; returns the job id. \
                       Use `wait` to block until it finishes."
    )]
    async fn queue(&self, Parameters(a): Parameters<QueueArgs>) -> ToolResult {
        let c = self.client().await?;
        let new = NewJob {
            project: a.project,
            command: a.command,
            targets: a.targets.unwrap_or_default(),
            configuration: a.configuration.unwrap_or_default(),
            strict: a.strict.unwrap_or(false),
            requested_by: RequestedBy::Mcp,
            retry_of: None,
        };
        let e: Enqueued = c.post("/api/jobs", &new).await.map_err(err)?;
        let note = if e.deduplicated { " (an identical job was already queued)" } else { "" };
        Ok(format!("queued job {}{note}\n{}", e.job.id, e.job.summary()))
    }

    #[tool(description = "List jobs, newest first (filters: status, project, limit).")]
    async fn jobs(&self, Parameters(a): Parameters<JobsArgs>) -> ToolResult {
        let c = self.client().await?;
        let mut q = vec![("limit", a.limit.unwrap_or(20).to_string())];
        q.extend(a.status.map(|s| ("status", name(&s))));
        q.extend(a.project.map(|p| ("project", p)));
        let jobs: Vec<Job> = c.get_query("/api/jobs", &q).await.map_err(err)?;
        if jobs.is_empty() {
            return Ok("no jobs".into());
        }
        Ok(jobs.iter().map(Job::summary).collect::<Vec<_>>().join("\n"))
    }

    #[tool(description = "Job metadata plus the last log lines.")]
    async fn job(&self, Parameters(a): Parameters<JobArgs>) -> ToolResult {
        let c = self.client().await?;
        let job: Job = c.get(&format!("/api/jobs/{}", a.id)).await.map_err(err)?;
        self.with_tail(&c, &job, a.lines).await
    }

    #[tool(description = "Read a job's log: from a byte offset (up to 1 MiB, returns next_offset) or the last `tail` lines.")]
    async fn log(&self, Parameters(a): Parameters<LogArgs>) -> ToolResult {
        let c = self.client().await?;
        let q = match a.tail {
            Some(n) => format!("tail={n}"),
            None => format!("offset={}", a.offset.unwrap_or(0)),
        };
        let l: LogChunk = c.get(&format!("/api/jobs/{}/log?{q}", a.id)).await.map_err(err)?;
        Ok(format!("[job #{} {} size={} next_offset={}]\n{}", l.id, name(&l.status), l.size, l.next_offset, l.text))
    }

    #[tool(description = "Block until a job finishes (or timeout_s, default 300, max 600); returns its status and log tail.")]
    async fn wait(&self, Parameters(a): Parameters<WaitArgs>) -> ToolResult {
        let c = self.client().await?;
        let deadline = Instant::now() + Duration::from_secs(a.timeout_s.unwrap_or(300).min(600));
        loop {
            let job: Job = c.get(&format!("/api/jobs/{}", a.id)).await.map_err(err)?;
            if job.status.is_final() {
                return self.with_tail(&c, &job, a.lines).await;
            }
            if Instant::now() >= deadline {
                let out = self.with_tail(&c, &job, a.lines).await?;
                return Ok(format!("still {} after timeout; call wait again\n{out}", name(&job.status)));
            }
            tokio::time::sleep(Duration::from_secs(2)).await;
        }
    }

    #[tool(description = "Cancel a queued job or abort a running one (kills its whole process group).")]
    async fn cancel(&self, Parameters(a): Parameters<IdArgs>) -> ToolResult {
        let c = self.client().await?;
        let job: Job = c.post(&format!("/api/jobs/{}/cancel", a.id), &()).await.map_err(err)?;
        Ok(job.summary())
    }

    #[tool(description = "Queue the same job again; returns the new job id.")]
    async fn retry(&self, Parameters(a): Parameters<IdArgs>) -> ToolResult {
        let c = self.client().await?;
        let e: Enqueued = c.post(&format!("/api/jobs/{}/retry?by=mcp", a.id), &()).await.map_err(err)?;
        Ok(format!("queued job {}\n{}", e.job.id, e.job.summary()))
    }
}

#[tool_handler(router = self.tool_router)]
impl ServerHandler for IdlciMcp {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(ServerCapabilities::builder().enable_tools().build()).with_instructions(
            "idlci: local CI for idl (iOS) projects in this pull workspace. `projects` lists projects and \
             targets; `queue` a build/test/lint/fmt-check/check/clean job, then `wait` for it (returns status \
             and log tail); `jobs`/`job`/`log` inspect, `cancel`/`retry` manage. Jobs run one at a time on a \
             shared queue (the laptop overheats), so prefer targeted jobs and don't queue duplicates.",
        )
    }
}

pub async fn serve(root: PathBuf, addr: Option<String>) -> anyhow::Result<()> {
    let server = IdlciMcp { root, addr, tool_router: IdlciMcp::tool_router() };
    let service = server.serve(rmcp::transport::stdio()).await?;
    service.waiting().await?;
    Ok(())
}
