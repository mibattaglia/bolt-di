# Bolt Performance Recovery Plan (v0.2 - Reference Port)

Date: 2026-02-12  
Status: Active (P1-P3 completed on 2026-02-12)  
Owner: Bolt maintainers

## Goal
Make Bolt the fastest runtime DI library in our benchmark set (WhoopDI, Factory, swift-dependencies) on comparable scenarios.

## Plan Mode
This plan is now a reference-port plan: copy proven internal patterns first, adapt only where Bolt semantics require it.

## Hard Truths
- Incremental micro-optimizations are unlikely to make Bolt fastest.
- `Any`-based factory erasure and repeated dynamic casting are expensive in hot loops.
- Bolt currently pays more semantic overhead than reference benchmarks in core paths.
- If a change is elegant but not measurably faster, it is a failure for this plan.

## Brutal Policy
- Optimize for benchmark wins first; preserve public semantics, not internal elegance.
- If a move does not produce repeatable median gains in its target metric, revert it.
- Prefer simple fast code over flexible abstractions on hot paths.
- Allow advanced internal techniques (`@inline(__always)`, unsafe fast paths, precomputed tables) when bounded by tests and benchmark gates.
- All internal APIs are fair game for change/removal if benchmarks improve and correctness holds.
- Copy reference implementations when they are faster; do not re-invent equivalent mechanisms.

## Why Prior Work Missed
Recent phases improved structure and correctness, but did not remove the dominant hot-path costs:
- Per-resolve synchronized/dynamic lookup overhead in `Container.resolve`.
- Depth-sensitive override lookup overhead in nested scopes.
- Singleton warm path still paying map/cell indirection overhead.
- Cycle tracking checks still adding cost on non-cached build paths.
- Benchmark matrix mixes apples-to-apples and Bolt stress tests in one view.

## Recovery Moves (Priority Order)

### 1) Reference Key/Lookup Port (Factory-inspired)
Replace lock-guarded registration reads with immutable snapshots and atomic swap on writes.

Reference inspiration:
- Factory `FactoryKey` normalization and direct hashed lookup path.

Implementation direction:
- Introduce normalized internal key representation optimized for dictionary hashing.
- Remove hot-path string/type-name work from key creation.
- Publish immutable registration lookup snapshots atomically on writes.
- Resolve reads snapshots lock-free.

Expected impact:
- Large reduction in factory leaf/root overhead.

Acceptance checks:
- No behavior regressions in existing tests.
- `bolt_factory_resolve_leaf` and `bolt_factory_resolve_root` median improvement vs current.

### 2) Override Scope Port (WhoopDI + swift-dependencies inspired)
Replace layered resolve-time override traversal with child/snapshot scoping.

Reference inspiration:
- WhoopDI child-container shadowing (override locally, fallback to parent).
- swift-dependencies task-local lexical scoping discipline.

Implementation direction:
- `withOverrides` creates a lightweight scoped container/view with only override registrations.
- Resolve path becomes: local lookup -> parent fallback (single-step chain), no per-key layer recursion.
- Preserve lexical/task-local behavior and deterministic precedence.

Expected impact:
- Major improvement in override resolve benchmarks, especially nested-depth runs.

Acceptance checks:
- Nested precedence and restore semantics unchanged.
- `bolt_with_overrides_resolve_depth_{1,3,10}` medians improve materially.

### 3) Singleton Port (WhoopDI-inspired DCL at Entry)
Attach singleton storage directly to registration entries and use direct DCL path.

Reference inspiration:
- WhoopDI singleton definition uses simple double-checked locking and keeps warm reads minimal.

Implementation direction:
- Embed/associate singleton cell with the effective registration entry.
- Warm path: unchecked read -> lock -> recheck -> initialize once.
- Remove extra singleton map indirection on warm resolve.
- Scoped overrides own scoped singleton entries; base fallback reuses base entries.
- Keep exactly-once under contention.

Expected impact:
- Improve `bolt_singleton_warm_resolve`.

Acceptance checks:
- Contention test still proves exactly-once init.
- Warm median improves while cold behavior remains correct.

