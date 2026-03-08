## Summary

<!-- What does this change and why? Link the issue if applicable. -->

## Type of change

- [ ] Bug fix
- [ ] New hook rule or quiet override
- [ ] Security hardening
- [ ] Monitoring / OTEL / Grafana
- [ ] Docs / tests only

## Checklist

- [ ] Hook scripts exit cleanly on all inputs (no `set -e`; uses `_warden_suppress_ok` / `_warden_deny`)
- [ ] New rules tested with fixtures in `tests/` — run `bash tests/run.sh`
- [ ] Regex anchored to avoid false positives (word boundaries, BOL/EOL as appropriate)
- [ ] JSON constructed via `jq -n` — no string interpolation into JSON
- [ ] No secrets, tokens, or `.env` files included
- [ ] `install.sh` updated if a new hook file was added
