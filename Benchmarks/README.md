# Bolt Benchmarks

Internal performance benchmarks for Bolt.

## Why this package is separate
This is a standalone Swift package so Bolt library consumers do not pull benchmark dependencies.

## Run
```bash
cd Benchmarks
swift run -c release BoltBenchmarks --format json --quiet
```

## Filter
```bash
cd Benchmarks
swift run -c release BoltBenchmarks --filter singleton
```

## Current benchmark set
- Tier A (head-to-head, comparable):
  - `tier_a_bolt_factory_resolve_leaf`
  - `tier_a_bolt_factory_resolve_root`
  - `tier_a_bolt_singleton_warm_resolve`
  - `tier_a_bolt_with_overrides_scope_entry_depth_1`
  - `tier_a_bolt_with_overrides_resolve_depth_1`
  - `tier_a_bolt_override_scope_comparable`
  - `tier_a_whoopdi_factory_resolve_leaf`
  - `tier_a_whoopdi_factory_resolve_root`
  - `tier_a_whoopdi_singleton_warm_resolve`
  - `tier_a_whoopdi_local_inject_scope`
  - `tier_a_factory_factory_resolve_leaf`
  - `tier_a_factory_factory_resolve_root`
  - `tier_a_factory_singleton_warm_resolve`
  - `tier_a_factory_override_scope`
  - `tier_a_dependencies_factory_resolve_leaf`
  - `tier_a_dependencies_factory_resolve_root`
  - `tier_a_dependencies_singleton_warm_resolve`
  - `tier_a_dependencies_override_scope`
- Tier B (Bolt stress):
  - `tier_b_bolt_factory_resolve_with_params`
  - `tier_b_bolt_singleton_cold_resolve`
  - `tier_b_bolt_with_overrides_scope_entry_depth_3`
  - `tier_b_bolt_with_overrides_scope_entry_depth_10`
  - `tier_b_bolt_with_overrides_resolve_depth_3`
  - `tier_b_bolt_with_overrides_resolve_depth_10`
  - `tier_b_bolt_with_overrides_scope_entry_contention`

## Baseline capture (Phase 1)
Run the JSON command at least 5 times on the same machine/session class, and compare medians for:
- `tier_a_bolt_factory_resolve_leaf`
- `tier_a_bolt_factory_resolve_root`
- `tier_b_bolt_factory_resolve_with_params`
- `tier_a_bolt_singleton_warm_resolve`
- `tier_b_bolt_singleton_cold_resolve`
- `tier_a_bolt_with_overrides_scope_entry_depth_1`
- `tier_b_bolt_with_overrides_scope_entry_depth_3`
- `tier_b_bolt_with_overrides_scope_entry_depth_10`
- `tier_a_bolt_with_overrides_resolve_depth_1`
- `tier_a_bolt_override_scope_comparable`
- `tier_b_bolt_with_overrides_resolve_depth_3`
- `tier_b_bolt_with_overrides_resolve_depth_10`
- `tier_b_bolt_with_overrides_scope_entry_contention`

## Override benchmark interpretation (Phase 3)
- `scope_entry_*`: measures lexical override push/pop overhead without dependency resolution.
- `resolve_*`: measures override overhead when resolving a rooted dependency graph within the active scope.
- `*_depth_N`: nested override layers at depth `N` (1, 3, 10).
- `scope_entry_contention`: concurrent tasks entering independent override scopes.
- `tier_a_bolt_override_scope_comparable`: single-level override plus root resolve, aligned with reference `*_override_scope` style.
