# Conventions

- Use existing state-machine helpers for video state transitions when available.
- Treat `:encoded` videos as protected during sync; do not reset encoded state or discard chosen VMAF/original-size data.
- `Reencodarr.AbAv1.OutputParser` is the shared parser for ab-av1 output; keep encode and CRF-search parsing aligned there.
- `Reencodarr.Rules.build_args/4` is the central encode/CRF-search argument builder.
- Service clients live under `lib/reencodarr/services/` and follow existing CarReq retry/fuse patterns.
- Paginated list LiveViews use URL params plus `ReencodarrWeb.Live.FlopList`; list APIs return `{items, %Flop.Meta{}}`.