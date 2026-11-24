//! idl projects in the workspace: discovery, `idl list` targets, git state.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use serde::Serialize;

use crate::db::GitInfo;

#[derive(Clone, Debug, Serialize)]
pub struct Project {
    /// Path relative to the workspace root ("." for the root itself).
    pub path: String,
    #[serde(skip)]
    pub dir: PathBuf,
}

const SKIP: &[&str] = &["target", "node_modules", "build", "DerivedData", "Pods"];

/// Every directory holding an `idlproj.yml`, up to 5 levels below the root.
pub fn discover(root: &Path) -> Vec<Project> {
    let walk = walkdir::WalkDir::new(root).max_depth(5).sort_by_file_name();
    let mut out: Vec<Project> = walk
        .into_iter()
        .filter_entry(|e| {
            let name = e.file_name().to_string_lossy();
            e.depth() == 0 || !(e.file_type().is_dir() && (name.starts_with('.') || SKIP.contains(&&*name)))
        })
        .filter_map(Result::ok)
        .filter(|e| e.file_type().is_file() && e.file_name() == "idlproj.yml")
        .filter_map(|e| {
            let dir = e.path().parent()?.to_path_buf();
            let rel = dir.strip_prefix(root).ok()?.to_string_lossy().into_owned();
            Some(Project { path: if rel.is_empty() { ".".into() } else { rel }, dir })
        })
        .collect();
    out.sort_by(|a, b| a.path.cmp(&b.path));
    out
}

/// Find a project by relative path, pull repo name, or unique last path segment.
pub fn resolve<'a>(root: &Path, projects: &'a [Project], arg: &str) -> Result<&'a Project> {
    let arg = arg.trim_end_matches('/');
    if let Some(p) = projects.iter().find(|p| p.path == arg) {
        return Ok(p);
    }
    // Pull repo name: the project at the repo root, or the repo's only project.
    let in_repo: Vec<_> = projects.iter().filter(|p| repo_name(root, &p.dir).as_deref() == Some(arg)).collect();
    if let Some(p) = in_repo.iter().find(|p| p.dir == root.join(arg)).or(in_repo.first().filter(|_| in_repo.len() == 1)) {
        return Ok(p);
    }
    let by_name: Vec<_> = projects.iter().filter(|p| p.path.rsplit('/').next() == Some(arg)).collect();
    match by_name[..] {
        [p] => Ok(p),
        _ => bail!(
            "unknown project {arg:?}; projects: {}",
            projects.iter().map(|p| p.path.as_str()).collect::<Vec<_>>().join(", ")
        ),
    }
}

#[derive(Clone, Debug, Serialize, serde::Deserialize)]
pub struct Target {
    pub name: String,
    pub kind: String,
    pub builder: String,
    pub bundle_id: Option<String>,
    pub platform: String,
    pub dir: String,
}

const KINDS: &[&str] = &["app", "framework", "dylib", "appex", "static", "test"];

/// Parse `idl list`: `NAME KIND BUILDER [BUNDLE_ID] PLATFORM VERSION DIR` per line.
pub fn parse_list(text: &str) -> Vec<Target> {
    text.lines()
        .filter_map(|line| {
            let t: Vec<&str> = line.split_whitespace().collect();
            let n = t.len();
            if n < 6 || !KINDS.contains(&t[1]) {
                return None;
            }
            Some(Target {
                name: t[0].into(),
                kind: t[1].into(),
                builder: t[2].into(),
                bundle_id: (n > 6).then(|| t[3..n - 3].join(" ")),
                platform: format!("{} {}", t[n - 3], t[n - 2]),
                dir: t[n - 1].into(),
            })
        })
        .collect()
}

