# victoriametrics-railway

Railway wrapper for single-node VictoriaMetrics (pinned `v1.153.0`). Basic auth from boot
(`VM_PASSWORD` required), writes stop before the volume fills, scrape targets from `SCRAPE_TARGETS`.
