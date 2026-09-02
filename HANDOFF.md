# Handoff: `gfisystem/downloads` release pipeline

**Written:** 2026-08-04. **Partially updated:** 2026-08-21 and 2026-09-02 (§3.2, §3.4, §5, §7.5, §10 only — see those dated entries).
**Repo:** `gfisystem/downloads` (GitHub, **public**, remote `https://github.com/gfisystem/downloads.git`, branch `main`)
**Scope of this doc:** everything relevant to how download links / GitHub Releases get generated in this repo — what exists, what changed recently, what was deliberately left alone, and what's still open.

**Staleness warning:** only the sections listed above were touched on those dates. Commits land on `main` regularly (new firmware/editor versions, etc.) between updates to this doc — the directory map (§2), file/tag counts (§8), and anything not in the dated list were **not** re-verified at each pass and may no longer be accurate. Re-derive from the repo/GitHub API rather than trusting those sections as current.

**[2026-09-02] If you take one thing from this doc: verify, don't trust, anything this doc or a prior agent says is "fixed."** §7.5 below is a real example of a fix that was confirmed working, then silently caused active data loss for 6+ days before anyone noticed — because nobody re-checked it against live GitHub state after the fact. Live-verify against `gh api` / `gh release view`, not against what a previous run's log or an agent's summary claimed.

Read this whole document before touching `.github/workflows/create-releases.yml` or running/triggering it. Several things in here look like bugs at first glance but are confirmed, intentional decisions the user made explicitly — see "Deliberate decisions" below before "fixing" anything.

---

## 1. What this repo actually is

`gfisystem/downloads` has no application code. It's pure static-asset storage: firmware files, editor installers, PDF manuals, drivers, and (as of today) artist preset bundles get pushed into specific folders on `main`. A GitHub Actions workflow turns those folders into **GitHub Releases**, and each release asset's `browser_download_url` is a public download link. Those links are presumably consumed by an external gfisystem-facing website/app that is **not** in this repo — nothing here renders a UI, this repo only produces URLs.

Because the repo is **public**, every release asset URL is unauthenticated and world-downloadable by anyone who has or guesses it. There is no auth layer in front of any of this. Keep that in mind for everything below — it's the reason several sections of this doc exist.

---

## 2. Full directory map (current, as of this commit)

```
.
├── .github/workflows/create-releases.yml   ← the release-publishing workflow (see §3)
├── .gitignore                              ← contains just ".DS_Store"
├── generate-download-links.sh              ← companion script, see §4
├── generated-download-links.txt            ← output of that script, 204 lines / 118 unique release tags currently
├── CDM-v2.12.36.4-for-ARM64.zip            ← root-level driver (published as a release asset)
├── CDM2123620_SpecLab_Win11_Driver.zip     ← root-level driver (published as a release asset)
│
├── solis-ventus-firmwares/                 ← + firmware-update-history/, newest/
├── duophony-firmwares/                     ← + firmware-update-history/
├── enieqma-firmwares/                      ← + firmware-update-history/, newest/
├── cabzeus-firmwares/
├── synesthesia-firmwares/                  ← + firmware-software-patch-bundle/
├── specular-tempus-firmwares/
│
├── editors/
│   ├── cabslab/            (CabsLab 2.0.8/)
│   ├── duophony/           (DFU 1.0.1/)
│   ├── enieqlab/           (EnieqLab 1.1.0/, EnieqLab 1.2.0/)
│   ├── speclab/            (SpecLab 3.4.3/, 3.4.7/, 3.4.8/, 3.4.9/)
│   ├── sv-studio/          (SV Studio 1.1.0/ … 1.6.5/, 17 version folders)
│   └── symmlab/            (SymmLab 2.5.2/, patch/)
│
├── manuals/
│   ├── cabzeus/, cabzeus-mono/, duophony/, enieqma/, jonassus/,
│   │   orca/, rossie/, skylar/, solis-ventus/, specular-tempus/, synesthesia/
│   └── (11 product folders total — every one gets its own release, see §3.6)
│
├── artist-series-presets/                  ← NEW today, see §6
│   ├── artist-bundle-november-drops.bkp            (plaintext preset bundle)
│   └── artist-bundle-november-drops.bkp.enc.bkp    (encrypted version, added same day)
│
├── versions-reference/                     ← NEW today, see §6
│   ├── gfisystem-ver-ref.txt               (harmless version-number reference)
│   └── artist-preset-entitlements.txt      (serial → preset entitlement map — SENSITIVE, see §7.2)
│
└── temporary-firmwares/
    └── temp-fw.fdt                         ← NOT wired into the workflow at all — see §8.3
```

