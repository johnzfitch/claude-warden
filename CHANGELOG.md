# Changelog

## 0.7.0

### Added

- **Dense file detection in read-guard**: Three-tier defense for Read tool calls:
  1. Bundled pattern block (node_modules, dist, .min.js, lockfiles)
  2. Oversize block (>2MB default)
  3. Density-based reroute for minified/single-line files (>500 bytes/line avg)
- Dense files are rerouted via `updatedInput` (capped to 100 lines) instead of blocked, so the model sees a successful Read with bounded output plus `additionalContext` guidance
- Go port of density detection in `collector/hooks/readguard.go` with `countFileLines()` (no subprocess overhead)
- New `ReadReroute()` output helper in Go types for PreToolUse `updatedInput` with `file_path`/`offset`/`limit`
- 7 new test cases for density scenarios (single-line blob, dense multiline, model-set limit, offset preservation)

### Fixed

- Bundled pattern regex anchors: `node_modules/`, `dist/`, `build/`, `vendor/`, `__generated__/`, `expo-downloads/` now use `(^|/)` prefix to avoid false matches mid-path

### Config

New environment variables (all with sane defaults):
- `WARDEN_DENSE_MIN_BYTES` (8192) -- min file size to check density
- `WARDEN_DENSE_BPL_THRESHOLD` (500) -- bytes/line threshold
- `WARDEN_DENSE_LINE_CAP` (100) -- line limit injected via updatedInput
