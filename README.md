# idlci

Local CI for the [idl](https://github.com/jbisfun/idl) projects of a [pull](https://github.com/jbisfun/pull)
workspace: a SQLite job queue running `idl build|test|lint|fmt --check|check|clean`, Jenkins-style pages
on the workspace's shared theme ([jbisfun/theme](https://github.com/jbisfun/theme)), a JSON API, git HEAD
watching, patch and stack runs for [cpull](https://github.com/jbisfun/cpull), and an MCP server for agents.
Written in Zig 0.17.1.

```sh
idlci serve [--listen 127.0.0.1:8737] [--jobs 1] [--watch [--watch-interval 15]] [--work-days 7]
idlci mcp                                    # stdio MCP server (ci_* tools)
idlci queue fossify-ios/calculator-ios build [TARGET...] [-c release] [--strict] [--wait]
idlci jobs [--status failed] [--project calculator-ios] [--limit 20]
idlci log 12 [-f]
idlci cancel 12 / idlci retry 12
idlci patch REPO PATCH [-w] / idlci stack STACK [-w]   # resolved through cpull's API
idlci cleanup [--days 7] [--dry-run]         # remove idle patch/stack work trees
```

The root is `--root`, else `$PULL_ROOT`, else the nearest parent holding `pullfile.plist`. State lives in
`$ROOT/.pull/idlci/`: `idlci.db`, `logs/<id>.log`, `work/<subject>/` (patch/stack work trees) and
`serve.addr`/`serve.lock`. Clients find the server through `--addr`, `$IDLCI_ADDR`, `serve.addr`, then
127.0.0.1:8737. Jobs run `idl` (`$IDLCI_IDL`, else `idl` on PATH) from the project directory. On start,
`idlci serve` adopts cpull's `.pull/cpull/ci/ci.db` (with its logs and work trees) when that is newer
than `idlci.db`, keeping the older one as `idlci.db.bak`.

Run it as a pullfile job (`idlci serve --listen 127.0.0.1:8737`) and register `idlci mcp` under
`mcp_servers`; the MCP tools start the job through `pull launchctl start idlci` when it isn't running.
The API (`/api/projects`, `/api/jobs`, `/api/runs`, `/api/status/...`, `/api/feed`) is specified in the
theme package's `docs/workspace-tools.md`.

Build with `~/jbisfun/theme` checked out beside this repo: `zig build -Doptimize=ReleaseSafe --prefix ~/.local`;
test with `zig build test`.