### 4) Cycle Detection Cost Reduction
Reduce cycle-check overhead in non-cyclic hot paths.

Reference inspiration:
- Reference libraries minimize work in successful resolve paths and keep richer diagnostics primarily on failure paths.

Implementation direction:
- Replace linear `stack.contains` checks with constant-time membership tracking.
- Keep full cycle path diagnostics on failure.
- Do not weaken cycle detection correctness.

Expected impact:
- Secondary but broad improvements across root/factory/override resolve paths.

Acceptance checks:
- Cycle error tests remain deterministic and unchanged.
- Small measurable wins in root and nested resolve paths.

### 5) Benchmark Matrix Split: Head-to-Head vs Stress
Separate benchmark reporting into two tiers to avoid conflating goals.

Reference inspiration:
- Existing reference benchmark suites focus on small, comparable core scenarios; advanced stress cases are typically separated from headline comparisons.

Tier A (head-to-head, comparable):
- factory leaf
- factory root
- singleton warm
- single-level override scope/resolve

Tier B (Bolt stress/feature depth):
- factory with params
- singleton cold/reset
- override depth 3/10
- contention scenarios

Expected impact:
- Clearer signal for “fastest vs references” objective.

Acceptance checks:
- README and benchmark output explicitly labeled by tier.
- Median comparisons reported per tier.

### 6) Remove `Any`/Cast Overhead from Core Resolve Paths
Build typed internal fast paths for the dominant shapes (`Factory<T>`, `Singleton<T>`) so hot resolves avoid repeated existential conversions.

Reference inspiration:
- Reference libraries keep hot-path value flow tight and direct; they avoid repeated type-erased adapters inside every resolve.

Implementation direction:
- Add typed internal factory entry points for common non-parameterized registrations.
- Keep erased fallback path only for uncommon/parameterized cases.
- Precompute registration shape metadata plus typed call handles at registration time.
- Minimize `as?`/`Any` use in leaf/root resolve loops.

Expected impact:
- High impact on factory leaf/root and singleton warm.

Acceptance checks:
- `bolt_factory_resolve_leaf` and `bolt_factory_resolve_root` show repeatable median gains.
- No regressions in parameterized registration behavior.

### 7) Precomputed Resolve Tables for Hot Keys
- Status: Attempted on 2026-02-12, reverted (override-path regressions)
Use precomputed key-to-entry lookup tables/snapshots for fastest-path key resolution.

Reference inspiration:
- Factory/WhoopDI benchmarked paths behave like direct keyed lookup with minimal branching.

Implementation direction:
- Build immutable resolve entries containing shape + singleton cell ref + typed closure handle.
- Read entries from atomically published snapshot tables.
- Avoid reconstructing expensive metadata on every resolve.

Expected impact:
- Broad constant-factor reductions across all Tier A paths.

Acceptance checks:
- Measurable reductions in leaf/root/warm medians.
- No changes in duplicate/override deterministic semantics.

## Execution Plan (Win-or-Revert)

### Phase P1: Key + Snapshot Lookup Port
- Status: Completed (2026-02-12)
- Port Factory-style key normalization for internal lookup.
- Port lock-free read snapshot publication model for registrations.
- Gate:
  - Must improve `bolt_factory_resolve_leaf` and `bolt_factory_resolve_root` medians.
  - If not, revert P1 entirely.

### Phase P2: Override Scope Port
- Status: Completed (2026-02-12)
- Replace current layered override lookup with child/snapshot scoped container model.
- Keep task-local lexical visibility and deterministic precedence.
- Gate:
  - Must improve `bolt_with_overrides_resolve_depth_1` and `bolt_with_overrides_scope_entry_depth_1`.
  - If not, revert P2 entirely.

### Phase P3: Singleton Entry Port
- Status: Completed (2026-02-12)
- Move singleton cells to effective registration entries.
- Use direct DCL per entry (WhoopDI-style).
- Gate:
  - Must improve `bolt_singleton_warm_resolve`.
  - No regression in concurrency correctness tests.
  - If not, revert P3 entirely.

