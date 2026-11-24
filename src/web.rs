//! `idlci serve`: axum web UI + JSON API over the queue, with the workers in-process.

use std::collections::{BTreeMap, HashMap};
use std::convert::Infallible;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};

use anyhow::{Context, Result, bail};
use axum::extract::{Path as UrlPath, Query, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::sse::{Event, KeepAlive, Sse};
use axum::response::{Html, IntoResponse, Redirect, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use futures_core::Stream;
use minijinja::value::Serde;
use minijinja::{Environment, Value, context};
use serde::{Deserialize, Serialize};

use crate::db::{self, Command, Enqueued, GitInfo, Job, JobFilter, NewJob, RequestedBy, Status, Store};
use crate::projects::{self, Project, Target};
use crate::runner::Runner;

/// `idl list` results keyed by project dir, with the idlproj.yml mtime they were read at.
type TargetCache = HashMap<PathBuf, (SystemTime, Arc<Vec<Target>>)>;

pub struct App {
    pub root: PathBuf,
    pub store: Arc<Store>,
    pub runner: Arc<Runner>,
    pub watch: bool,
    env: Environment<'static>,
    projects: Mutex<Option<(Instant, Arc<Vec<Project>>)>>,
    targets: Mutex<TargetCache>,
}

/// Latest-job reference used in project views.
#[derive(Clone, Serialize, Deserialize)]
pub struct Brief {
    pub id: i64,
    pub status: Status,
    pub created: i64,
    pub started: Option<i64>,
    pub finished: Option<i64>,
}

impl From<&Job> for Brief {
    fn from(j: &Job) -> Self {
        Brief { id: j.id, status: j.status, created: j.created, started: j.started, finished: j.finished }
    }
}

#[derive(Clone, Serialize, Deserialize)]
pub struct ProjectView {
    pub path: String,
    pub name: String,
    #[serde(flatten)]
    pub git: GitInfo,
    pub targets: Vec<Target>,
    pub targets_error: Option<String>,
    /// Latest job per command ("build", "test", ...).
    pub last: BTreeMap<String, Brief>,
    pub last_build: Option<Brief>,
    pub last_success: Option<Brief>,
    pub last_failure: Option<Brief>,
    pub running: bool,
    /// Pass rate (%) of the last 5 passed/failed jobs.
    pub health: Option<i64>,
}

impl App {
    pub fn new(root: PathBuf, store: Arc<Store>, runner: Arc<Runner>, watch: bool) -> Arc<Self> {
        let mut env = Environment::new();
        for (name, src) in [
            ("base.html", include_str!("../templates/base.html")),
            ("macros.html", include_str!("../templates/macros.html")),
            ("dashboard.html", include_str!("../templates/dashboard.html")),
            ("project.html", include_str!("../templates/project.html")),
            ("job.html", include_str!("../templates/job.html")),
            ("jobs.html", include_str!("../templates/jobs.html")),
        ] {
            env.add_template(name, src).expect("template");
        }
        env.add_filter("dt", |ts: i64| {
            chrono::DateTime::from_timestamp(ts, 0)
                .map(|t| t.with_timezone(&chrono::Local).format("%b %-d, %Y, %-I:%M:%S %p").to_string())
                .unwrap_or_default()
        });
        env.add_filter("dts", |ts: i64| {
            chrono::DateTime::from_timestamp(ts, 0)
                .map(|t| t.with_timezone(&chrono::Local).format("%b %-d, %-I:%M %p").to_string())
                .unwrap_or_default()
        });
        env.add_filter("ago", |ts: i64| human(db::now() - ts));
        env.add_filter("dur", |started: Option<i64>, finished: Option<i64>| {
            started.map(|s| human(finished.unwrap_or_else(db::now) - s)).unwrap_or_default()
        });
        Arc::new(Self { root, store, runner, watch, env, projects: Mutex::default(), targets: Mutex::default() })
    }

    /// Discovered projects, rescanned at most every 30s.
    pub fn projects(&self) -> Arc<Vec<Project>> {
        let mut cache = self.projects.lock().unwrap();
        match &*cache {
            Some((at, p)) if at.elapsed() < Duration::from_secs(30) => p.clone(),
            _ => {
                let p = Arc::new(projects::discover(&self.root));
                *cache = Some((Instant::now(), p.clone()));
                p
            }
        }
    }

    pub fn resolve(&self, arg: &str) -> Result<Project> {
        Ok(projects::resolve(&self.root, &self.projects(), arg)?.clone())
    }

    /// `idl list` for a project, cached until idlproj.yml changes.
    pub async fn targets(&self, p: &Project) -> Result<Arc<Vec<Target>>> {
        let mtime = std::fs::metadata(p.dir.join("idlproj.yml"))?.modified()?;
        if let Some((m, t)) = self.targets.lock().unwrap().get(&p.dir)
            && *m == mtime
        {
            return Ok(t.clone());
        }
        let t = Arc::new(projects::targets(&self.runner.idl, &p.dir).await?);
        self.targets.lock().unwrap().insert(p.dir.clone(), (mtime, t.clone()));
        Ok(t)
    }

    pub async fn enqueue(&self, mut new: NewJob) -> Result<Enqueued> {
        let p = self.resolve(&new.project)?;
        if !new.targets.is_empty()
            && let Ok(known) = self.targets(&p).await
        {
            let unknown: Vec<_> = new.targets.iter().filter(|t| !known.iter().any(|k| &k.name == *t)).cloned().collect();
            if !unknown.is_empty() {
                let names: Vec<_> = known.iter().map(|k| k.name.as_str()).collect();
                bail!("unknown target(s) {} in {}; targets: {}", unknown.join(", "), p.path, names.join(", "));
            }
        }
        new.project = p.path.clone();
        let (root, dir) = (self.root.clone(), p.dir.clone());
        let git = tokio::task::spawn_blocking(move || projects::git_info(&root, &dir)).await?;
        let (job, created) = self.store.insert(&new, &git)?;
        if created {
            self.runner.kick();
        }
        Ok(Enqueued { job, deduplicated: !created })
    }

    async fn project_views(&self, only: Option<&str>) -> Result<Vec<ProjectView>> {
        let latest = self.store.latest_per_command()?;
        let finished = self.store.finished_per_project(50)?;
        let active = self.store.active()?;
        let mut out = Vec::new();
        for p in self.projects().iter().filter(|p| only.is_none_or(|o| o == p.path)) {
            let (targets, targets_error) = match self.targets(p).await {
                Ok(t) => (t.to_vec(), None),
                Err(e) => (Vec::new(), Some(format!("{e:#}"))),
            };
            let mine: Vec<&Job> = finished.iter().filter(|j| j.project == p.path).collect();
            // Weather counts passed/failed only (aborted builds don't affect it, like Jenkins).
            let rated: Vec<&&Job> = mine.iter().filter(|j| j.status != Status::Cancelled).take(5).collect();
            let passed = rated.iter().filter(|j| j.status == Status::Passed).count() as i64;
            out.push(ProjectView {
                name: p.path.rsplit('/').next().unwrap_or(&p.path).to_string(),
                path: p.path.clone(),
                git: projects::git_info(&self.root, &p.dir),
                targets,
                targets_error,
                last: latest
                    .iter()
                    .filter(|j| j.project == p.path)
                    .map(|j| (db::name(&j.command), Brief::from(j)))
                    .collect(),
                last_build: mine.first().map(|j| Brief::from(*j)),
                last_success: mine.iter().find(|j| j.status == Status::Passed).map(|j| Brief::from(*j)),
                last_failure: mine.iter().find(|j| j.status == Status::Failed).map(|j| Brief::from(*j)),
                running: active.iter().any(|j| j.project == p.path && j.status == Status::Running),
                health: (!rated.is_empty()).then(|| passed * 100 / rated.len() as i64),
            });
        }
        Ok(out)
    }

    fn render(&self, name: &str, ctx: Value) -> Result<Html<String>, Error> {
        let active = self.store.active()?;
        let base = context! {
            root => self.root.display().to_string(),
            watch => self.watch,
            version => env!("CARGO_PKG_VERSION"),
            commands => Command::ALL.iter().map(db::name).collect::<Vec<_>>(),
            queue => Serde(active.iter().filter(|j| j.status == Status::Queued).collect::<Vec<_>>()),
            executors => Serde(self.runner.executors()),
            active => !active.is_empty(),
        };
        let html = self.env.get_template(name)?.render(context! { ..ctx, ..base })?;
        Ok(Html(html))
    }
}

fn human(secs: i64) -> String {
    let s = secs.max(0);
    match s {
        0..60 => format!("{s} sec"),
        60..3600 => format!("{} min {} sec", s / 60, s % 60),
        3600..86400 => format!("{} hr {} min", s / 3600, s % 3600 / 60),
        _ => format!("{} days", s / 86400),
    }
}

pub struct Error(StatusCode, String);

impl IntoResponse for Error {
    fn into_response(self) -> Response {
        (self.0, Json(serde_json::json!({ "error": self.1 }))).into_response()
    }
}

impl<E: Into<anyhow::Error>> From<E> for Error {
    fn from(e: E) -> Self {
        Error(StatusCode::INTERNAL_SERVER_ERROR, format!("{:#}", e.into()))
    }
}

fn bad(e: impl Into<anyhow::Error>) -> Error {
    Error(StatusCode::BAD_REQUEST, format!("{:#}", e.into()))
}

fn job_or_404(app: &App, id: i64) -> Result<Job, Error> {
    app.store.get(id)?.ok_or_else(|| Error(StatusCode::NOT_FOUND, format!("no job #{id}")))
}

type St = State<Arc<App>>;

pub fn router(app: Arc<App>) -> Router {
    Router::new()
        .route("/", get(dashboard))
        .route("/projects/{*path}", get(project_page))
        .route("/jobs", get(jobs_page))
        .route("/jobs/{id}", get(job_page))
        .route("/jobs/{id}/console", get(console_text))
        .route("/search", get(search))
        .route("/assets/{*file}", get(asset))
        .route("/api/health", get(health))
        .route("/api/projects", get(api_projects))
        .route("/api/projects/{*path}", get(api_project))
        .route("/api/jobs", get(api_jobs).post(api_enqueue))
        .route("/api/jobs/{id}", get(api_job))
        .route("/api/jobs/{id}/cancel", post(api_cancel))
        .route("/api/jobs/{id}/retry", post(api_retry))
        .route("/api/jobs/{id}/log", get(api_log))
        .route("/api/jobs/{id}/events", get(api_events))
        .with_state(app)
}

/// Theme + icons copied from the wiki repo, embedded in the binary.
async fn asset(UrlPath(file): UrlPath<String>) -> Response {
    let (body, mime): (&'static [u8], &str) = match file.as_str() {
        "style.css" => (include_bytes!("../assets/style.css"), "text/css; charset=utf-8"),
        "icons/favicon.ico" => (include_bytes!("../assets/icons/favicon.ico"), "image/x-icon"),
        "icons/favicon.svg" => (include_bytes!("../assets/icons/favicon.svg"), "image/svg+xml"),
        "icons/icon-64.png" => (include_bytes!("../assets/icons/icon-64.png"), "image/png"),
        _ => return StatusCode::NOT_FOUND.into_response(),
    };
    ([(header::CONTENT_TYPE, mime), (header::CACHE_CONTROL, "max-age=300")], body).into_response()
}

/// Query string filters; empty form fields mean "any".
#[derive(Deserialize, Default)]
struct JobsQuery {
    status: Option<String>,
    project: Option<String>,
    limit: Option<usize>,
}

impl JobsQuery {
    fn filter(&self, app: &App) -> Result<JobFilter, Error> {
        let nonempty = |s: &Option<String>| s.clone().filter(|s| !s.is_empty());
        Ok(JobFilter {
            status: nonempty(&self.status).map(|s| db::parse(&s)).transpose().map_err(bad)?,
            project: nonempty(&self.project).map(|p| app.resolve(&p).map(|p| p.path).unwrap_or(p)),
            limit: self.limit,
        })
    }
}

async fn dashboard(State(app): St) -> Result<Html<String>, Error> {
    let projects = app.project_views(None).await?;
    app.render("dashboard.html", context! { projects => Serde(projects), crumbs => Vec::<(String, String)>::new(), nav => "dashboard" })
}

async fn project_page(State(app): St, UrlPath(path): UrlPath<String>) -> Result<Html<String>, Error> {
    let p = app.resolve(&path).map_err(|e| Error(StatusCode::NOT_FOUND, format!("{e:#}")))?;
    let view = app.project_views(Some(&p.path)).await?.pop();
    let builds = app.store.list(&JobFilter { project: Some(p.path.clone()), limit: Some(30), ..Default::default() })?;
    let crumbs = vec![(p.path.clone(), format!("/projects/{}", p.path))];
    let config = std::fs::read_to_string(p.dir.join("idlproj.yml")).unwrap_or_default();
    app.render("project.html", context! { project => Serde(view), builds => Serde(builds), crumbs, config })
}

async fn jobs_page(State(app): St, Query(q): Query<JobsQuery>) -> Result<Html<String>, Error> {
    let jobs = app.store.list(&q.filter(&app)?)?;
    let projects: Vec<String> = app.projects().iter().map(|p| p.path.clone()).collect();
    let crumbs = vec![("Build History".to_string(), "/jobs".to_string())];
    let statuses = ["queued", "running", "passed", "failed", "cancelled"];
    app.render(
        "jobs.html",
        context! { jobs => Serde(jobs), projects, statuses, crumbs, status => q.status, project => q.project, nav => "jobs" },
    )
}

async fn job_page(State(app): St, UrlPath(id): UrlPath<i64>) -> Result<Html<String>, Error> {
    let job = job_or_404(&app, id)?;
    let builds = app.store.list(&JobFilter { project: Some(job.project.clone()), limit: Some(30), ..Default::default() })?;
    let crumbs = vec![
        (job.project.clone(), format!("/projects/{}", job.project)),
        (format!("#{id}"), format!("/jobs/{id}")),
    ];
    let args = job.command.idl_args(job.configuration, job.strict, &job.targets).join(" ");
    app.render("job.html", context! { job => Serde(job), builds => Serde(builds), crumbs, args })
}

async fn console_text(State(app): St, UrlPath(id): UrlPath<i64>) -> Result<Response, Error> {
    let job = job_or_404(&app, id)?;
    let text = std::fs::read(&job.log).unwrap_or_default();
    Ok(([(header::CONTENT_TYPE, "text/plain; charset=utf-8")], text).into_response())
}

#[derive(Deserialize)]
struct SearchQuery {
    q: String,
}

async fn search(State(app): St, Query(SearchQuery { q }): Query<SearchQuery>) -> Redirect {
    let q = q.trim();
    if let Ok(id) = q.trim_start_matches('#').parse::<i64>() {
        return Redirect::to(&format!("/jobs/{id}"));
    }
    match app.resolve(q) {
        Ok(p) => Redirect::to(&format!("/projects/{}", p.path)),
        Err(_) => Redirect::to("/"),
    }
}

async fn health(State(app): St) -> Json<serde_json::Value> {
    Json(serde_json::json!({ "ok": true, "root": app.root, "version": env!("CARGO_PKG_VERSION") }))
}

async fn api_projects(State(app): St) -> Result<Json<Vec<ProjectView>>, Error> {
    Ok(Json(app.project_views(None).await?))
}

async fn api_project(State(app): St, UrlPath(path): UrlPath<String>) -> Result<Json<ProjectView>, Error> {
    let p = app.resolve(&path).map_err(|e| Error(StatusCode::NOT_FOUND, format!("{e:#}")))?;
    let view = app.project_views(Some(&p.path)).await?.pop().context("project vanished")?;
    Ok(Json(view))
}

async fn api_jobs(State(app): St, Query(q): Query<JobsQuery>) -> Result<Json<Vec<Job>>, Error> {
    Ok(Json(app.store.list(&q.filter(&app)?)?))
}

async fn api_enqueue(State(app): St, Json(new): Json<NewJob>) -> Result<Json<Enqueued>, Error> {
    Ok(Json(app.enqueue(new).await.map_err(bad)?))
}

async fn api_job(State(app): St, UrlPath(id): UrlPath<i64>) -> Result<Json<Job>, Error> {
    Ok(Json(job_or_404(&app, id)?))
}

async fn api_cancel(State(app): St, UrlPath(id): UrlPath<i64>) -> Result<Json<Job>, Error> {
    job_or_404(&app, id)?;
    app.runner.cancel(id).map_err(bad)?;
    Ok(Json(job_or_404(&app, id)?))
}

#[derive(Deserialize)]
struct ByQuery {
    by: Option<RequestedBy>,
}

async fn api_retry(
    State(app): St,
    UrlPath(id): UrlPath<i64>,
    Query(q): Query<ByQuery>,
) -> Result<Json<Enqueued>, Error> {
    let job = job_or_404(&app, id)?;
    let new = NewJob {
        project: job.project,
        command: job.command,
        targets: job.targets,
        configuration: job.configuration,
        strict: job.strict,
        requested_by: q.by.unwrap_or(job.requested_by),
        retry_of: Some(id),
    };
    Ok(Json(app.enqueue(new).await.map_err(bad)?))
}

#[derive(Deserialize)]
struct LogQuery {
    offset: Option<u64>,
    tail: Option<usize>,
}

#[derive(Serialize, Deserialize)]
pub struct LogChunk {
    pub id: i64,
    pub status: Status,
    pub size: u64,
    /// Offset to pass next time to continue.
    pub next_offset: u64,
    pub text: String,
}

/// Read up to `max` bytes of `path` from `offset`; returns (bytes, file size).
fn read_from(path: &Path, offset: u64, max: u64) -> (Vec<u8>, u64) {
    let Ok(mut f) = std::fs::File::open(path) else {
        return (Vec::new(), 0);
    };
    let size = f.metadata().map(|m| m.len()).unwrap_or(0);
    let mut buf = Vec::new();
    if offset < size && f.seek(SeekFrom::Start(offset)).is_ok() {
        let _ = f.take(max).read_to_end(&mut buf);
    }
    (buf, size)
}

async fn api_log(State(app): St, UrlPath(id): UrlPath<i64>, Query(q): Query<LogQuery>) -> Result<Json<LogChunk>, Error> {
    let job = job_or_404(&app, id)?;
    let (text, size, next) = if let Some(n) = q.tail {
        let (buf, size) = read_from(&job.log, 0, u64::MAX);
        let text = String::from_utf8_lossy(&buf);
        let lines: Vec<&str> = text.lines().collect();
        (lines[lines.len().saturating_sub(n)..].join("\n"), size, size)
    } else {
        let offset = q.offset.unwrap_or(0);
        let (buf, size) = read_from(&job.log, offset, 1 << 20);
        let next = offset + buf.len() as u64;
        (String::from_utf8_lossy(&buf).into_owned(), size, next.max(offset))
    };
    Ok(Json(LogChunk { id, status: job.status, size, next_offset: next, text }))
}

/// Live console: `log` events (JSON string chunks, id = byte offset, so reconnects resume),
/// `status` when it changes, and a final `done` with the job.
async fn api_events(
    State(app): St,
    UrlPath(id): UrlPath<i64>,
    headers: HeaderMap,
) -> Result<Sse<impl Stream<Item = Result<Event, Infallible>>>, Error> {
    job_or_404(&app, id)?;
    let mut offset: u64 = headers
        .get("last-event-id")
        .and_then(|v| v.to_str().ok()?.parse().ok())
        .unwrap_or(0);
    let stream = async_stream::stream! {
        let mut last_status = None;
        loop {
            let Ok(Some(job)) = app.store.get(id) else { break };
            if last_status != Some(job.status) {
                last_status = Some(job.status);
                yield Ok(Event::default().event("status").data(db::name(&job.status)));
            }
            let done = job.status.is_final();
            let (mut buf, _) = read_from(&job.log, offset, 256 << 10);
            if !done && let Some(nl) = buf.iter().rposition(|&b| b == b'\n') {
                buf.truncate(nl + 1); // whole lines only while the job writes
            }
            if !buf.is_empty() && (done || buf.ends_with(b"\n")) {
                offset += buf.len() as u64;
                let text = String::from_utf8_lossy(&buf).into_owned();
                if let Ok(ev) = Event::default().event("log").id(offset.to_string()).json_data(text) {
                    yield Ok(ev);
                }
                continue;
            }
            if done {
                let data = serde_json::to_string(&job).unwrap_or_default();
                yield Ok(Event::default().event("done").data(data));
                break;
            }
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
    };
    Ok(Sse::new(stream).keep_alive(KeepAlive::default()))
}

/// Run the server until SIGINT/SIGTERM, then kill running jobs.
pub async fn serve(root: PathBuf, addr: &str, jobs: usize, watch: Option<u64>) -> Result<()> {
    let store = Arc::new(Store::open(&root)?);
    let dir = store.dir.clone();
    let lock = std::fs::File::create(dir.join("serve.lock"))?;
    let _lock = nix::fcntl::Flock::lock(lock, nix::fcntl::FlockArg::LockExclusiveNonblock).map_err(|_| {
        let addr = std::fs::read_to_string(dir.join("serve.addr")).unwrap_or_default();
        anyhow::anyhow!("idlci serve is already running for {} (at {})", root.display(), addr.trim())
    })?;
    let runner = Runner::new(store.clone(), root.clone(), projects::idl_path(), jobs);
    runner.recover()?;
    let app = App::new(root.clone(), store, runner.clone(), watch.is_some());
    let listener = tokio::net::TcpListener::bind(addr).await.with_context(|| format!("binding {addr}"))?;
    let local = listener.local_addr()?;
    std::fs::write(dir.join("serve.addr"), local.to_string())?;
    eprintln!(
        "idlci: http://{local}  root {}  idl {}  executors {}{}",
        root.display(),
        runner.idl.display(),
        runner.executors,
        watch.map(|s| format!("  watching every {s}s")).unwrap_or_default()
    );
    runner.start();
    if let Some(secs) = watch {
        tokio::spawn(crate::watch::run(app.clone(), Duration::from_secs(secs)));
    }
    let shutdown = async {
        let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
        tokio::select! {
            _ = term.recv() => {}
            _ = tokio::signal::ctrl_c() => {}
        }
        anyhow::Ok(())
    };
    tokio::select! {
        r = axum::serve(listener, router(app)) => r?,
        r = shutdown => r?,
    }
    eprintln!("idlci: shutting down");
    runner.shutdown().await;
    let _ = std::fs::remove_file(dir.join("serve.addr"));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every page renders (catches template errors such as missing filters).
    #[tokio::test]
    async fn pages_render() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().to_path_buf();
        std::fs::create_dir_all(root.join("group/app-ios")).unwrap();
        std::fs::write(root.join("group/app-ios/idlproj.yml"), "name: App\n").unwrap();
        let store = Arc::new(Store::open(&root).unwrap());
        let runner = Runner::new(store.clone(), root.clone(), "/bin/false".into(), 2);
        let app = App::new(root, store.clone(), runner, true);
        let new = NewJob { project: "app-ios".into(), command: Command::Build, ..Default::default() };
        let job = app.enqueue(new.clone()).await.unwrap().job;
        assert_eq!(job.project, "group/app-ios");
        store.claim_next().unwrap();
        store.finish(job.id, Status::Failed, Some(1)).unwrap();
        app.enqueue(NewJob { command: Command::Test, ..new }).await.unwrap();

        let page = |r: Result<Html<String>, Error>| r.map(|h| h.0).map_err(|e| e.1).unwrap();
        let st = || State(app.clone());
        assert!(page(dashboard(st()).await).contains("app-ios"));
        assert!(page(project_page(st(), UrlPath("group/app-ios".into())).await).contains("Build with Parameters"));
        assert!(page(jobs_page(st(), Query(JobsQuery::default())).await).contains(&format!("#{}", job.id)));
        let html = page(job_page(st(), UrlPath(job.id)).await);
        assert!(html.contains(&format!("Build #{}", job.id)) && html.contains("Console Output"));
    }
}
