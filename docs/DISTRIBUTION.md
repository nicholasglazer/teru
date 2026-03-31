# teru Distribution Plan

## Linux

### Arch Linux (AUR)
- Package name: `teru` (available, checked 2026-03-30)
- PKGBUILD: standard zig build, depends on zig, glibc
- Also: `teru-git` for latest main branch
- Submit: https://aur.archlinux.org/submit

### Nix
- Add to nixpkgs: `pkgs/by-name/te/teru/package.nix`
- Zig build support in nixpkgs via `zig.hook`
- PR to https://github.com/NixOS/nixpkgs

### Homebrew (Linux + macOS)
- Formula at: homebrew-tap repo or homebrew-core PR
- `brew tap nicholasglazer/homebrew-tap && brew install teru`
- Zig build, depends on zig

### Fedora/RHEL (COPR)
- COPR repo for RPM packaging
- Spec file with zig build

### Debian/Ubuntu (PPA)
- Launchpad PPA or direct .deb packages
- debian/ directory with rules using zig build

### Flatpak
- Not ideal for terminal emulators (sandbox conflicts with PTY)
- Skip unless demand

### AppImage
- Portable, self-contained
- Build with linuxdeploy

## macOS

### Homebrew (primary)
- Same formula as Linux, zig cross-compiles
- `brew install teru`

### MacPorts
- Portfile submission
- Lower priority than Homebrew

### DMG / .app bundle
- For non-package-manager users
- Requires Swift GUI shell (macOS platform shell)
- Code-signed + notarized for Gatekeeper

## Windows (v2)

### winget
- Package name: `nicholasglazer.teru` (available, checked 2026-03-30)
- Manifest YAML in winget-pkgs repo
- PR to https://github.com/microsoft/winget-pkgs

### Chocolatey
- Package name: `teru` (available, checked 2026-03-30)
- nuspec + chocolateyInstall.ps1

### Scoop
- JSON manifest in a bucket
- `scoop bucket add miozu https://github.com/nicholasglazer/scoop-bucket`
- `scoop install teru`

### MSIX / Microsoft Store
- Modern Windows packaging
- Lower priority

## Source

### GitHub Releases
- Automated via CI
- Artifacts: teru-linux-x86_64, teru-linux-aarch64, teru-macos-x86_64, teru-macos-aarch64
- .tar.gz with binary + terminfo + LICENSE

### Codeberg Mirror
- Mirror releases to Codeberg for non-GitHub users

## Priority Order
1. AUR (user's primary OS)
2. Homebrew (cross-platform, easy)
3. Nix (growing community)
4. GitHub Releases (universal fallback)
5. winget + Chocolatey + Scoop (Windows, v2)
6. Everything else (on demand)
