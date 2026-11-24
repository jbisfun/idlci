# idlci

Local CI for the [idl](https://github.com/jbisfun/idl) projects of a [pull](https://github.com/jbisfun/pull)
workspace: a SQLite-backed job queue running `idl build|test|lint|fmt --check|check|clean`, a
Jenkins-style web UI, a JSON API, git HEAD watching, and an MCP server for agents.

```sh
idlci serve [--root DIR] [--addr 127.0.0.1:8737] [--jobs 1] [--watch]   # UI at http://127.0.0.1:8737
idlci mcp                                    # stdio MCP server; starts `idlci serve` when needed
idlci queue fossify-ios/calculator-ios build [TARGET...] [-c release] [--strict] [--wait]
idlci jobs [--status failed] [--project calculator-ios]
idlci log 12 [-f]
idlci cancel 12 / idlci retry 12
```

The root is `--root`, else `$PULL_ROOT`, else the nearest parent holding `pullfile.plist`. State lives
in `$ROOT/.pull/idlci/` (`idlci.db`, `logs/<id>.log`, `serve.addr`, `serve.log`). Jobs run `idl` from
the project directory with the server's environment.

API: `GET /api/projects[/{path}]`, `GET|POST /api/jobs`, `GET /api/jobs/{id}`,
`POST /api/jobs/{id}/cancel|retry`, `GET /api/jobs/{id}/log?offset=|tail=`, `GET /api/jobs/{id}/events` (SSE).
MCP tools: `projects`, `queue`, `jobs`, `job`, `log`, `wait`, `cancel`, `retry`.
