# Bolt Benchmarks

Internal performance benchmarks for Bolt.

## Why this package is separate
This is a standalone Swift package so Bolt library consumers do not pull benchmark dependencies.

## Run
```bash
cd Benchmarks
swift run -c release BoltBenchmarks
```

## Filter
```bash
cd Benchmarks
swift run -c release BoltBenchmarks --filter singleton
```

## Current benchmark set
- Bolt:
  - `bolt_factory_resolve_leaf`
  - `bolt_factory_resolve_root`
  - `bolt_singleton_warm_resolve`
  - `bolt_with_overrides_scope`
- WhoopDI:
  - `whoopdi_factory_resolve_leaf`
  - `whoopdi_factory_resolve_root`
  - `whoopdi_singleton_warm_resolve`
  - `whoopdi_local_inject_scope`
- Factory:
  - `factory_factory_resolve_leaf`
  - `factory_factory_resolve_root`
  - `factory_singleton_warm_resolve`
  - `factory_override_scope`
- swift-dependencies:
  - `dependencies_factory_resolve_leaf`
  - `dependencies_factory_resolve_root`
  - `dependencies_singleton_warm_resolve`
  - `dependencies_override_scope`
