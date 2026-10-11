# Docker Build Smoke Test Fixtures

Five minimal synthetic application fixtures for Docker build validation.
No external runtime dependencies; pure stdlib implementations.

## Structure

- `node/` — Node.js 20+ with npm (no external deps, lockfile v3)
  - `package.json`, `package-lock.json`, `server.js`
  - Health: POST `/healthz` → 200 on port 3000

- `python/` — Python 3.12 with Flask + Gunicorn
  - `requirements.txt` (pinned), `app.py` 
  - Health: GET `/healthz` → 200 on port 8000

- `go/` — Go 1.23 stdlib
  - `go.mod`, `go.sum` (empty), `main.go`
  - Health: GET `/healthz` → JSON on port 8080

- `rust/` — Rust 1.81+ stdlib (no Tokio/Hyper)
  - `Cargo.toml`, `Cargo.lock`, `src/main.rs`
  - Health: GET `/healthz` → JSON on port 8000

- `java/` — Java 17 stdlib (com.sun.net.httpserver only)
  - `pom.xml` (metadata), `src/main/java/com/fixture/App.java`, `mvnw` (synthetic wrapper)
  - Health: GET `/actuator/health` → JSON on port 8080

## Build Command Format

Each fixture responds to:
```
docker build -f <Dockerfile> -t fixture:lang .
docker run --rm -p PORT:PORT fixture:lang
curl http://localhost:PORT/<health-path>
```

**No Docker commands or network calls in tests.** Dockerfile syntax validated offline;
health paths and ports are compile-time contract.
