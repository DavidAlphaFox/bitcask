# bitcask_cypher changelog (English)

中文版：[`CHANGELOG.md`](CHANGELOG.md). Loosely follows [Keep a Changelog](https://keepachangelog.com/).

The Cypher query layer used to live in the main bitcask application (since 13.1.0); it is now a separate application,
`bitcask_cypher`. Entries from before the split are kept below.

## [Unreleased]

### Removed

- **Neo4j extension syntax** (not in the openCypher 2024.3 grammar, TASK.md O7): `FOREACH`, `CALL { … }` subqueries (including
  `CALL (a) { … }`, `OPTIONAL CALL`, `IN TRANSACTIONS` batched commits), `COUNT { … }` / `COLLECT { … }`, `LOAD CSV` (with
  `linenumber()` / `file()` and the `cypher_import_dir` setting). These are now syntax errors; `EXISTS { … }`, bitcask's own `@@` /
  `<=>` / search functions and user procedures / functions are unaffected.

### Added

- **Syntax reference** `doc/cypher-syntax-en.md` / `doc/cypher-syntax-zh.md`: the openCypher 2024.3 syntax (clauses, patterns,
  label expressions, quantified paths, path search prefixes, expressions and precedence, functions, unsupported forms) and the syntax
  specific to bitcask (`@@`, `<=>`, search functions, `text` / `embedding`, user procedures, built-in procedures, differences from
  openCypher).
- **Aligned with the openCypher 2024.3 grammar** (TASK.md O1–O6): digit underscores, float suffixes, `INF` / `NAN` literals,
  doubled quotes and `\U` escapes, Unicode identifiers, `$0` parameters, keywords as variable names; `UNION DISTINCT`, `RETURN ALL`,
  `OFFSET`, `SET m.node.p` / `SET n['k']`, `CASE x WHEN 1, 2`, `shortestPath(…)` as an expression; `WHERE` inside element patterns;
  label expressions `IS` / `&` / `%` / parentheses; path search prefixes `ANY` / `SHORTEST k` / `ALL SHORTEST` / `SHORTEST k GROUPS`
  and so on; quantified paths `((x)-[r]->(y)){1,3}` / `+` / `*`, quantified relationships `-[:T]->{1,2}`, unquantified
  parenthesized paths and subpath variables, adjacent node patterns (TASK.md O6).

- **Cypher phase 2, first batch**: `OPTIONAL MATCH` (keeps the input row with `null` for the new variables when nothing matches);
  `MERGE` of a single node or of a single relationship between bound nodes, with `ON CREATE SET` / `ON MATCH SET` (concurrent
  identical `MERGE`s don't create duplicates); `CASE` expressions (generic and simple forms). `CASE` / `WHEN` / `THEN` / `ELSE` /
  `END` become keywords (still usable as property names and labels). See `doc/cypher-en.md` sections 4 and 5.
- **Cypher phase 2, the rest**: plain named paths and `allShortestPaths`; label expressions `:A|B` / `:!A`; `ORDER BY … NULLS FIRST
  / LAST`; regex `=~`; indexing and slicing; string functions (`substring`, `replace`, `split`, `trim`, …) and list functions
  (`head`, `tail`, `last`, `range`); `CALL db.labels()` / `db.relationshipTypes()` / `db.propertyKeys()` (`YIELD … WHERE`);
  whole-pattern `MERGE` (unbound ends, several hops). `NULLS` / `CALL` / `YIELD` become keywords. All phase-2 items of the design
  are now implemented.
- **Cypher streaming cursors**: `bitcask_cypher:cursor/2,3,4` with `fetch/2` / `columns/1` / `close/1` fetch rows of a read-only
  query in batches on demand (scans / expansions before `LIMIT` needn't run to completion); a cursor closes when its owner exits or
  after an idle timeout.
- **Cypher search functions**: `fts.phrase` / `fts.near` / `fts.wildcard` / `fts.fuzzy` / `fts.fields` and `search.hybrid`
  (full-text + vector RRF); as a `WHERE` condition they become the start of the plan and `score(n)` works.
- **Cypher aligned with openCypher syntax**: list comprehensions, quantifiers `all` / `any` / `none` / `single`, `reduce`, map
  projections, chained comparisons (`1 < x <= 3`), `exists(n.prop)`, hex / octal integers; pattern predicates (`WHERE (a)-[:T]->()`),
  `exists((a)--())`, pattern comprehensions (`[(a)-->(b) | b.name]`); `UNION` / `UNION ALL`; `CREATE p = …` / `MERGE p = …`;
  `CALL db.labels` without parentheses and `YIELD *`; math / trigonometric functions (`sqrt`, `log`, `sin`, `atan2`, …),
  `timestamp()`, aggregates `percentileCont` / `percentileDisc` / `stDev` / `stDevP`. `ALL` / `ANY` / `NONE` / `SINGLE` / `REDUCE` /
  `EXISTS` / `UNION` become keywords (still usable as property names and labels; the first six still work as variable names when
  not followed by `(`). See `doc/cypher-en.md` section 4.
- **Cypher phase 3** (`doc/cypher-phase3-design-zh.md`): `FOREACH`; `CALL { … }` subqueries (`CALL (a, b) { … }` / `CALL (*)`,
  `OPTIONAL CALL`, write-only unit subqueries, UNION bodies) and `CALL { … } IN TRANSACTIONS [OF n ROWS]` batched commits (bulk
  loads are no longer capped at 4096 vertices per statement; such a statement is no longer atomic); `EXISTS { … }` / `COUNT { … }` /
  `COLLECT { … }` subquery expressions; user procedures and functions (`bitcask_cypher:register_procedure/2`, `register_function/2`,
  `unregister/1`, `registered/0`; `CALL ns.proc(args)`, `ns.f(…)`); `LOAD CSV` (requires the `cypher_import_dir` application
  environment and only reads files below it) with `linenumber()` / `file()`; temporal and spatial types Date / LocalTime / Time /
  LocalDateTime / DateTime / Duration / Point (construction, accessors, arithmetic, comparison and ordering, `duration.between`,
  `truncate`, `point.distance`, `point.withinBBox`), storable as vertex / relationship properties and accepted / returned by the graph
  API as well (fixed offsets only, no named time zones). `FOREACH` / `TRANSACTIONS` / `LOAD` / `CSV` / `FROM` become keywords (still
  usable as property names and labels). See `doc/cypher-en.md` sections 4, 5 and 11–13.
- **openCypher TCK runner** `test/tck/`: `fetch.sh` fetches the openCypher scenarios (2024.3 by default) and
  `escript apps/bitcask_cypher/test/tck/tck.escript` runs them and writes a report (`doc/cypher-en.md` section 14). All 3880 scenarios
  currently pass.
- **Error types and detail codes**: error maps gain `type` / `detail` (openCypher's error type / detail code, e.g. `SyntaxError` /
  `VariableAlreadyBound`, `TypeError` / `InvalidArgumentValue`; new module `bitcask_cypher_error`), matching the openCypher TCK
  throughout; the TCK runner now compares them strictly (`--phase-only` compares the phase only). **Behaviour change**:
  `MATCH (n $p)` with a parameter as pattern properties is now an error (`InvalidParameterUse`, as in openCypher; `CREATE (n $p)`
  is unchanged, and `MERGE (n $p)` was already rejected).
- **Merged time zones resolve as in IANA's default build**: `Europe/Stockholm` and 141 other zones IANA merged into others use the
  merge target's data by default (as Java / Neo4j do; only pre-1970 times differ); set the application environment
  `tz_backzone = true` to use their own data from zoneinfo built with backzone.
- **No more 4096-vertex limit per updating statement**: unlimited by default; the application environment
  `cypher_max_write_vertices` sets a cap (exceeding it is an error that names the setting). Large write statements grow the executing
  process's heap automatically (doubling, restored when the statement ends), so time is roughly linear: 100,000 relationships in one
  statement went from 34 s to 11.5 s.
- **Negative years**: dates support year 0 and negative years over ±999999999 (proleptic Gregorian, written as in java.time:
  `-0044-03-15`, `+10000-01-01`).
- **Duration multiplication / division**: computed with exact fractions and nanoseconds truncated toward zero (as Neo4j does), so
  `d / 2` no longer gains a nanosecond.
- **NaN / Infinity**: floats follow IEEE 754, with the atoms `'NaN'` / `'Infinity'` / `'-Infinity'` (new module `bitcask_ieee`).
  Float overflow and float division by zero no longer raise errors; NaN comparison and ordering follow openCypher; new function
  `isNaN`; such values can be stored. **Behaviour change**: `sqrt(-1)`, `log(0)`, `acos(2)` and the like used to be `null`
  and are now `NaN` / `±Infinity`; `1.0 / 0` used to be an execution error.
- **Named time zones**: `datetime('…[Europe/Stockholm]')`, `{timezone: 'Europe/Stockholm'}` and so on, with zone data read from the
  local zoneinfo (application environment `tz_dir` > `TZDIR` > `/usr/share/zoneinfo`; new module `bitcask_tz`). A DateTime with a zone
  name keeps it (`{datetime, D, Ns, Off, Zone}`), offsets follow the date and DST rules, and such values can be stored.
- **Cypher value types**: lists of one element type can be stored as properties (`[1, 2]`, `[true]`, `[date(…)]`; graph API too);
  clock functions such as `date.statement()` / `transaction()` / `realtime()`, `truncate` overrides, the alternative
  `P2012-02-02T…` duration form; typed arguments and output-less procedures for user procedures; implicit arguments for a standalone
  `CALL p`.

### Changed

- **Cypher aligned with the openCypher TCK** (behaviour changes, see `doc/cypher-en.md` sections 4, 10, 11): integers are 64-bit and
  overflow is an error; string + number concatenates; `^` is left-associative; unaliased columns are named by the item exactly as
  written; compile-time type checks (boolean / arithmetic operands, property access on scalars, `IN`, `WHERE`, graph function
  arguments, `SKIP` / `LIMIT`, `DELETE`); `WITH … WHERE` / `ORDER BY` may use pre-projection variables (without aggregation) or simple
  expressions equal to projection items; ambiguous aggregations fail; patterns may only be predicates (`RETURN (a)-->(b)` is an error —
  use `exists(…)` / `COUNT { … }`); `YIELD *` only in a standalone CALL; `*` without an upper bound is unbounded (it used to default to
  10 hops); `*3..1` is legal (matches nothing); MERGE accepts undirected relationships; missing parameters are compile-time errors;
  times with zero seconds print as `12:00`; temporal maps with a base take missing fields from the base's representation, and a new
  `timezone` converts first.
- **Cypher: property conditions pushed down to the engine**: when the start is a label scan / full scan, the other labels, inline
  properties and WHERE conditions of the form "property compared with a constant / parameter" (`=`, `<`, `<=`, `>`, `>=`, `IN`,
  `IS NOT NULL`) go to the engine's meta filter (relaxed into necessary conditions; the original filters stay, results are unchanged);
  label scans read documents back in one range per chunk instead of one read per vertex. On 20k vertices "label + property filter"
  drops from 64–80 to 14–19 ms, grouping by a property from 67–77 to 55–59 ms. Scan operators with pushdown carry one more argument in
  `explain` (`{label_scan, V, L, #{push, fetch}}`, `{all_nodes_scan, V, Push}`).
- **Cypher: plans cached by query text** (per calling process, at most 128): text queries run almost as fast as prepared ones (one
  hop 19 → 5 µs).
- **Cypher: executor overhead**: prepared one hop 7.1–7.6 → 5.0–5.7 µs, two-hop count 22–27 → 18–21 µs (query caches created on
  demand; an `id(v)` start followed by a one-hop expansion skips the separate existence check).
- **Lighter Cypher write statements**: reads rely on version guards without read locks (see below). Compared in the same run with
  locked reads: in KV mode a `SET` found by label + property drops from 98–99 to 90 µs and a node `CREATE` from 42–46 to 36–41 µs;
  in index mode `SET` drops from 114–128 to 101–104 µs. Statement atomicity and conflict restarts are unchanged.
- **Cypher: label scans in updating statements use property indexes**: in updating statements / a caller's transaction a ready
  property index is read instead of the label index, locking that value's (for ordering comparisons, that property's) index prefix
  rather than the whole label — `MATCH (c:C {k: 1}) SET …` over 2,000 vertices drops from 6.7 to 0.13–0.17 ms. New `bitcask_txn:prefix_range/3` option `{within, {Lo, Hi}}` (locks
  the whole prefix, reads only part of it).
- **Cypher: unknown namespaced functions** (`foo.bar(…)`) are now a semantic `unknown function` error instead of a syntax error (every
  `ns.f(…)` now parses as a call, so user functions can plug in). Element variables of `UNWIND` / `FOREACH` can now be used directly
  with `SET` / `REMOVE` / `DELETE` (types are checked at run time; they used to be rejected during semantic analysis).

### Fixed

- **Cypher**: variable-length relationships expanded from the pattern's end had their relationship list reversed; the variable of
  `*1..1` wasn't a list; local variables of list comprehensions weren't bound inside pattern comprehensions; chained-comparison
  rewriting crossed parentheses (`(a AND (b > c)) = …`); `range(0, 1, -1)` returned `[0]`; overflowing float literals and non-Latin
  characters crashed the lexer.
