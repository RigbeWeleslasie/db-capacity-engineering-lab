# C6 — observability evidence

- `alert-rules.yml` — the 5 alert rules (one per incident, plus
  `OPS2204_TargetDown` as a second, more robust signal for OPS-2204 — see
  `evidence/07-incidents/README.md` for why).
- `dashboards/capacity-lab-dashboard.json` — full Grafana dashboard export,
  8 panels: the 4 pre-loaded ones plus 4 added this session, one per
  incident, each querying the exact expression its alert rule uses.
- `panels/` — real screenshots of the 4 per-incident panels, captured live
  during an actual re-triggered incident (not staged).

## Loom — one incident caught end-to-end

**[OPS-2204: alert firing → dashboard → mechanism, live](https://www.loom.com/share/506b07fa0089452b8e044250d38a2362)**

Recorded per the assignment's submission requirement: inducing the OPS-2204
crash-loop live, showing `OPS2204_TargetDown` actually firing in Prometheus,
showing the same signal on the Grafana panel above, and naming the
mechanism (unbuffered export + concurrent load → OOM-kill) — including why
the originally-designed memory-threshold alert never fires in practice (the
crash outruns Prometheus's scrape interval), which is why the second alert
exists. See `evidence/07-incidents/README.md` for the full written version
of the same walkthrough.
