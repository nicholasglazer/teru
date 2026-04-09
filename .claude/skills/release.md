---
name: release
description: Ship a new teru version — bump, changelog, test, tag, push, monitor CI. Use when releasing a new version (e.g., `/release 0.3.9`).
---

# teru Release Skill

Automates the full release pipeline. Argument is the version number (e.g., `0.3.9`).

## Steps

When invoked with `/release <version>`:

1. **Pre-flight checks**
   - Run `zig build test` — all tests must pass
   - Run `zig build` — binary must compile
   - Check `git status` — warn if uncommitted changes exist (don't block)
   - Check `git log --oneline main..HEAD` — ensure we're on main with no unpushed divergence

2. **Version bump**
   - Run `make bump-version V=<version>` (updates build.zig + build.zig.zon)
   - Verify the version was set: `grep 'const version' build.zig`

3. **Changelog**
   - Read `CHANGELOG.md`
   - Read `git log --oneline` since the last tag to summarize changes
   - Add a new `## <version> (<date>)` section at the top of CHANGELOG.md
   - Categorize changes into: Features, Fixes, Build/CI, Documentation

4. **Commit and tag**
   - `git add build.zig build.zig.zon CHANGELOG.md`
   - `git commit -m "release: v<version>"`
   - `git tag v<version>`

5. **Push and deploy**
   - `git push && git push origin v<version>`
   - This triggers `.github/workflows/release.yml` which builds:
     - `teru-linux-x86_64.tar.gz`
     - `teru-linux-x86_64-x11.tar.gz`
     - `teru-linux-x86_64-wayland.tar.gz`
     - `teru-windows-x86_64.zip`
     - `teru-macos-aarch64.tar.gz`

6. **Monitor CI**
   - `gh run list --limit 3` to find the Release workflow run
   - `gh run view <id> --json status,conclusion,jobs` to check progress
   - Wait for completion, report result
   - On success: `gh release view v<version> --json assets --jq '.assets[].name'` to confirm binaries
   - On failure: show `gh run view <id> --log-failed | tail -30` and diagnose

## Important

- Single source of truth for version: `build.zig` line 10
- Release workflow: `.github/workflows/release.yml`
- macOS builds run on `macos-15` (aarch64 only, Intel Macs are EOL)
- Windows is cross-compiled from Ubuntu
- Never skip tests before releasing
- If CI fails, fix the issue, delete the tag (`git tag -d v<version> && git push origin :refs/tags/v<version> && git push codeberg :refs/tags/v<version>`), re-tag, and re-push
- Always push to both remotes: `origin` (GitHub) and `codeberg`