### Phase P4: Cycle Tracking Optimization
- Status: Attempted on 2026-02-12, reverted (Tier A regression)
- Introduce constant-time membership bookkeeping in resolution context.
- Preserve full cycle diagnostics.
- Gate:
  - Must not regress any Tier A metric.
  - If regressions occur without compensating gains, revert P4.

### Phase P5: Typed Fast Path Port
- Status: Attempted on 2026-02-12, reverted (Tier A regression)
- Introduce typed resolve entries for dominant no-params factory/singleton shapes.
- Keep erased fallback only for uncommon/parameterized paths.
- Gate:
  - Must improve at least 2 Tier A metrics.
  - If not, revert P5.

### Phase P6: Final Benchmark/Reporting Cleanup
- Status: Completed (2026-02-12)
- Finalize tiered benchmark naming/documentation.
- Publish before/after medians and percent gaps to each reference.

## Agent Porting Runbook (Detailed)
Use this runbook for every phase. Agents should copy reference mechanics first, then adapt minimally for Bolt semantics.

### 0) Prepare and verify pinned references
Run:
```bash
cd /Users/michaelbattaglia/Documents/swift-bolt
swift package --package-path Benchmarks resolve
jq -r '.pins[] | select(.identity=="whoopdi" or .identity=="factory" or .identity=="swift-dependencies") | "\(.identity)\t\(.state.revision)"' Benchmarks/Package.resolved
git -C Benchmarks/.build/checkouts/WhoopDI rev-parse HEAD
git -C Benchmarks/.build/checkouts/Factory rev-parse HEAD
git -C Benchmarks/.build/checkouts/swift-dependencies rev-parse HEAD
```

Expected revisions:
- `whoopdi`: `1f5f93f3365a459bb4a37ef150ee4ab931ba84b0`
- `factory`: `bcca76f9243ace59477c8d077d25a97795eab5c4`
- `swift-dependencies`: `c79f72b3e67a1eb64f66f76704c22ed6a5c1ed84`

### 1) Phase P1 file fetch (Factory key + lookup model)
Reference files to fetch:
- `Benchmarks/.build/checkouts/Factory/Sources/Factory/Factory/Key.swift`
- `Benchmarks/.build/checkouts/Factory/Sources/Factory/Factory/Containers.swift`
- `Benchmarks/.build/checkouts/Factory/Sources/Factory/Factory/Registrations.swift`

Run:
```bash
cd /Users/michaelbattaglia/Documents/swift-bolt
mkdir -p /tmp/bolt-port/P1
cp Benchmarks/.build/checkouts/Factory/Sources/Factory/Factory/{Key.swift,Containers.swift,Registrations.swift} /tmp/bolt-port/P1/
```

Bolt target files:
- `Sources/Bolt/Key.swift`
- `Sources/Bolt/Registration.swift`
- `Sources/Bolt/Container.swift`

### 2) Phase P2 file fetch (WhoopDI override shadowing + task-local semantics)
Reference files to fetch:
- `Benchmarks/.build/checkouts/WhoopDI/Sources/WhoopDIKit/Container/Container.swift`
- `Benchmarks/.build/checkouts/WhoopDI/Sources/WhoopDIKit/Container/ContainerContext.swift`
- `Benchmarks/.build/checkouts/swift-dependencies/Sources/Dependencies/WithDependencies.swift`
- `Benchmarks/.build/checkouts/swift-dependencies/Sources/Dependencies/Dependency.swift`

Run:
```bash
cd /Users/michaelbattaglia/Documents/swift-bolt
mkdir -p /tmp/bolt-port/P2
cp Benchmarks/.build/checkouts/WhoopDI/Sources/WhoopDIKit/Container/{Container.swift,ContainerContext.swift} /tmp/bolt-port/P2/
cp Benchmarks/.build/checkouts/swift-dependencies/Sources/Dependencies/{WithDependencies.swift,Dependency.swift} /tmp/bolt-port/P2/
```

Bolt target files:
- `Sources/Bolt/Container.swift`
- `Sources/Bolt/Bolt.swift`
- `Tests/BoltTests/ContainerScopingTests.swift`