---

## 3. The workflow: `.github/workflows/create-releases.yml`

Single job (`release`, `ubuntu-latest`), single `run:` step that's one long bash script. No build step — it just discovers files with `find` and calls `gh release`.

### 3.1 Triggers

```yaml
on:
  push:
    branches:
      - main
    paths:
      - 'solis-ventus-firmwares/**'
      - 'duophony-firmwares/**'
      - 'enieqma-firmwares/**'
      - 'cabzeus-firmwares/**'
      - 'synesthesia-firmwares/**'
      - 'specular-tempus-firmwares/**'
      - 'editors/**'
      - 'manuals/**'
      - 'artist-series-presets/**'
      - 'versions-reference/**'
      - '*.zip'
      - '*.exe'
  workflow_dispatch:
```

**Important nuance:** a push only auto-triggers this workflow if the push touches a file matching one of these `paths:` globs. Editing the workflow file itself does **not** trigger it (`.github/workflows/**` isn't listed). `temporary-firmwares/**` is also not listed (see §8.3). `workflow_dispatch` (manual "Run workflow" button, or `gh workflow run`) has no path restriction — it always runs the full script against whatever's currently on the target branch.

### 3.2 Helpers

```bash
slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -d '()' | tr -s '-'
}

upload_to_release() {
  local tag="$1"; local title="$2"; local notes="$3"; shift 3
  local files=("$@")
  gh release upload "$tag" "${files[@]}" --repo "${{ github.repository }}" --clobber 2>/dev/null || \
  gh release create "$tag" "${files[@]}" --title "$title" --repo "${{ github.repository }}" --notes "$notes" 2>&1 || \
  echo "⚠ Skipped $tag"
}
```

`upload_to_release` is the standard idempotent pattern used almost everywhere in this script: try to upload assets to an existing release tag with `--clobber` (overwrites same-named assets); if that fails (tag doesn't exist yet), fall back to creating the release fresh.

**Critical behavior to understand:** `--clobber` **overwrites and adds** assets, it never **removes** assets that are no longer present in the source folder. If a file is renamed or deleted from the repo, the old asset stays attached to the release forever unless someone runs `gh release delete-asset` by hand. This is not hypothetical — it already happened today, see §7.3.

**[Added 2026-08-21] `replace_release` — second helper, used only by the `-newest` floating releases (§3.4):**

```bash
replace_release() {
  local tag="$1" title="$2" notes="$3"; shift 3
  local files=("$@")

  if ! gh release upload "$tag" "${files[@]}" --repo "${{ github.repository }}" --clobber 2>/dev/null; then
    if ! gh release create "$tag" "${files[@]}" \
        --title "$title" --repo "${{ github.repository }}" --notes "$notes" 2>&1; then
      echo "  ⚠ Skipped $tag (upload/create failed — previous release left untouched)"
      return 1
    fi
  fi

  # prune remote assets not in the new file list
  local wantnames=(); for f in "${files[@]}"; do wantnames+=("$(basename "$f")"); done
  local livenames=(); mapfile -t livenames < <(gh release view "$tag" --repo "${{ github.repository }}" --json assets --jq '.assets[].name' 2>/dev/null)
  for name in "${livenames[@]}"; do
    keep=0; for w in "${wantnames[@]}"; do [ "$name" = "$w" ] && keep=1 && break; done
    [ "$keep" -eq 0 ] && gh release delete-asset "$tag" "$name" --repo "${{ github.repository }}" --yes 2>/dev/null
  done
}
```

Replaces the old delete-then-create pattern for `-newest` releases (see §3.4, §7.5 for why). Order of operations matters here: it uploads/creates the new content **first**, and only prunes assets that are no longer wanted **after** that succeeds — so if the upload/create step fails (including a bare transient GitHub API error, which is exactly what happened in §7.5), the release is left exactly as it was instead of being deleted with nothing to replace it. The prune step is a name-diff against what's actually live (via `gh release view --json assets`), not a blanket delete — so it still cleans up genuinely stale/renamed assets, it just does so safely, after the fact.

**[2026-09-02] `gh_asset_name` helper — required by `replace_release`, added after the first version of this helper caused real data loss (§7.5 part 2):**

```bash
gh_asset_name() {
  printf '%s' "$1" | sed -E 's/[^A-Za-z0-9._ -]//g; s/ +/./g; s/^\.+//; s/\.+$//'
}
```

Predicts the release-asset name GitHub will actually store for a given local filename: delete characters outside `[A-Za-z0-9._- ]` (strips parens, etc.), collapse whitespace runs to a single `.`, trim leading/trailing dots. Reverse-engineered from real examples and validated against every one of the ~195 files this workflow currently publishes, cross-checked against all ~212 live assets — zero unexplained mismatches. `replace_release` runs every local filename through this before comparing to the live asset list (`gh release view --json assets`), for both the completeness check and the prune check, so both sides are in the same name-space. **Do not compare a raw local basename directly against a live GitHub asset name — that was the exact bug in §7.5.**

Current version of `replace_release` also verifies completeness after upload: it checks that every wanted file's predicted name actually appears live, and retries once (via `gh release upload --clobber`) for anything missing, logging a warning if the retry still doesn't stick. Only after that does it prune.

### 3.3 Root-level drivers → tag `drivers-and-tools`

Any `*.zip` / `*.exe` sitting directly at repo root goes into one flat release, tag `drivers-and-tools`. Currently: `CDM-v2.12.36.4-for-ARM64.zip`, `CDM2123620_SpecLab_Win11_Driver.zip`.

### 3.4 Firmwares

```bash
declare -A FIRMWARE_MAP=(
  ["solis-ventus-firmwares"]="solis-ventus"
  ["duophony-firmwares"]="duophony"
  ["enieqma-firmwares"]="enieqma"
  ["cabzeus-firmwares"]="cabzeus"
  ["synesthesia-firmwares"]="synesthesia"
  ["specular-tempus-firmwares"]="specular-tempus"
)
```

For each folder → product pair:
- Every top-level `*.fdt` file gets its **own** release: tag = `<product>-<slugified-filename-without-extension>`. E.g. `SV_firmware_v1_8_14.fdt` → tag `solis-ventus-sv_firmware_v1_8_14`.
- If a `<folder>/newest/*.fdt` exists: **floating tag** `<product>-newest`, bundling the newest `.fdt` + every PDF in `manuals/<product>/` + every PDF in `<folder>/firmware-update-history/`. **[As of 2026-08-21]** this calls `replace_release` (§3.2): upload-then-prune, safe against a failed API call. **Before 2026-08-21** it did `gh release delete` then `gh release create` with no safety net — see §7.5 for the actual outage that caused the change.
- Only `solis-ventus` and `enieqma` currently have a populated `newest/` folder, so only those two products have a `-newest` release. `duophony`, `cabzeus`, `synesthesia`, `specular-tempus` do not (deliberate gap, not fixed — see §7.1).

Special case bolted onto the end of this section: `synesthesia-firmwares/firmware-software-patch-bundle/` (zips, not `.fdt`s) → its own flat release, tag `synesthesia-patch-bundle`.

### 3.5 Editors

```bash
declare -A EDITOR_MAP=(
  ["editors/cabslab"]="cabslab"
  ["editors/duophony"]="duophony-dfu"
  ["editors/enieqlab"]="enieqlab"
  ["editors/speclab"]="speclab"
  ["editors/sv-studio"]="sv-studio"
  ["editors/symmlab"]="symmlab"
)
```

For each folder → product pair:
- Every version subfolder (e.g. `SV Studio 1.6.5/`) → its own release, tag = `<product>-<slugified-version-folder-name>`. This is where the double-prefixed tags come from, e.g. `sv-studio-sv-studio-1.6.5` (folder name already contains the product name, then the script prepends it again). Confirmed present, deliberately not renamed — see §7.1.
- Folders named `patch`, `patches`, `drivers`, `extras` are skipped by this loop (handled separately below).
- Any loose files directly in the editor's root (not in a version subfolder) → tag `<product>-extras`.
- If `<folder>/patch/` exists → tag `<product>-patch` (currently only `symmlab`).

### 3.6 Manuals — per-product, standalone

```bash
while IFS= read -r -d '' manualdir; do
  manualproduct=$(basename "$manualdir")
  ...
  tag="${manualproduct}-manuals"
  upload_to_release "$tag" "${manualproduct} - Manuals" "..." "${manualfiles[@]}"
done < <(find "manuals" -mindepth 1 -maxdepth 1 -type d -print0)
```

This iterates **every** subfolder under `manuals/` generically — it does not check `FIRMWARE_MAP` or `EDITOR_MAP` first. That's intentional: it's what makes manuals for products with no firmware/editor entry (e.g. `cabzeus-mono`, `jonassus`, `orca`, `rossie`, `skylar`) still get published, tag `<product>-manuals`. This was the main driver of the 2026-07-27 fix round (see §5) — 9 of 11 manual folders previously had no publishing path at all.

### 3.7 NEW — Artist series presets → tag `artist-series-presets`

```bash
mapfile -d '' presetfiles < <(find "artist-series-presets" -maxdepth 1 -type f ! -name ".DS_Store" -print0 2>/dev/null)
if [ ${#presetfiles[@]} -gt 0 ]; then
  upload_to_release "artist-series-presets" "Artist Series Presets" "Artist series preset bundles" "${presetfiles[@]}"
fi
```

Flat bucket, same pattern as §3.3 / editor `-extras`. All top-level files in `artist-series-presets/`, `.DS_Store` excluded, uploaded with clobber. Not versioned per-file, not tied into `FIRMWARE_MAP`/`EDITOR_MAP` — every file that lands directly in this folder becomes an asset on the single `artist-series-presets` release.

### 3.8 NEW — Versions reference → tag `versions-reference`

```bash
mapfile -d '' verreffiles < <(find "versions-reference" -maxdepth 1 -type f ! -name ".DS_Store" -print0 2>/dev/null)
if [ ${#verreffiles[@]} -gt 0 ]; then
  upload_to_release "versions-reference" "Versions Reference" "Version and entitlement reference data" "${verreffiles[@]}"
fi
```

Identical flat-bucket pattern. Currently uploads both `gfisystem-ver-ref.txt` and `artist-preset-entitlements.txt`. **The entitlements file is sensitive — see §7.2 before changing anything here.**

---

## 4. Companion script: `generate-download-links.sh`

Not part of CI — a local, manually-run script (`./generate-download-links.sh`, requires `gh` + `jq`, must be `gh auth login`'d). Paginates `gh api repos/gfisystem/downloads/releases` and dumps every asset's `browser_download_url`, one per line, into `generated-download-links.txt` next to the script, then auto-opens the file (`open`, macOS-only). This is how the human confirms what's actually live after a workflow run — it's a read of GitHub's current state, not a generator of anything new. It has been re-run today; `generated-download-links.txt` currently reflects the real, live state of every release including the two new ones (see §8).

---

## 5. Timeline (chronological, for context)

| Date | Commit | What |
|---|---|---|
| — | `022ce1a` | `add release workflow` — workflow first added |
| — | `831a0d0` | `release on push` |
| — | `888d44e` | `script to gen all dl links` — `generate-download-links.sh` added |
| — | `cc25bbc` | `trigger workflow on relevant files` |
| 2026-07-27 | (several) | Reliability audit + fix round (see §7 of prior context / [[github-actions-release-workflow]] memory): non-idempotent `gh release create` calls that silently failed on every re-run were replaced with `upload_to_release`; `.gitignore` added for `.DS_Store`; root `*.zip`/`*.exe` added to trigger `paths:`; generic per-product `manuals/` loop added (fixed 9/11 manual folders having zero publish path, including `cabzeus`) |
| 2026-08-04 12:38 | `bb18c5e` | `added file` — original messy-named preset file added: `artist-series-presets/Solis Ventus backup on 22 July 2026 at 16.40.bkp` |
| 2026-08-04 12:45 | `7b62537` | `new files` — **this session's workflow edit**: added `artist-series-presets/**` + `versions-reference/**` to trigger paths, added the two new release blocks (§3.7, §3.8) |
| 2026-08-04 13:04 | `bfff388` | `rename file` — preset file renamed to `artist-bundle-november-drops.bkp` (matches the `artist-bundle-<slug>.bkp` convention documented in the entitlements file), `generated-download-links.txt` regenerated |
| 2026-08-04 14:36 | `bc2c261` | `add ecnrypted` [sic] — added `artist-series-presets/artist-bundle-november-drops.bkp.enc.bkp`, `generated-download-links.txt` regenerated again |
| 2026-08-21 | run `32441023802` (`workflow_dispatch`, not a commit) | **`enieqma-newest` outage + fix — see §7.5 for full detail.** Root-caused a live 404 on the `enieqma-newest` release to a transient GitHub API `HTTP 500` hitting the old delete-then-create step on the prior push (`fbaa56c`, "add enieqma fw 1.2.4"). Fixed immediately by re-dispatching the workflow (this run) — confirmed restored via `gh api repos/gfisystem/downloads/releases/tags/enieqma-newest`, history PDF included again. |
| 2026-08-21 | landed in `0dd29b9` (unrelated message, "add sv 1.6.6 mac installer") | Structural fix for the same class of bug: added `replace_release` helper (§3.2), rewired the `-newest` block (§3.4) to use it instead of delete-then-create. Written as uncommitted at the time; the user committed it at some point before 2026-08-24 without a dedicated commit message. |
| 2026-08-24 → 2026-08-27 | `61266ae`, `77c98f4`, `f51f3d2`, `2919b0c`, `be72b8b` (ordinary firmware/editor pushes) | Each push auto-triggered the workflow, and each run's `replace_release` call silently deleted the space-named assets from `enieqma-newest`/`solis-ventus-newest` — see §7.5 part 2. Nobody noticed until the user hit a 404 and asked. |
| 2026-09-02 | uncommitted | Root-caused §7.5 part 2 (raw-vs-sanitized name comparison bug in `replace_release`'s own prune step), added `gh_asset_name` helper + completeness retry (§3.2). Audited all ~127 live tags vs source — confirmed only these two affected. Restored the 8 stripped files via `gh release upload --clobber` (user-approved). Code fix **sitting in the working tree, not committed** — see §9 rule 1. |

Between `7b62537` and now, the workflow was actually **triggered for real** (either manual `workflow_dispatch` or a push that matched the new paths) — the live release URLs in §8 below are confirmed real as of 2026-08-04, not hypothetical (though likely stale by now — see the staleness warning at the top of this doc).

---

## 6. What's new today, in plain terms

Two new folders exist to support a **serial-number-gated "artist series presets"** feature:

- `artist-series-presets/` — the actual preset bundle files (`.bkp`) that get published as downloads.
- `versions-reference/artist-preset-entitlements.txt` — the map deciding which pedal serial number unlocks which bundle. Format:
  ```
  SERIAL|Display Name|file-slug|presetCount
  ```
  Currently one **placeholder** row: `SOLV-123456|Echo Wind|november-drops|10`. The file-slug (`november-drops`) is what ties an entitlement row to a real filename (`artist-bundle-november-drops.bkp`) — confirmed by the rename in `bfff388`.
- `versions-reference/gfisystem-ver-ref.txt` — unrelated, just plain version numbers (`Firmware: 1.4.0`, `SV Studio: 1.2.0`). Not sensitive.

---

## 7. Deliberate decisions — do not "fix" these without asking first

This is the most important section for whoever picks this up next. Everything below **looks** like a bug or oversight. It was surfaced to the user explicitly and they made an informed call each time. Treat any change here as a real decision point, not cleanup — confirm with the user before touching any of it.

### 7.1 Tag-naming inconsistencies (from the 2026-07-27 round, still true)
- Editor tags double up the product name: `sv-studio-sv-studio-1.6.5`, `cabslab-cabslab-2.0.8`, etc.
- Legacy bare tags `v1.8.11` / `v1.8.12` coexist with the current `solis-ventus-sv_firmware_v1_x_x` scheme for the same product (pre-workflow manual releases).
- Only `solis-ventus` and `enieqma` have a floating `-newest` release; the other four firmware products don't.

**Why left alone:** changing any existing tag name changes/breaks the public download URL for that asset. The user was asked and chose not to touch this.

### 7.2 `artist-preset-entitlements.txt` is published in plaintext, publicly, on purpose (for now)

I flagged before wiring this in: this repo is public, so publishing the entitlement map (§3.8) makes the entire serial→bundle mapping world-readable, and makes it possible to derive the download URL for any artist's preset bundle without owning the entitled hardware — i.e. the "gating" is not actually enforced anywhere in this pipeline, it's just a lookup table sitting in the open.

**User's exact response:** *"just do it publicly for now, im planning to encrypt it later but for now, just inlcude it."*

So it was wired in as-is, deliberately. **Status as of this doc:** an encrypted counterpart now exists (`artist-bundle-november-drops.bkp.enc.bkp`, added in `bc2c261`), but:
- The **plaintext** `artist-bundle-november-drops.bkp` is still present and still published alongside it.
- `artist-preset-entitlements.txt` itself is still plaintext and still published — only the preset *content* has an encrypted variant, the *entitlement map* does not.

Do not assume encryption is "done" — it looks like a first step, not a completed migration. If asked to harden this, confirm current intent with the user before removing/changing the plaintext files; don't infer it from the presence of the `.enc.bkp` file alone.

### 7.3 NEW FINDING (not previously flagged) — stale orphaned asset on the live `artist-series-presets` release

Confirmed by reading the live `generated-download-links.txt` (regenerated today, reflects real GitHub state): the `artist-series-presets` release currently has **three** assets, not two:

```
https://github.com/gfisystem/downloads/releases/download/artist-series-presets/artist-bundle-november-drops.bkp
https://github.com/gfisystem/downloads/releases/download/artist-series-presets/artist-bundle-november-drops.bkp.enc.bkp
https://github.com/gfisystem/downloads/releases/download/artist-series-presets/Solis.Ventus.backup.on.22.July.2026.at.16.40.bkp
```

The third one is the **original, pre-rename filename** (spaces became dots via GitHub's asset-name sanitization). This is exactly the `--clobber`-never-deletes behavior described in §3.2: the file was renamed on disk (`bfff388`), the workflow ran again, and the new filename was uploaded as a new asset — but the old asset from the original filename was never removed, because nothing in this script ever calls `gh release delete-asset`. It's just sitting there, live, publicly downloadable, orphaned.

This will keep happening for any future rename in a flat-bucket folder (`artist-series-presets`, `versions-reference`, `drivers-and-tools`, any `-extras`). It hasn't been raised with the user yet — flag it, don't silently delete the stale asset (deleting a release asset is a real public action, needs explicit confirmation, see §9).

### 7.5 [RESOLVED — but see part 2] `enieqma-newest` / `solis-ventus-newest` data loss, two separate incidents

**Part 1 — 2026-08-21, `enieqma-newest` went fully missing due to an unsafe delete-then-create step**

This one wasn't a deliberate decision — it's a real bug that caused a real outage, triggered by asking "why is the enieqma firmware update history not included in the release?". The honest answer turned out to be "the whole `enieqma-newest` release doesn't exist," not "one file is missing from it."

**Root cause, confirmed via GitHub API + Actions run logs (not guessed):**
- The `-newest` block (§3.4, pre-2026-08-21 version) did `gh release delete "$tag" --yes` **then** `gh release create "$tag" ...`, with the create's failure swallowed by `|| echo "⚠ Skipped $tag"`.
- On 2026-08-19 (`6943bcd`), this succeeded fine — `enieqma-newest` was live with the history PDF, confirmed in that run's log.
- On 2026-08-21 (`fbaa56c`, "add enieqma fw 1.2.4"), the delete succeeded but the recreate hit `HTTP 500` from GitHub's API (transient — confirmed `solis-ventus-newest`, same code path, was unaffected and stayed live as a control). The swallowed failure meant the Actions run still reported green ✅ with no visible error, while the release was left deleted. Confirmed 404 via `gh api repos/gfisystem/downloads/releases/tags/enieqma-newest`.

**Fixed, in two parts, both approved by the user in-chat:**
1. **Immediate:** re-ran the workflow via `gh workflow run create-releases.yml --ref main` (run `32441023802`), confirmed via the API that `enieqma-newest` is back with all 5 expected assets including `Enieqma.Firmware.Update.history.pdf`. This part is done and live — no further action needed.
2. **Structural:** replaced the delete-then-create pattern with the new `replace_release` helper (§3.2) for **both** `solis-ventus-newest` and `enieqma-newest` (same shared code path in `FIRMWARE_MAP` loop, one edit covers both). **This part is written but not committed** — it's sitting in the working tree. Until the user commits and pushes it, the live workflow on GitHub still runs the old, unsafe delete-then-create version, and this exact outage could recur on the next transient API blip.

**Not done, deliberately out of scope of what was asked:** the same `replace_release` upload-then-prune pattern would also fix the orphaned-asset issue in §7.3 (which affects the flat-bucket sections: `drivers-and-tools`, editor `-extras`, `artist-series-presets`, `versions-reference`) — but the user only approved hardening the `-newest` step specifically. Extending the pattern to those sections is a reasonable follow-up, not something to do unprompted — see §10.

**Part 2 — 2026-08-21 through 2026-09-02, `replace_release` itself silently deleted the same files it was supposed to protect**

The user later committed the part-1 fix (exactly when is unclear — the commit it landed in, `0dd29b9`, has an unrelated message, "add sv 1.6.6 mac installer"). It then ran on every subsequent push (confirmed runs on 2026-08-24, -26, -27) and, on **every single run**, its prune step deleted every wanted asset whose original filename contained a space — because `wantnames` was built from raw local `basename` output while `livenames` came from `gh release view` (already GitHub-sanitized: spaces→dots, punctuation stripped). Raw `"Solis Ventus - User Manual - rev I.pdf"` never equals sanitized `"Solis.Ventus.-.User.Manual.-.rev.I.pdf"`, so the prune loop treated it as stale and ran `gh release delete-asset` on it. Confirmed directly in the 2026-08-27 run log:
```
→ pruning stale asset from solis-ventus-newest: SolisVentus.Firmware.Update.history.pdf
→ pruning stale asset from enieqma-newest: Enieqma.Firmware.Update.history.pdf
```
This is how the user found it: they hit a 404 on `SolisVentus.Firmware.Update.history.pdf` days later and asked why. **The immediate trigger question ("why is this link 404") undersold the actual scope — the bug had been silently stripping the same ~8 files back out on every push for about 6 days before anyone noticed.**

Investigation method (worth repeating for future audits — see §5 "how to re-audit"): rather than checking file-by-file, the release-discovery half of this very script was extracted, its `gh`-calling functions stubbed to record `(tag, wanted-filename)` pairs instead of executing, and run locally against the actual repo checkout — giving an authoritative "what should be live" list without guessing. That was diffed against a single paginated `gh api repos/gfisystem/downloads/releases` pull (all releases + assets in one read). Result: **only these two tags were affected** — the other ~120 live release tags matched their expected source files exactly (aside from already-known, harmless items: stray `default.DS_Store` assets from before `.gitignore` existed, the pre-rename `artist-series-presets` orphan from §7.3, and the two legacy pre-workflow `v1.8.11`/`v1.8.12` tags from §7.1).

**Fixed 2026-09-02:** added the `gh_asset_name` helper (§3.2) so `replace_release` compares like-for-like instead of raw-vs-sanitized. Also added the completeness-check/retry that was separately approved after part 1 — `replace_release` now verifies every wanted asset actually landed and retries once if not, before ever pruning. Validated the new normalization function against all ~195 files this workflow publishes and all ~212 live assets, zero unexplained mismatches, before trusting it to drive a delete call. **This fix is, again, uncommitted** — same rule as always, this agent doesn't commit (§9 rule 1). The 8 files the bug had stripped out (2 on `enieqma-newest`, 6 on `solis-ventus-newest`) were restored directly via `gh release upload --clobber` after explicit user confirmation, and reverified live via `gh api`.

**Lesson for next time, stated plainly:** a fix that adds a *delete* path needs to be validated against real, messy production filenames (spaces, punctuation) before it's trusted — not just syntax-checked and dry-run against discovery logic that never calls the destructive step. Neither part-1 nor part-2 of this incident would have been caught by `bash -n` or a local `find`-only dry run; both required checking actual live GitHub state.

### 7.4 `temporary-firmwares/` is not wired into the workflow at all

`temporary-firmwares/temp-fw.fdt` exists on disk but: not in the trigger `paths:` list, not in `FIRMWARE_MAP`. Pushing to this folder does nothing — no release, no trigger. Unknown whether this is intentional (a staging area that's *supposed* to stay unpublished) or an oversight. Not touched this session because it was out of scope of what was asked. Worth a one-line question to the user if it comes up.

---

## 8. Confirmed live state right now

Pulled from `generated-download-links.txt` after today's real workflow run(s) — this reflects actual GitHub state, not intent:

- 118 unique release tags total across the repo.
- `artist-series-presets` release: 3 assets (see §7.3 for why it's 3 and not 2).
- `versions-reference` release: 2 assets — `artist-preset-entitlements.txt` and `gfisystem-ver-ref.txt`, both live and publicly downloadable right now.

If you need the current ground truth again later, re-run `./generate-download-links.sh` from repo root (needs `gh auth login` first) rather than trusting this doc's snapshot as still accurate — it will go stale.

---

## 9. Hard rules for whoever (whatever agent) picks this up

1. **Never run `git commit` in this repo.** The user commits everything themselves, always, no exceptions — confirmed explicitly ("no. always I do the commit."). Don't ask "want me to commit?" either — just report the change is ready and stop there.
2. **Never run `gh release create/upload/delete`, `gh workflow run`, or `git push` without explicit in-chat confirmation for that specific action.** This is a public repo — every one of those is a real, publicly-visible, non-trivially-reversible action (release assets get scraped/cached/indexed once public, even if deleted later). Explaining *how* to do it is fine and doesn't need permission; actually doing it does.
3. **Don't "clean up" anything in §7 unprompted** — tag-naming, the plaintext entitlements/preset exposure, the stale orphaned asset, or the unwired `temporary-firmwares/` folder. Each one was either an explicit user decision or is an unconfirmed open question. Surface, don't silently fix.
4. **Treat any new folder added under a public-release-producing path as effectively public the moment it's wired into this workflow and run.** If new sensitive-looking content shows up (credentials, customer data, anything resembling license/entitlement keys), flag it the same way §7.2 was flagged — before wiring it in, not after.
5. Validate workflow edits before handing them back: YAML via `ruby -ryaml -e "YAML.load_file(...)"` (no `yq`/PyYAML available in this environment as of this session), and the embedded bash via `bash -n` on the extracted `run:` block. Dry-run any new `find` logic against the real folders locally (no `gh` calls) to confirm file discovery before it goes anywhere near a real release.

---

## 10. Open items — raise with the user, not yet decided

- [ ] Is the plaintext `artist-bundle-november-drops.bkp` supposed to be removed now that an encrypted version exists, or is plaintext intentionally staying available too?
- [ ] Should `artist-preset-entitlements.txt` also get an encrypted/gated treatment, or is only the preset *content* meant to be encrypted (leaving the entitlement map itself in the clear)?
- [ ] Should the stale `Solis.Ventus.backup.on.22.July.2026.at.16.40.bkp` asset be deleted from the live `artist-series-presets` release? (And more broadly: should this workflow gain asset-pruning logic so renames don't leave orphans in *any* flat-bucket release going forward?)
- [ ] Is `temporary-firmwares/` intentionally excluded from the workflow, or should it be wired in like the other firmware folders?
- [ ] **[2026-09-02, supersedes the 2026-08-21 item]** The `gh_asset_name`-fixed `replace_release` (§3.2, §7.5 part 2) is written but uncommitted — needs the user to commit + push before it's actually protecting anything. Until then the live workflow still runs the **buggy** version that deletes space-named assets on every run. This is more urgent than a typical pending fix: leaving it uncommitted means the next push to `solis-ventus-firmwares/**`, `enieqma-firmwares/**`, `manuals/solis-ventus/**`, or `manuals/enieqma/**` will silently strip the same 8 files right back out again.
- [ ] **[2026-08-21]** Should the same `replace_release` upload-then-prune pattern be extended to the flat-bucket sections (`drivers-and-tools`, editor `-extras`, `artist-series-presets`, `versions-reference`) to fix the orphaned-asset issue in §7.3 the same way? Not done — only `-newest` was in scope of what was approved. Given §7.5 part 2, extending this pattern elsewhere should come with the same real-filename validation this time, not just a syntax check.
- [ ] **[2026-09-02]** Consider whether this workflow needs a lightweight live-state check (e.g. a periodic re-run of the audit method described in §7.5 part 2) rather than relying on someone noticing a 404 by hand — that's how part 2 went undetected for 6 days.