pub async fn targets(idl: &Path, dir: &Path) -> Result<Vec<Target>> {
    let out = tokio::process::Command::new(idl)
        .arg("list")
        .current_dir(dir)
        .stdin(std::process::Stdio::null())
        .output()
        .await
        .with_context(|| format!("running {} list", idl.display()))?;
    if !out.status.success() {
        bail!("idl list failed: {}", String::from_utf8_lossy(&out.stderr).trim());
    }
    Ok(parse_list(&String::from_utf8_lossy(&out.stdout)))
}

/// The `idl` binary: $IDLCI_IDL, else `idl` on PATH, else ~/.local/bin/idl.
pub fn idl_path() -> PathBuf {
    if let Some(p) = std::env::var_os("IDLCI_IDL") {
        return p.into();
    }
    let on_path = std::env::var_os("PATH")
        .into_iter()
        .flat_map(|p| std::env::split_paths(&p).collect::<Vec<_>>())
        .map(|d| d.join("idl"))
        .find(|p| p.is_file());
    on_path.unwrap_or_else(|| {
        let local = std::env::home_dir().unwrap_or_default().join(".local/bin/idl");
        if local.is_file() { local } else { "idl".into() }
    })
}

fn repo_name(root: &Path, dir: &Path) -> Option<String> {
    let repo = git2::Repository::discover(dir).ok()?;
    let rel = repo.workdir()?.strip_prefix(root).ok()?.to_string_lossy().trim_end_matches('/').to_string();
    (!rel.is_empty()).then_some(rel)
}

/// Repo name (relative to the root), branch, short HEAD and dirty flag.
pub fn git_info(root: &Path, dir: &Path) -> GitInfo {
    let Ok(repo) = git2::Repository::discover(dir) else {
        return GitInfo::default();
    };
    let head = repo.head().ok();
    let mut opts = git2::StatusOptions::new();
    opts.include_untracked(true).include_ignored(false).exclude_submodules(true);
    GitInfo {
        repo: repo_name(root, dir),
        branch: head.as_ref().and_then(|h| h.shorthand().ok().map(str::to_string)),
        head: head
            .as_ref()
            .and_then(|h| h.peel_to_commit().ok())
            .and_then(|c| c.as_object().short_id().ok())
            .and_then(|b| b.as_str().ok().map(str::to_string)),
        dirty: repo.statuses(Some(&mut opts)).map(|s| !s.is_empty()).unwrap_or(false),
    }
}

/// HEAD oid of the repo containing `dir` (for the watcher).
pub fn head_oid(dir: &Path) -> Option<(PathBuf, git2::Oid)> {
    let repo = git2::Repository::discover(dir).ok()?;
    let oid = repo.head().ok()?.target()?;
    Some((repo.workdir()?.to_path_buf(), oid))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_idl_list() {
        let text = "FossifyCalculator        app       direct  org.fossify.math.ios                 iOS 17.0   .\n\
                    CalculatorKit            static    direct                                       iOS 17.0   .\n\
                    FossifyCommons           static    direct                                       iOS 17.0   ../commons-ios\n\
                    warning: something\n";
        let t = parse_list(text);
        assert_eq!(t.len(), 3);
        assert_eq!(t[0].bundle_id.as_deref(), Some("org.fossify.math.ios"));
        assert_eq!(t[1].bundle_id, None);
        assert_eq!(t[1].platform, "iOS 17.0");
        assert_eq!(t[2].dir, "../commons-ios");
    }

    #[test]
    fn discovers_and_resolves() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        for d in ["group/a-ios", "b", "b/target/x", ".hidden/c"] {
            std::fs::create_dir_all(root.join(d)).unwrap();
            std::fs::write(root.join(d).join("idlproj.yml"), "").unwrap();
        }
        let p = discover(root);
        assert_eq!(p.iter().map(|p| p.path.as_str()).collect::<Vec<_>>(), ["b", "group/a-ios"]);
        assert_eq!(resolve(root, &p, "a-ios").unwrap().path, "group/a-ios");
        assert_eq!(resolve(root, &p, "group/a-ios/").unwrap().path, "group/a-ios");
        assert!(resolve(root, &p, "nope").is_err());
    }
}