### 3) Phase P3 file fetch (WhoopDI singleton DCL)
Reference files to fetch:
- `Benchmarks/.build/checkouts/WhoopDI/Sources/WhoopDIKit/Module/DependencyDefinition.swift`

Run:
```bash
cd /Users/michaelbattaglia/Documents/swift-bolt
mkdir -p /tmp/bolt-port/P3
cp Benchmarks/.build/checkouts/WhoopDI/Sources/WhoopDIKit/Module/DependencyDefinition.swift /tmp/bolt-port/P3/
```

Bolt target files:
- `Sources/Bolt/Container.swift`
- `Sources/Bolt/Registration.swift`
- `Tests/BoltTests/ContainerConcurrencyTests.swift`
- `Tests/BoltTests/ContainerResolutionTests.swift`

### 4) Phase P4 file fetch (Cycle path and failure-path discipline)
Reference files to inspect (diagnostic style and fast-success patterns):
- `Benchmarks/.build/checkouts/WhoopDI/Sources/WhoopDIKit/Module/DependencyDefinition.swift`
- `Benchmarks/.build/checkouts/Factory/Sources/Factory/Factory/Registrations.swift`

Run:
```bash
cd /Users/michaelbattaglia/Documents/swift-bolt
mkdir -p /tmp/bolt-port/P4
cp Benchmarks/.build/checkouts/WhoopDI/Sources/WhoopDIKit/Module/DependencyDefinition.swift /tmp/bolt-port/P4/
cp Benchmarks/.build/checkouts/Factory/Sources/Factory/Factory/Registrations.swift /tmp/bolt-port/P4/
```

Bolt target files:
- `Sources/Bolt/Container.swift`

### 5) Phase P5 file fetch (typed fast-path shaping)
Reference files to inspect:
- `Benchmarks/.build/checkouts/Factory/Sources/Factory/Factory/Registrations.swift`
- `Benchmarks/.build/checkouts/WhoopDI/Sources/WhoopDIKit/Module/DependencyDefinition.swift`

Run:
```bash
cd /Users/michaelbattaglia/Documents/swift-bolt
mkdir -p /tmp/bolt-port/P5
cp Benchmarks/.build/checkouts/Factory/Sources/Factory/Factory/Registrations.swift /tmp/bolt-port/P5/
cp Benchmarks/.build/checkouts/WhoopDI/Sources/WhoopDIKit/Module/DependencyDefinition.swift /tmp/bolt-port/P5/
```

Bolt target files:
- `Sources/Bolt/Registration.swift`
- `Sources/Bolt/Container.swift`

### 6) Mandatory per-phase validation commands
Run after each phase before commit:
```bash
cd /Users/michaelbattaglia/Documents/swift-bolt
swift test
cd Benchmarks
swift run -c release BoltBenchmarks --format json --quiet
```

Phase gate protocol:
- Capture 5 runs before and 5 runs after for the target metrics of that phase.
- If phase target metrics do not improve repeatably at median, revert phase.

## Success Criteria (Recovery)
- Tier A targets (median):
  - Wave 1: Beat current best reference in at least 2/4 categories.
  - Wave 2: No category worse than +10% vs best reference.
  - Final target: Fastest median in all 4 Tier A categories on same machine/session class.
- Tier B:
  - Maintain correctness and improve Bolt’s own baseline trend in all depth-1 metrics.
- Quality:
  - No test regressions.
  - No API/semantic regressions from README + spec guarantees.

## Risk Controls
- Keep diffs focused by move; no mixed refactors.
- Keep one benchmark artifact set per move (before/after, 5 runs each).
- Reject complexity that does not show repeatable median gains.
- Add explicit rollback rule:
  - If two consecutive phases do not improve any Tier A metric, pause implementation and redesign architecture before further tuning.

## Copy/Adapt Mapping
- WhoopDI patterns to port:
  - Child container override shadowing.
  - Per-entry singleton DCL.
- Factory patterns to port:
  - Normalized key representation.
  - Direct hashed lookup path and reduced scope overhead.
- swift-dependencies patterns to port:
  - Strict lexical/task-local override scope mechanics.
  - Scope entry composition instead of resolve-time traversal.
