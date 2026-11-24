//! `serve --watch`: poll the repos of every project (and of its targets' dirs) and queue
//! `build` then `test` when a HEAD moves.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use crate::db::{Command, NewJob, RequestedBy};
use crate::projects::head_oid;
use crate::web::App;

pub async fn run(app: Arc<App>, every: Duration) {
    let mut seen: HashMap<String, Vec<(PathBuf, git2::Oid)>> = HashMap::new();
    loop {
        for p in app.projects().iter() {
            let mut dirs = vec![p.dir.clone()];
            if let Ok(targets) = app.targets(p).await {
                dirs.extend(targets.iter().map(|t| p.dir.join(&t.dir)));
            }
            let mut heads: Vec<_> = dirs.iter().filter_map(|d| head_oid(d)).collect();
            heads.sort();
            heads.dedup();
            let changed = seen.insert(p.path.clone(), heads.clone()).is_some_and(|old| old != heads);
            if !changed {
                continue;
            }
            for command in [Command::Build, Command::Test] {
                let new = NewJob {
                    project: p.path.clone(),
                    command,
                    requested_by: RequestedBy::Watch,
                    ..Default::default()
                };
                match app.enqueue(new).await {
                    Ok(e) if !e.deduplicated => eprintln!("idlci: watch: {} moved, queued #{}", p.path, e.job.id),
                    Ok(_) => {}
                    Err(e) => eprintln!("idlci: watch: {}: {e:#}", p.path),
                }
            }
        }
        tokio::time::sleep(every).await;
    }
}
