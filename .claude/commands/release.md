# teru Release Pipeline

Automate the full release: test, bump, changelog, commit, tag, push, monitor CI, verify binaries.

## Version

$ARGUMENTS

## Protocol

Execute all phases in order. Stop and report if any phase fails.

### Phase 1: Pre-flight

1. Run `zig build test 2>&1 | tail -5` — must pass (480+ tests)
2. Run `zig build 2>&1 | tail -5` — must compile
3. Run `git status` — warn about uncommitted changes but don't block
4. Run `git log --oneline -1` — confirm we're on main
5. Check no existing tag: `git tag -l v$ARGUMENTS`
6. If any test/build fails, STOP and report

### Phase 2: Version bump

1. Run `make bump-version V=$ARGUMENTS`
2. Verify: `grep 'const version' build.zig | head -1` should show the new version

### Phase 3: Changelog

1. Find the previous release tag: `git describe --tags --abbrev=0`
2. Read commits since that tag: `git log --oneline <prev-tag>..HEAD`
3. Read the top of `CHANGELOG.md`
4. Add a new section at the top: `## $ARGUMENTS (YYYY-MM-DD)` with today's date
5. Categorize commits into:
   - **Features** — new functionality
   - **Fixes** — bug fixes
   - **Build/CI** — build system, CI, dependency changes
   - **Documentation** — docs, README, comments
6. Write concise bullet points (not raw commit messages)

### Phase 4: Commit, tag, push

1. Stage: `git add build.zig build.zig.zon CHANGELOG.md`
2. Also stage any other files modified as part of the release prep
3. Commit: `git commit -m "release: v$ARGUMENTS"`
4. Tag: `git tag v$ARGUMENTS`
5. Push: `git push && git push origin v$ARGUMENTS`

### Phase 5: Monitor CI

1. Find the Release workflow: `gh run list --limit 3`
2. Get the run ID for the Release workflow
3. Poll status: `gh run view <id> --json status,conclusion,jobs --jq '{status: .status, conclusion: .conclusion, jobs: [.jobs[] | {name: .name, conclusion: .conclusion}]}'`
4. Wait for completion (check every 30s, max 10 minutes)
5. On **success**:
   - Verify assets: `gh release view v$ARGUMENTS --json assets --jq '.assets[].name'`
   - Expected binaries: linux-x86_64, linux-x86_64-x11, linux-x86_64-wayland, windows-x86_64, macos-aarch64
   - Report: "v$ARGUMENTS released with N binaries"
6. On **failure**:
   - Show logs: `gh run view <id> --log-failed | tail -40`
   - Diagnose the failure
   - If fixable: fix, delete tag (`git tag -d v$ARGUMENTS && git push origin :refs/tags/v$ARGUMENTS`), re-commit, re-tag, re-push
   - If not fixable: report and stop

### Phase 6: Verify

1. `gh release view v$ARGUMENTS` — show the release page summary
2. Report the release URL: `https://github.com/nicholasglazer/teru/releases/tag/v$ARGUMENTS`
3. Check AUR workflow: `gh run list --workflow=aur.yml --limit 1`

## Key Files

- Version source of truth: `build.zig` line 10
- Changelog: `CHANGELOG.md`
- Release CI: `.github/workflows/release.yml`
- AUR CI: `.github/workflows/aur.yml`
- Bump script: `make bump-version V=x.y.z`

## Binary Targets

| Asset | Source |
|-------|--------|
| `teru-linux-x86_64.tar.gz` | Ubuntu runner, native |
| `teru-linux-x86_64-x11.tar.gz` | Ubuntu, `-Dwayland=false` |
| `teru-linux-x86_64-wayland.tar.gz` | Ubuntu, `-Dx11=false` |
| `teru-windows-x86_64.zip` | Ubuntu, cross-compile `-Dtarget=x86_64-windows-gnu` |
| `teru-macos-aarch64.tar.gz` | macOS 15 runner, native |
