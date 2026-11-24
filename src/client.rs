//! HTTP client for a running `idlci serve` (MCP server and CLI), starting one if needed.

use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{Context, Result, bail};
use serde::{Serialize, de::DeserializeOwned};

use crate::db::data_dir;

pub const DEFAULT_ADDR: &str = "127.0.0.1:8737";

pub struct Client {
    http: reqwest::Client,
    base: String,
}

impl Client {
    /// Connect to the server for `root` (address: `addr`, else `.pull/idlci/serve.addr`, else
    /// the default); with `autostart`, spawn a detached `idlci serve` when none answers.
    pub async fn connect(root: &Path, addr: Option<&str>, autostart: bool) -> Result<Self> {
        let http = reqwest::Client::builder().connect_timeout(Duration::from_secs(2)).build()?;
        let addr_file = data_dir(root).join("serve.addr");
        let current = || {
            addr.map(str::to_string)
                .or_else(|| std::fs::read_to_string(&addr_file).ok().map(|s| s.trim().to_string()))
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| DEFAULT_ADDR.into())
        };
        if let Some(c) = Self::probe(&http, &current(), root).await? {
            return Ok(c);
        }
        if !autostart {
            bail!("idlci serve is not running for {} (start it with `idlci serve`)", root.display());
        }
        let log = spawn_server(root, addr)?;
        for _ in 0..80 {
            tokio::time::sleep(Duration::from_millis(250)).await;
            if let Some(c) = Self::probe(&http, &current(), root).await? {
                return Ok(c);
            }
        }
        bail!("started idlci serve but it did not answer; see {}", log.display())
    }

    /// `Some` if a server for this root answers at `addr`; error if it serves another root.
    async fn probe(http: &reqwest::Client, addr: &str, root: &Path) -> Result<Option<Self>> {
        let base = format!("http://{addr}");
        let Ok(resp) = http.get(format!("{base}/api/health")).timeout(Duration::from_secs(3)).send().await else {
            return Ok(None);
        };
        let health: serde_json::Value = resp.json().await.unwrap_or_default();
        match health["root"].as_str() {
            Some(r) if Path::new(r) == root => Ok(Some(Self { http: http.clone(), base })),
            Some(r) => bail!("{addr} is an idlci server for {r}, not {}; pass --addr", root.display()),
            None => bail!("{addr} answers but isn't idlci; pass --addr"),
        }
    }

    pub async fn get<T: DeserializeOwned>(&self, path: &str) -> Result<T> {
        self.get_query(path, &[]).await
    }

    pub async fn get_query<T: DeserializeOwned>(&self, path: &str, query: &[(&str, String)]) -> Result<T> {
        decode(self.http.get(format!("{}{path}", self.base)).query(query).send().await?).await
    }

    pub async fn post<T: DeserializeOwned>(&self, path: &str, body: &impl Serialize) -> Result<T> {
        decode(self.http.post(format!("{}{path}", self.base)).json(body).send().await?).await
    }
}

async fn decode<T: DeserializeOwned>(resp: reqwest::Response) -> Result<T> {
    let status = resp.status();
    let v: serde_json::Value = resp.json().await.context("decoding response")?;
    if !status.is_success() {
        bail!("{}", v["error"].as_str().unwrap_or(status.as_str()));
    }
    Ok(serde_json::from_value(v)?)
}

/// `idlci serve --root ROOT` in its own session, logging to `.pull/idlci/serve.log`.
fn spawn_server(root: &Path, addr: Option<&str>) -> Result<PathBuf> {
    let dir = data_dir(root);
    std::fs::create_dir_all(&dir)?;
    let log_path = dir.join("serve.log");
    let log = std::fs::OpenOptions::new().create(true).append(true).open(&log_path)?;
    let mut cmd = std::process::Command::new(std::env::current_exe()?);
    cmd.arg("serve").arg("--root").arg(root);
    if let Some(a) = addr {
        cmd.arg("--addr").arg(a);
    }
    cmd.stdin(std::process::Stdio::null()).stdout(log.try_clone()?).stderr(log);
    // SAFETY: setsid is async-signal-safe; it detaches the server from our session.
    unsafe {
        cmd.pre_exec(|| nix::unistd::setsid().map(drop).map_err(std::io::Error::from));
    }
    cmd.spawn().context("starting idlci serve")?;
    Ok(log_path)
}
