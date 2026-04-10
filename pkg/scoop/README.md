# Scoop Package

teru is distributed via a Scoop bucket for Windows users.

## Install

```powershell
scoop bucket add teru https://github.com/nicholasglazer/scoop-teru
scoop install teru
```

## Update

```powershell
scoop update teru
```

## Bucket Setup

The bucket repo is [nicholasglazer/scoop-teru](https://github.com/nicholasglazer/scoop-teru).

Created from [ScoopInstaller/BucketTemplate](https://github.com/ScoopInstaller/BucketTemplate):

1. Use the template to create `nicholasglazer/scoop-teru`
2. Copy `teru.json` to `bucket/teru.json`
3. Replace `TODO_SHA256_HASH` with the actual hash: `(Get-FileHash teru-windows-x86_64.zip).Hash`
4. Add `scoop-bucket` topic to the repo for indexing at https://scoop.sh
5. Enable GitHub Actions (read+write permissions) for Excavator auto-updates

Excavator runs every 4 hours and auto-updates the manifest when a new GitHub Release is published.

## Releasing

On each teru release:
1. Tag `vX.Y.Z` and create GitHub Release with `teru-windows-x86_64.zip`
2. Excavator auto-detects the new version within 4 hours
3. Downloads the zip, computes SHA256, updates `bucket/teru.json`, commits

No manual manifest updates needed.
