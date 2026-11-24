# Graph query language (Cypher subset)

中文：[`cypher-zh.md`](cypher-zh.md). **Syntax reference** (openCypher 2024.3 syntax and syntax specific to bitcask):
[`cypher-syntax-en.md`](cypher-syntax-en.md). Design and trade-offs (Chinese): [`cypher-query-design-zh.md`](cypher-query-design-zh.md).

`bitcask_cypher` provides openCypher (aligned with the 2024.3 grammar) on top of the `graphdb` graph layer, plus search syntax
specific to bitcask: `<=>` (vector distance), `@@` (full-text match) and search functions. It and the graph API (`graphdb:*`) are **two entry points to the same graph CRUD**: one data
model, one vertex id space, one label index. Vertices created through the API can be found by label from a statement, and vertices
created by a statement can be read and written by id through the API.

## 1. Quick start

```erlang
%% Full-text search needs index mode ({analyzer, _}); vector search needs {vector_dim, N}. Plain graph queries need neither.
G = graphdb:open("/data/g", [read_write, {analyzer, whitespace}, {vector_dim, 3}]),

{ok, _} = bitcask_cypher:q(G,
    "CREATE (a:Person {name: 'ann', age: 31, text: 'graph databases', embedding: [1.0, 0.0, 0.0]})"
    "-[:KNOWS {since: 2020}]->(b:Person {name: 'bob', embedding: [0.0, 1.0, 0.0]})"),

{ok, #{columns := [<<"name">>, <<"friend">>], rows := Rows}} =
    bitcask_cypher:q(G, "MATCH (a:Person {name: $n})-[:KNOWS]->(b) RETURN a.name AS name, b.name AS friend",
                     #{n => <<"ann">>}),

%% Prepared: parse and plan once
{ok, P} = bitcask_cypher:prepare(G, "MATCH (n:Person) WHERE n.age > $min RETURN n ORDER BY n.age DESC LIMIT 10"),
{ok, _} = bitcask_cypher:q(G, P, #{min => 18}).
```

A complete runnable example: [`examples/cypher_demo.escript`](../examples/cypher_demo.escript).

## 2. API

| Function | Notes |
|---|---|
| `q(HandleOrTx, Query)` / `q(HandleOrTx, Query, Params)` | Run one statement. `Query` is a binary / string or the result of `prepare/2` |
| `q(Handle, Query, Params, TxOpts)` | Same; `TxOpts` go to the transaction of an updating statement (`retries` / `timeout` / `lock_wait_timeout` / `sync` / `read_locks`, default `[{sync, no_sync}, {read_locks, guard_only}]`: reads rely on version guards without read locks, see `bitcask_txn`) |
| `prepare(Handle, Query)` | Parse + check + plan once; returns a handle that can be run repeatedly |
| `explain(Handle, Query)` | `{ok, #{ops => [Operator], columns => [Name]}}`: the plan (see section 8) |
| `writes(Query \| Prepared)` | Whether the statement has updating clauses |
| `parse(Query)` | Parse and semantic check only |
| `cursor(Handle, Query[, Params[, Opts]])` | Open a streaming cursor for a read-only query: `{ok, Cursor}`. `Opts`: `{idle_timeout, Ms}` (default 300000) |
| `fetch(Cursor, N)` | Fetch up to `N` rows: `{ok, Rows, more \| done}`; the cursor closes itself after `done` |
| `columns(Cursor)` / `close(Cursor)` | Column names; close (idempotent) |

**Streaming cursors**: a cursor is a separate process holding the lazy pipeline and the query caches; scans / expansions advance only
on `fetch` (the part before a `LIMIT` reads on demand); sorting, aggregation and `DISTINCT` still need all their input (materialized on
the first `fetch`). The cursor closes when the opening process exits or after `idle_timeout` of inactivity; later `fetch` calls return
`{error, #{message := <<"cursor_closed">>}}`. Cursors can only be opened on a handle (not inside a transaction), and not for updating
statements.

Parameters `Params :: #{binary() | atom() => Value}`: integers, floats, binaries (strings), `true` / `false`, `null` (`undefined` is
treated as `null`), lists, maps. Referenced as `$name`; temporal / spatial values (the tuples of section 11) are accepted too; a missing parameter is a compile-time
(`semantic`) error.

**Result**: `{ok, #{columns := [binary()], rows := [[Value]], stats := map()}}`

- Scalars are natural Erlang terms; strings are binaries; `null` is the atom `null`.
- Node `#{id, labels, properties}`; relationship `#{src, type, dst, rank, properties}` (`type` is the type name, or an integer for
  types without a registered name); path `#{nodes, relationships}`.
- Column names: the alias if given, otherwise the item **exactly as written** in the query (openCypher: `RETURN cOuNt( * )` names
  its column `cOuNt( * )`). Statements without
  `RETURN` have `columns` and `rows` both `[]`.
- `stats` (non-zero entries only): `nodes_created`, `nodes_deleted`, `relationships_created`, `relationships_deleted`,
  `properties_set`, `labels_added`, `labels_removed`; plus `vector_exhaustive` when vector search ran (section 6.2).

**Errors**: `{error, #{stage := parse | semantic | plan | exec, message := binary(), type => binary(), detail => binary(),
line => L, column => C}}`. `type` / `detail` are openCypher's error type and detail code (as in the TCK; module
`bitcask_cypher_error`):

| `type` | Typical `detail` |
|---|---|
| `SyntaxError` | parsing: `UnexpectedSyntax`, `InvalidNumberLiteral`, `IntegerOverflow`, `FloatingPointOverflow`, `InvalidUnicodeLiteral`, `InvalidUnicodeCharacter`, `InvalidRelationshipPattern`; semantics: `UndefinedVariable`, `VariableAlreadyBound`, `VariableTypeConflict`, `InvalidArgumentType`, `InvalidAggregation`, `NestedAggregation`, `AmbiguousAggregationExpression`, `NoExpressionAlias`, `ColumnNameConflict`, `DifferentColumnsInUnion`, `InvalidClauseComposition`, `NoSingleRelationshipType`, `RequiresDirectedRelationship`, `CreatingVarLength`, `InvalidDelete`, `InvalidParameterUse`, `NonConstantExpression`, `NegativeIntegerArgument`, `InvalidNumberOfArguments`, `InvalidArgumentPassingMode`, `UnknownFunction`, `RelationshipUniquenessViolation`, `NoVariablesInScope` |
| `ParameterMissing` | `MissingParameter` |
| `ProcedureError` | `ProcedureNotFound` (failures inside a procedure carry only the type) |
| `TypeError` | `InvalidArgumentType`, `InvalidArgumentValue`, `InvalidPropertyType`, `MapElementAccessByNonString`, `ListElementAccessByNonInteger` |
| `ArgumentError` | `InvalidArgumentType`, `InvalidArgumentValue`, `NumberOutOfRange` |
| `ArithmeticError` | `DivisionByZero`, `IntegerOverflow` |
| `EntityNotFound` | `DeletedEntityAccess` |
| `ConstraintVerificationFailed` | `DeleteConnectedNode` |
| `SemanticError` | `MergeReadOwnWrites`; type only: a disabled feature (index mode), the vertex write cap, a null endpoint, … |

Storage, file and internal errors fall outside openCypher's categories and have no `type`.

## 3. Data model

| Concept | Storage | Graph API |
|---|---|---|
| Vertex id | u64, one space per store | allocated by `create_vertex/2`; explicit with `put_vertex(G, Vid, _)` |
| Labels | `_labels` (string array) in the vertex document meta + the label index | `set_labels/3`, `remove_labels/3`, `vertices_by_label/2,3` |
| Properties | the other meta keys of the vertex document | `put_vertex(G, Vid, #{labels, props, text, vector})`, `vertex/2` |
| Body text | the text segment of the vertex document; property `text` in Cypher, the target of full-text search | `text` above |
| Vector | the vector of the vertex document; `embedding` in Cypher | `vector` above |
| Relationships | graph adjacency lists (src, etype, dst, rank) | `put_edge/5` (`props` may be a map) |
| Relationship types | name ⇄ etype id registry | `register_etype/2`; new types used by `CREATE` are registered automatically |

- Property values are null, boolean, integer (int64), float, string, temporal / spatial values, and lists whose elements all have
  one type (`[1, 2]`, `['a']`, `[true]`, `[date(…)]`; mixing integers and floats is not allowed). Maps and nested lists fail with
  "unsupported property type". Names starting with an underscore are reserved (`_labels`, `_raw`).
- **Ids**: allocation starts at 1; writes with an explicit id (`put_vertex`, `put_edge` endpoints, and their transactional versions)
  raise the high-water mark when they go past it, so later allocations never collide; the allocator also checks inside its batch that
  the id is unused, so it never overwrites existing data. Ids of deleted vertices are not reused.
- A vertex that only has an adjacency list (edges written through the API, no vertex document) is still a vertex: no labels, no
  properties. The body of a legacy plain-binary vertex document shows up as property `text`.
- Relationship properties written as a map (the API's `props => #{}` or Cypher) read back as a property map; legacy arbitrary
  binary properties show up as `_raw` (and cannot be edited from Cypher).

## 4. Syntax

The table below is an overview; the syntax form by form, and the syntax specific to bitcask, are in
[`cypher-syntax-en.md`](cypher-syntax-en.md).

| Clause / form | Supported |
|---|---|
| `MATCH` with several patterns, `WHERE` | ✅ |
| Nodes `(v:A:B {k: e})`, `(v $props)` (a parameter as the properties only in `CREATE`; in `MATCH` / `MERGE` it is `InvalidParameterUse`, as in openCypher) | ✅ |
| Relationships `-[r:T1\|T2 {k: e}]->`, `<-[]-`, `-[]-`, `-->`, `<--` | ✅ |
| Variable length `*`, `*n`, `*n..m`, `*..m`, `*n..` (no upper bound unless written; with `*1..1` the variable is still a list) | ✅ |
| `p = shortestPath((a)-[:T*..n]->(b))`, `p = allShortestPaths(…)`, `length(p)` / `nodes(p)` / `relationships(p)` | ✅ |
| Plain named paths `p = (a)-[r]->(b)<-[*1..3]-(c)` | ✅ |
| Label expressions `(n:A\|B)` (any), `(n:!A)` (not), `WHERE n:A\|B` | ✅ |
| `RETURN [DISTINCT]`, aliases, `RETURN *` | ✅ |
| `WITH` (aggregation, `DISTINCT`, `ORDER BY` / `SKIP` / `LIMIT`, `WITH … WHERE`) | ✅ |
| `ORDER BY … [ASC\|DESC] [NULLS FIRST\|LAST]`, `SKIP`, `LIMIT` (literal or parameter) | ✅ |
| `UNWIND expr AS x` | ✅ |
| `CREATE` nodes, relationships, chains, named paths `CREATE p = (…)` | ✅ |
| `SET n.p = e`, `SET n += {…}`, `SET n = {…}`, `SET n:L`; the same for relationship properties | ✅ |
| `REMOVE n.p`, `REMOVE n:L` | ✅ |
| `DELETE`, `DETACH DELETE` | ✅ |
| `OPTIONAL MATCH` (with `WHERE`) | ✅ |
| `MERGE` of a node, a relationship or a whole pattern (unbound ends, several hops), `MERGE p = (…)`, `ON CREATE SET …` / `ON MATCH SET …` | ✅ |
| `CALL db.labels()` / `db.relationshipTypes()` / `db.propertyKeys()` (parentheses optional) `[YIELD x [AS y], … [WHERE …]]`; a standalone CALL may `YIELD *` | ✅ |
| `CALL ns.proc(args…) [YIELD …]` (registered user procedures, section 12) | ✅ |
| `CASE WHEN … THEN … [ELSE …] END`, `CASE expr WHEN v THEN … END` | ✅ |
| `… UNION …`, `… UNION ALL …` | ✅ |
| `EXISTS { … }` subquery expressions | ✅ |
| Path search prefixes `p = ANY [k] / ALL SHORTEST / ANY SHORTEST / SHORTEST k / SHORTEST [k] GROUPS (…)` (grouped by start and end node, selected by length; `WHERE` filters before selection) | ✅ |
| `WHERE` inside element patterns: `(n:L WHERE n.x > 1)`, `[r:T WHERE r.w > 1]` (not on variable-length relationships) | ✅ |
| Label expressions: `:A\|B`, `:A&B`, `:!A`, `:%` (any label), parentheses, `IS A`; relationships `[r:T\|U]`, `[r IS !T]`; `WHERE n IS A` | ✅ |
| `RETURN` / `WITH ALL …`, `UNION DISTINCT`, `OFFSET n` (same as `SKIP`), `CASE x WHEN 1, 2 THEN …`, `shortestPath(…)` as an expression | ✅ |
| `SET m.node.p = …`, `SET n['k'] = …`, `REMOVE n[k]` (the target is any postfix expression, the key may be an expression) | ✅ |
| Literals and names: `1_000`, `1.5f`, `INF` / `NAN`, `'it''s'`, `\U01F600`, Unicode identifiers, `` `a``b` ``, `$0` / `` $`x` ``; keywords can be variable names | ✅ |
| Quantified paths: `(a) ((x)-[r:T]->(y)){1,3} (b)`, `+` / `*` / `{n}` / `{m,}` / `{,n}`, labels / properties / `WHERE` inside the group (checked on every repetition); `-[:T]->{1,2}`, `-->+`; unquantified parenthesized paths `((a)-[r]->(b) WHERE …)`, `(p = …)`; adjacent node patterns `(a) (b)` are the same node. Variables inside the group are lists outside it. No nesting, no variable-length relationships inside a group; not supported in expression patterns | ✅ |
| Temporal / spatial types (section 11) | ✅ |
| Neo4j extension syntax: `FOREACH`, `CALL { … }` subqueries (including `CALL (a) { … }`, `OPTIONAL CALL`, `IN TRANSACTIONS`), `COUNT { … }` / `COLLECT { … }`, `LOAD CSV` | not supported (not in the openCypher 2024.3 grammar; removed) |

Keywords are case-insensitive; property names, labels and relationship types are case-sensitive, may be keywords (`n.order`,
`:Order`) or backquoted (`` n.`weird name` ``). Comments: `//` and `/* */`.

**Expressions**: literals (integer (also hex `0x1F` and octal `0o17`), float, string, `true` / `false` / `null`, list, map);
`= <> < <= > >=` (chainable: `1 < n.x <= 3` means `1 < n.x AND n.x <= 3`); `AND OR XOR NOT`;
`+ - * / % ^`; `IN`; `IS [NOT] NULL`; `STARTS WITH` / `ENDS WITH` / `CONTAINS`; regex `=~` (matches the whole string, Erlang `re`
syntax, e.g. `(?i)` for case-insensitive); label tests `n:Label` / `n:A|B` / `n:!A`; indexing `list[i]` (negative counts from the
end, out of range gives `null`), `map['key']`, slicing `list[a..b]` (either end optional, may be negative); `v.embedding <=> q`;
`v.text @@ 'query'`; `CASE` (the generic form takes the first branch whose condition is `true`; the simple form the first branch
equal (`=` true) to the subject; otherwise `ELSE`, or `null` without `ELSE`; only the chosen branch is evaluated); list
comprehensions `[x IN list WHERE p | e]` (both `WHERE` and `| e` optional); quantifiers `all` / `any` / `none` / `single(x IN list
WHERE p)`; `reduce(acc = init, x IN list | e)`; map projections `n {.name, .*, k: e, v}` (nodes, relationships and maps);
`exists(n.prop)` (same as `IS NOT NULL`).

**Pattern expressions**: pattern predicates `WHERE (a)-[:T]->(:L)` and `exists((a)--())` (boolean: does the pattern match starting
from the current row), pattern comprehensions `[(a)-[r:T]->(b) WHERE … | b.name]`, `[p = (a)-[*]->() | length(p)]` (one value per
match). A pattern predicate may only reference bound node variables (no new variables, no relationship variables — use `OPTIONAL
MATCH` or a pattern comprehension for those); a `null` outer variable gives `null`. Patterns may only be used as **predicates**
(openCypher): in `WHERE` (including under `AND` / `OR` / `NOT`), in `exists(…)`, in the `WHERE` of comprehensions / quantifiers, and in
`CASE WHEN`; in projections or function arguments (`RETURN (a)-->(b)`, `size((a)-->())`) they are a syntax error — use
`exists((a)-->(b))` for a boolean and `size([(a)-->(b) | 1])` for a count. An expression pattern must contain a
relationship (`(a)` alone is a parenthesized expression), and a relationship starts with `-[`, `--`, `<-[` or `<--`, so `(a) - (b)`
and `(x) < -1` are still arithmetic / comparison while `(a)--(b)` and `(a)-->(b)` are patterns (whitespace doesn't matter).

**Functions**: `id`, `labels`, `type`, `properties`, `keys`, `coalesce`, `size`, `length`, `nodes`, `relationships`, `startNode`,
`endNode`, `toInteger`, `toFloat`, `toString`, `toBoolean`, `toLower`, `toUpper`, `abs`, `score`; strings: `substring(s, start[,
len])` (0-based), `replace`, `split`, `trim` / `ltrim` / `rtrim`, `left`, `right`, `reverse`; lists: `head`, `tail`, `last`,
`reverse`, `range(start, end[, step])` (end inclusive). A `null` argument gives `null`. Math: `ceil`, `floor`, `round` (float
results), `sign`, `rand()`, `sqrt`, `exp`, `log`, `log10`, `e()`, `pi()`; trigonometry: `sin`, `cos`, `tan`, `cot`, `asin`, `acos`,
`atan`, `atan2(y, x)`, `degrees`, `radians`, `haversin`; `timestamp()` (milliseconds). Results that aren't real numbers
follow IEEE 754 (as in Java / Neo4j): `sqrt(-1)` and `acos(2)` are `NaN`, `log(0)` is `-Infinity`, `exp(1000)` is `Infinity`;
`isNaN(x)` tests for NaN. Aggregates: `count(*)`, `count(x)`,
`count(DISTINCT x)`, `sum`, `avg`, `min`, `max`, `collect`, `percentileCont(x, p)` (linear interpolation), `percentileDisc(x, p)`
(nearest actual value), `stDev` (sample), `stDevP` (population); grouping is implicit (projection items without aggregates are the
grouping keys). The parts of a comprehension / quantifier / `reduce` that see the local variable can't contain aggregates (the list
part can: `reduce(t = 0, x IN collect(v) | t + x)`).

**Semantics** (openCypher):

- Three-valued logic with `null` propagation; `WHERE` keeps only `true`.
- Numbers compare by value: `1 = 1.0` is true, and 1 and 1.0 fall into the same group / distinct value. `=` between different types
  is false; `<` and friends return `null`.
- Integers are 64-bit: results out of range (`9223372036854775807 + 1`) are execution errors and out-of-range integer literals are
  compile errors. Integer division truncates (`5 / 2 = 2`); division by zero is an error. `^` is left-associative
  (`2 ^ 3 ^ 2 = 64.0`). `+` on strings concatenates, and a number added to a string is converted to text first (`'a' + 1 = 'a1'`).
  `toFloat('1e3')` / `toFloat('.5')` style numbers are accepted.
- Compile-time type checks (openCypher's `InvalidArgumentType`): operands whose static type is clearly wrong fail before execution —
  non-boolean operands of boolean operators, strings / booleans / lists in arithmetic, property access on scalars (`WITH 1 AS x RETURN
  x.p`), a non-list on the right of `IN`, a non-boolean `WHERE`, wrong argument kinds for `labels()` / `type()` / `length()` and
  friends, fractional or negative `SKIP` / `LIMIT`, `DELETE` of a scalar, and statically scalar variables used in patterns (`WITH true
  AS n MATCH (n)`). Values of unknown static type (parameters, `UNWIND` elements, …) are still checked at run time.
- `ORDER BY` uses a total order: map < node < relationship < list < path < string < boolean < number; `null` sorts last ascending
  and first descending.
- Within one `MATCH` a relationship is never matched twice; separate `MATCH` clauses are not constrained.
- `OPTIONAL MATCH`: the pattern (with its `WHERE`) is matched for each input row; when nothing matches, the input row is kept and
  the variables introduced by this clause are `null`. A `null` node expands to nothing, `SET` / `DELETE` on it does nothing, and
  `CREATE` / `MERGE` of a relationship with it is an error.
- `id(r)` is `[src, etype, dst, rank]`.
- A named path's value is `{nodes, relationships}`; the intermediate nodes of a variable-length segment come from the relationships'
  endpoints. `allShortestPaths` yields every shortest path (one row each, at most 100,000).
- By default `ORDER BY` puts `null` last ascending and first descending; `NULLS FIRST` / `NULLS LAST` override that regardless of
  direction.
- `ORDER BY` and `WITH … WHERE` after a projection: without aggregation or `DISTINCT`, variables from before the projection are visible
  too (`WITH a WHERE r IS NULL` may use an earlier `r`); with aggregation or `DISTINCT` only projected columns may be used, but **simple**
  expressions equal to a projection item (variables, property accesses) and aggregates are replaced by that column (`RETURN a.name AS n,
  count(*) AS c ORDER BY a.name + 'x'` and `ORDER BY $k + count(*)` both work). In an item containing an aggregate, the parts outside
  the aggregate must be simple grouping keys or constants (`RETURN me.age + count(*)` without projecting `me.age` on its own is an
  ambiguous aggregation and fails).
- `all` / `any` / `none` / `single` extend three-valued logic over the predicate results (e.g. `all` is `false` if any result is
  `false`, otherwise `null` if any is `null`); on an empty list `all` is true and `any` false; a `null` list gives `null`. `all` and
  the other function keywords, `reduce` and `exists` can still be variable names when not followed by `(`.
- `UNION`: each part is independent (its own variables), must end with `RETURN`, and must return the same column names in the same
  order; `UNION` removes duplicates, `UNION ALL` keeps them; the two can't be mixed in one query. Parts with updating clauses run in
  one transaction — an error in any part writes nothing.
- `CREATE p = (…)` / `MERGE p = (…)`: binds the created / found pattern to the path variable `p`. `MERGE p = …` merges the whole
  pattern.
- `EXISTS { … }` sees all outer variables and may introduce new ones (unlike pattern predicates), but can't update. The body is a
  full clause sequence (`MATCH … WHERE … RETURN …`, `UNION` allowed) or the short form "pattern [WHERE …]" (`EXISTS { (n)-->() }`);
  the value says whether there is any row.
- `CALL`: a lone `CALL p()` returns all of the procedure's columns (`YIELD *` allowed; `CALL p` without parentheses takes its
  arguments from the query parameters of the same names); with further clauses specific columns must be `YIELD`ed (`YIELD *` only in
  a standalone CALL). A procedure without outputs (void) can be followed directly by other clauses and doesn't change the rows. `db.labels()` lists
  labels that have at least one vertex, `db.relationshipTypes()` the registered relationship types, `db.propertyKeys()` the property
  names found by scanning all vertex documents (slow on large stores).

## 5. Writes

- **One updating statement is one transaction**: the whole statement runs in a `bitcask_txn` transaction — vertices and adjacency
  lists it reads are locked and version-guarded, writes are buffered and committed as one atomic batch. On conflicts with other
  writers (statements or graph API calls) the transaction layer reruns the statement (`retries` in `TxOpts`, default as in
  `bitcask_txn`). If the statement fails nothing is written.
- **Reads before writes**: an updating clause first computes all of its input rows, then applies the changes.
- **Joining a caller's transaction**: inside `graphdb:transaction(G, fun(Tx) -> … end)`, pass `Tx` as the first argument of `q`; the
  statement sees earlier writes of the same transaction and can be mixed with `graphdb:*_txn`. A failing statement aborts the whole
  transaction with `{aborted, {cypher, Error}}`.
- `CREATE (a)-[:T]->(b)`: when a relationship of the same type already connects the two nodes, the new one gets the next `rank`. The id
  of a deleted relationship is never given to a new one (Cypher deletes record the pair's rank high-water mark and creation searches
  upward from it; deletes through the graph API's `del_edge` don't record it). New relationship types are registered before the statement starts (and stay registered if it fails).
- Referring to an already bound node in `CREATE` only connects to it; you cannot add labels / properties there (use `SET`).
- `SET x.p = null` / `REMOVE x.p` delete a property; `SET n = {…}` replaces all properties and the body text (labels and the vector
  stay unless the map has `embedding`); `SET` on `null` does nothing. `n.text` and `n.embedding` write the body text and the vector.
- `DELETE n` fails while the node still has relationships (use `DETACH DELETE`). `DELETE r, n` in one statement deletes the
  relationship first.
- `MERGE`: for each input row, look the pattern up; every match yields a row (with `ON MATCH SET` applied); if there is none, create
  the pattern once (with `ON CREATE SET` applied).
  - Whole patterns: `MERGE (a:X {k: 1})-[:T]->(b:Y {k: 2})`, several hops, a bound start with an unbound end all work. **If the whole
    pattern doesn't match, the whole pattern is created** — even if an end already exists on its own (openCypher semantics); to
    connect existing ends, `MATCH` / `MERGE` the ends first, then `MERGE` the relationship between bound nodes.
  - Nodes: `MERGE (v:A:B {k: e})` needs all labels and every property equal (`1` equals `1.0`); without labels it searches all
    vertices. Property values cannot be `null`, `embedding` cannot be matched, and the variable must not be bound already.
  - Relationships: `MERGE (a)-[r:T {k: e}]->(b)` needs both ends to be bound nodes (no labels / properties on them), a direction, one
    type and no variable length. It looks for a relationship of that type with matching properties between a and b;
    `(b)<-[:T]-(a)` and `(a)-[:T]->(b)` are the same relationship.
  - Concurrency: the lookup by label takes the label index's prefix read lock, so two concurrent `MERGE`s don't both create (the
    conflicting one reruns and sees the other's node). A node `MERGE` without labels locks all vertices; give it a label under
    high concurrency.
- An updating statement may write any number of vertices by default (the whole statement is one transaction committed as one atomic
  batch; large writes grow the executing process's heap automatically, so time grows roughly linearly: 100,000 relationships plus
  200,000 vertices in one statement take about 11 s). The application environment `{bitcask_cypher, [{cypher_max_write_vertices, N}]}`
  sets a cap; exceeding it is an error. For bulk loads, splitting the work into several statements (small transactions, cheap retries)
  or the graph layer's bulk APIs such as `graphdb:put_edges/2` are recommended.

## 6. Search

### 6.1 Full text `@@`

`WHERE n.text @@ 'query'` matches the vertex body text (the store must be opened in index mode). Query string syntax:

| Form | Meaning |
|---|---|
| `graph vector` | both words must appear |
| `graph OR vector` | either (upper-case `OR`, binds tighter than juxtaposition: `a OR b c` = (a or b) and c) |
| `-cooking` | exclude |
| `"graph database"` | phrase |
| `graph*` | prefix |
| `graphs~` | fuzzy (edit distance 1) |

- `score(n)`: BM25 score; with several terms it is the sum of the terms' scores (`OR` takes the larger). Rows that did not go
  through a full-text match have `null`.
- When the whole `WHERE` contains this conjunct it is the starting point (search first, then expand / filter); on a vertex reached by
  expansion it filters row by row (each query string is searched once per query).
- Only `n.text` is supported; search reads the engine and does not see uncommitted writes of the same transaction.

### 6.2 Vector `<=>`

`v.embedding <=> q`: `q` is a list of numbers or an f32 little-endian binary; the value is **the negated engine similarity score**,
smaller is closer — negative inner product under cosine / dot, squared distance under L2. `null` when the vertex has no vector. Two
forms use the vector index:

- `MATCH (n[:L] …) [WHERE …] RETURN … ORDER BY n.embedding <=> $q LIMIT k` (no aggregation, no DISTINCT): a vector top-k search
  is the starting point. The other conditions are checked on its results and the search widens automatically when fewer than k
  pass; if it still falls short at the cap, `stats` has `vector_exhaustive => false`.
- `WHERE n.embedding <=> $q < t` (or `<=`): candidates by threshold.

The first label is pushed down to the engine as a meta filter. Other forms (candidates from a graph pattern, e.g.
`MATCH (a)-[:R]->(b) … ORDER BY b.embedding <=> $q`) compute exact distances over the candidates (one `bitcask:vector_rank/4`
call). Requires `{vector_dim, N}`.

### 6.3 Function forms (other full-text forms, hybrid search)

| Function | Engine call |
|---|---|
| `fts.phrase(n.text, 'a phrase')` | `search_phrase` |
| `fts.near(n.text, 'a b', slop)` | `search_near` (at most `slop` words apart) |
| `fts.wildcard(n.text, 'gr*h')` | `search_wildcard` |
| `fts.fuzzy(n.text, 'word'[, edits])` | `search_fuzzy` (default 1, at most 2) |
| `fts.fields(n, 'title:x body:y')` | `search_fields` (query syntax over named fields) |
| `search.hybrid(n, 'text', $vector[, k])` | `search_hybrid` (RRF fusion of full-text and vector, top k, default 10) |

They work like `@@`: as a `WHERE` conjunct they are the starting point (`search_seek` in `explain`), rows come in descending score
order and `score(n)` is the engine's score; elsewhere they test whether the vertex is a hit (the hit set is cached per arguments
within a query). A `null` argument means no hit.

## 7. Mixing with the graph API

```erlang
{ok, V} = graphdb:create_vertex(G, #{labels => [<<"Doc">>], props => #{title => <<"x">>}}),
{ok, #{rows := [[<<"x">>]]}} = bitcask_cypher:q(G, "MATCH (d:Doc) WHERE id(d) = $v RETURN d.title", #{v => V}),
ok = graphdb:put_edge(G, V, T, 42, #{props => #{w => 0.5}}),       %% r.w = 0.5 in a statement
{atomic, _} = graphdb:transaction(G, fun(Tx) ->
    {ok, _} = bitcask_cypher:q(Tx, "MATCH (d:Doc) SET d.seen = true"),
    graphdb:put_edge_txn(Tx, V, T, 43)
end).
```

## 8. Planning and `explain`

There are no statistics; the rules are fixed. Each connected pattern gets one starting point: an already bound variable >
`id(v) = …` / `id(v) IN …` > an `@@` conjunct > vector (the two forms above) > a label (label index scan) > a full scan (vertex
documents ∪ adjacency heads; slow on large graphs, shows as `all_nodes_scan` in `explain`). From the start the pattern is expanded
hop by hop, "expand into" when the other end is already bound; `WHERE` is split into conjuncts applied as soon as their variables are
bound. Execution is lazy: scans before a `LIMIT` stop once enough rows are produced.

**Pushdown**: when the start is a label scan or a full scan, the node's other labels, inline properties and `WHERE` conditions of the
form "property compared with a constant / parameter" (`=`, `<`, `<=`, `>`, `>=`, `IN`, `IS NOT NULL`) go to the engine's meta filter.
What the engine gets is a relaxed necessary condition (both the `1` and `1.0` spellings, cross-type ordering with the equal sign;
string ordering, `IS NULL`, conditions with variables on both sides and `text` / `embedding` are not pushed down), and the original
filters still run in Erlang — pushdown only reads less, results do not change. Label scans work in chunks of 256 vertices; when the
ids are dense enough the chunk is read back with its documents in one range, so later property accesses do not read vertices one by
one. In `explain`, scans with pushdown show as `{label_scan, V, Label, #{push => Conditions, fetch => FetchDocs}}` and
`{all_nodes_scan, V, Conditions}`.

An `id(v) = …` start followed by a one-hop expansion from v (`{node_by_id, V, E, nocheck}`) skips the separate existence check: a
vertex without edges simply yields no rows in the expansion.

**Property indexes**: `graphdb:create_index(G, Label, Prop)` declares a (label, property) index, builds it from the existing data
right away, and from then on every write that changes a vertex (graph API and Cypher, direct writes and transactions) maintains it
in the same batch; `graphdb:drop_index/3` removes it, `graphdb:indexes/1` lists them (`building` / `ready`). Only scalar values are
indexed; `text` / `embedding` cannot be indexed. At run time a label-scan start checks whether one of its pushed-down conditions has a
ready index and uses it if so (equality > `IN` > ordering; both integer and float spellings of a number), the original filters still
apply and results do not change. Plans do not depend on data, so `explain` still shows `label_scan`. With 20k vertices and about 200
per value, `MATCH (n:L) WHERE n.k = 7` drops from about 11.7 ms to about 0.5 ms. Inside a transaction (write statements, or a
statement run in the caller's transaction) label scans switch to a ready property index too, locking that value's index prefix (the
property's prefix for ordering comparisons) — narrower than locking the whole label (a write `MATCH (c:C {k: 1}) SET …` over 2,000
vertices drops from 6.7 ms to about 0.14 ms); without a usable index they still scan the label index under a prefix read lock
(phantom protection) and push nothing down.

Parse and plan results are cached by query text in the calling process (at most 128 entries), so a text query runs almost as fast as
a `prepare/2`d one.

Operators returned by `explain`: `node_by_id`, `label_scan`, `all_nodes_scan`, `fts_seek`, `vector_topk`, `vector_range`,
`node_check`, `expand`, `var_expand`, `rel_check`, `shortest_path`, `all_shortest_paths`, `build_path`, `optional`, `search_seek`,
`call_proc`, `filter`, `unwind`, `project`, `aggregate`, `distinct`, `sort`, `skip`, `limit`, `select`, `create`, `set`, `remove`,
`delete`, `merge_node`, `merge_rel`, `merge_pattern`, `qpp_expand` (quantified paths), `tag_rows` / `path_select` / `drop_vars`
(path search prefixes).

## 9. Performance

`test/cypher_bench` (20k vertices / 100k edges, power-law degrees, with labels, properties, body text and 8-dimensional vectors;
local machine, µs per operation):

| Operation | Fresh writes | After reopen |
|---|---|---|
| One hop: `graphdb:out_edges` / Cypher prepared / Cypher text | 2.0 / 5.0 / 5.1 | 2.1 / 5.4 / 5.7 |
| Two-hop count (prepared) | 18.2 | 20.1 |
| One hop + property filter on neighbours | 15.2 | 16.0 |
| `shortestPath` (prepared) / `graphdb:shortest_path` | 184 / 154 | 252 / 221 |
| Vector top-10 (`ORDER BY <=> LIMIT`) / `bitcask:search_vector` | 52 / 21 | 49 / 20 |
| Neighbours ranked by vector (graph + `<=>`) | 23.4 | 24.0 |
| Full-text `@@` (all hits, per query) | 3758 | 3663 |
| Scan all `Person` + property filter / count per property (per query) | 19 ms / 59 ms | 14 ms / 55 ms |

| Write | µs per operation |
|---|---|
| `graphdb:create_vertex` (with body text and vector) | 37 |
| `CREATE` one vertex (one statement, with body text and vector) | 182 |
| `UNWIND $rows CREATE` (1000 per statement, per vertex) | 45 |
| `graphdb:put_edges` (per edge) | 13 |
| `SET` one property (one statement) | 37 |
| `CREATE` one relationship between existing nodes / `graphdb:put_edge` | 66 / 32 |
| `DETACH DELETE` one vertex | 300 |

Updating statements carry the fixed cost of a transaction (write locks, guards, commit; reads take no locks), so single writes are one
to two times slower than the graph API; use `UNWIND` or the graph layer's bulk APIs for bulk writes.

## 10. Known limitations

- There are no statistics; starting points follow fixed rules. Aggregating full scans (when no condition can be pushed down) still
  cost about 1.4 µs of executor work per row.
- Full-text / vector search inside an updating statement reads the engine and does not see uncommitted writes of the same transaction.
- Time: years range over ±999999999 (proleptic Gregorian, year 0 and negative years included: `date('-0044-03-15')`; in text, negative
  years have at least 4 digits and positive years over 4 digits get a `+`, as in java.time). Duration multiplication and division use
  exact fractions and truncate nanoseconds toward zero (as Neo4j does). Named time zones
  come from the local zoneinfo, so very old historical offsets depend on the system's tzdata version. Zones that IANA merged into
  others (`Europe/Stockholm` into `Europe/Berlin` and 141 more) use the merge target's data by default, as IANA's default build and
  Java / Neo4j do; zoneinfo built with backzone (Debian and others) keeps their own pre-1970 data, which the application environment
  `tz_backzone = true` selects (the two agree from 1970 on). Machines without zoneinfo (Windows) need `tz_dir` configured, or only
  fixed offsets work.
- **NaN / Infinity**: Erlang floats can't represent them, so results and parameters use the atoms `'NaN'`, `'Infinity'` and
  `'-Infinity'`. Float arithmetic follows IEEE 754: overflow gives infinity (`1e308 * 10`), float division by zero gives infinity or
  NaN (`1.0 / 0`, `0.0 / 0.0`; integer division by integer zero is still an error). NaN equals nothing (itself included), compares
  `false` with numbers and `null` with other types; ordering is `-Infinity` < finite numbers < `Infinity` < `NaN` < `null`. `toString`
  gives `'NaN'` / `'Infinity'` / `'-Infinity'`, `toFloat` accepts those spellings, `toInteger` gives `null`. They can be stored as
  properties (text + `_types`), in lists too.
- Conditions on temporal / spatial values are not pushed down and don't use property indexes (results are right, just not faster).

## 11. Temporal and spatial types

| Type | Construction | Erlang value in results |
|---|---|---|
| `Date` | `date()`, `date('2024-05-01')`, `date({year: 2024, month: 5, day: 1})` | `{date, {Y, M, D}}` |
| `LocalTime` | `localtime()`, `localtime('12:30:15.5')`, `localtime({hour: 12, minute: 30})` | `{localtime, NanosOfDay}` |
| `Time` | `time()`, `time('12:30+01:00')`, `time({hour: 12, timezone: '+01:00'})` | `{time, NanosOfDay, OffsetSeconds}` |
| `LocalDateTime` | `localdatetime()`, `localdatetime('2024-05-01T12:30')` | `{localdatetime, {Y, M, D}, NanosOfDay}` |
| `DateTime` | `datetime()`, `datetime('2024-05-01T12:30Z')`, `datetime('2024-05-01T12:30[Europe/Berlin]')`, `datetime({epochSeconds: 0})`, `datetime.fromepochmillis(ms)` | `{datetime, {Y, M, D}, NanosOfDay, OffsetSeconds}`; named zones `{datetime, {Y, M, D}, NanosOfDay, OffsetSeconds, ZoneName}` |
| `Duration` | `duration('P1Y2M3DT4H5M6.5S')`, `duration({days: 3, hours: 4})`, `duration.between(a, b)` | `{duration, Months, Days, Seconds, Nanos}` |
| `Point` | `point({x: 1, y: 2[, z: 3]})`, `point({longitude: 13.4, latitude: 52.5[, height: 30]})` | `{point, Srid, X, Y[, Z]}` |

- Strings are ISO 8601 — dates `2024-05-01` / `20240501` / `2024-05` / `2024` / week dates `2024-W18-3` / ordinal dates `2024-122`;
  times `HH:MM[:SS[.f]]` or the compact form, followed by `Z` / `±hh:mm`. Maps: dates take `year` plus `month` / `day`, `week` /
  `dayOfWeek`, `ordinalDay`, or `quarter` / `dayOfQuarter`; times take `hour` / `minute` / `second` / `millisecond` / `microsecond` /
  `nanosecond`; `timezone`; a `date` / `time` / `datetime` key provides a base temporal value that the other keys override —
  missing fields come from the base in the representation being used (`{date: d, week: 2}` keeps `d`'s week year and weekday,
  `{date: d, quarter: 3}` keeps its day of quarter), `nanosecond` alone keeps the base's milli / microseconds, and a new `timezone`
  on a base with an offset first converts the base to that zone (same instant) before the other fields apply. Conversions:
  `date(dt)`, `localtime(dt)`, `datetime(localdatetime)` (offset UTC). Durations also accept the alternative
  `P2012-02-02T14:37:21.545` form.
- **Time zones**: fixed offsets (`Z`, `+01:00`, `+01:00:30`) or IANA names (`Europe/Stockholm`, `'…T12:00[Europe/Stockholm]'`,
  `{timezone: 'Europe/Stockholm'}`). Zone data is read from the local zoneinfo: application environment `bitcask_cypher.tz_dir` > environment
  variable `TZDIR` > `/usr/share/zoneinfo` (TZif files; years after the last transition follow the file's trailing POSIX rule), cached
  per zone. A DateTime with a zone name keeps it and prints as `2024-05-01T12:00+02:00[Europe/Stockholm]`; `.timezone` is the name and
  `.offset` the offset in effect. Offsets are resolved per date — in the autumn overlap an offset written in the string wins, otherwise
  the earlier (summer) one; in the spring gap the time moves forward by the gap (as java.time does). Adding a Duration adds months /
  days on the local calendar (re-resolving the offset) and the seconds part on the instant. In `duration.between`, a value without an
  offset paired with a zoned one is interpreted in that zone (on the day DST ends, 00:00 to 04:00 is 5 hours). Times don't keep zone
  names: `time({…, timezone: 'Europe/Stockholm'})` uses the zone's offset today (or on the given date).
- Output text matches Neo4j / openCypher: when seconds and fraction are both zero, times stop at minutes (`12:00`,
  `2024-05-01T08:30Z`); otherwise seconds are written and the fraction loses trailing zeros.
- The argument-less `date()` / `datetime()` etc. use the **statement clock** (UTC): every call within one statement returns the same
  instant. `date.statement()` / `date.transaction()` are the statement clock too and `date.realtime()` is the real current time (same
  for the other types; an offset argument is accepted).
- Accessors: `.year .quarter .month .week .weekYear .day .ordinalDay .dayOfWeek .dayOfQuarter .hour .minute .second .millisecond
  .microsecond .nanosecond .timezone .offset .offsetMinutes .offsetSeconds .epochSeconds .epochMillis` (as applicable); Duration:
  `.years .quarters .months .weeks .days .hours .minutes .seconds .milliseconds .microseconds .nanoseconds` plus `.monthsOfYear
  .daysOfWeek .minutesOfHour .secondsOfMinute .millisecondsOfSecond` and friends; Point: `.x .y .z .longitude .latitude .height .srid
  .crs`.
- Arithmetic: temporal ± Duration (months first — clamping the day to the month's end — then days, then seconds with day carry; types
  without a date only add the seconds part, modulo one day); Duration ± Duration; Duration × / ÷ number (fractional months cascade at
  30.436875 days, fractional days at 86400 seconds). `duration.between(a, b)` gives months + days + seconds; `duration.inMonths` /
  `inDays` / `inSeconds` use a single unit. `date.truncate('month', d[, overrides])` and friends (units `millennium` … `microsecond`; a
  `timezone` in the overrides only relabels, it doesn't convert). For Date ± Duration only the whole days of the duration's seconds
  part are used (truncated toward zero).
- Comparison: only within one type; `DateTime` / `Time` compare by instant (the same instant at different offsets is equal);
  `Duration` and `Point` only support equality (`P1D` ≠ `PT24H`); `=` across types is false, `<` is `null`. Position in the
  `ORDER BY` total order: path < Point < DateTime < LocalDateTime < Date < Time < LocalTime < Duration < string.
- Spatial: `point.distance(a, b)` (also `distance`) — Euclidean for Cartesian points, great-circle metres for WGS-84 (3D adds the
  height difference), `null` across coordinate systems; `point.withinBBox(p, lowerLeft, upperRight)` (for WGS-84 a lower-left
  longitude greater than the upper-right one means the box crosses the date line).
- Storage: usable as vertex / relationship properties (also as lists of one temporal / spatial type) and read back with their type. The graph API
  (`graphdb:create_vertex/2` etc.) accepts and returns the same tuples. On disk they are canonical text plus a reserved `_types` key
  recording the types (keys starting with `_` are reserved and never show up as properties).
- Parameters can be these tuples directly; `bitcask_cypher_temporal:format/1` renders a value as ISO 8601 / `point({…})` text.

## 12. User procedures and functions

Register them from Erlang (node-wide; registering / unregistering invalidates every process's plan cache):

```erlang
ok = bitcask_cypher:register_procedure(<<"my.range">>, #{
         args    => [<<"n">>, {<<"step">>, 1}],          %% {Name, Default} arguments are optional and come last
         outputs => [<<"i">>, <<"sq">>],
         mode    => read,                                 %% read | write
         fn      => fun(_Ctx, [N, Step]) -> [#{i => I, sq => I * I} || I <- lists:seq(1, N, Step)] end}),
ok = bitcask_cypher:register_function(<<"my.slug">>, #{arity => 1, fn => fun(_Ctx, [S]) -> slug(S) end}),
bitcask_cypher:registered(),          %% #{procedures => [...], functions => [...]}
ok = bitcask_cypher:unregister(<<"my.slug">>).
```

```cypher
CALL my.range(3)                                      // alone: returns all output columns
UNWIND [2, 3] AS n CALL my.range(n) YIELD i, sq RETURN n, sum(sq)
RETURN my.slug('Hello World')
```

- Arguments may also be `#{name => <<"n">>, type => integer | float | number | string | boolean | any, default => D}`: typed arguments
  are checked against literals at compile time (`CALL my.range('x')` is a type error). `outputs => []` declares a procedure without
  outputs: called alone it returns no columns and no rows; in the middle of a query it needs no `YIELD` and keeps the rows.
- Names need a namespace (`a.b`, `a.b.c`), are case-insensitive, and can't use the built-in namespaces (`db`, `fts`, `search`, `date`,
  `time`, `localtime`, `datetime`, `localdatetime`, `duration`, `point`).
- `fn(Ctx, Args)`: `Ctx = #{handle => H, txn => Tx | undefined, params => Params}`. Arguments are evaluated Cypher values — nodes are
  `{node, Id}`, scalars / lists / maps as is, temporal values as in section 11. A procedure returns a list of maps (keys are output
  names, binaries or atoms; missing ones are `null`) or a lazy stream `fun() -> done | {Row, Next}`; a function returns one value.
  User functions are called even with `null` arguments (they decide what to do).
- Inside a transaction a `read` procedure's handle is the transaction's underlying handle and reads / writes through it are **not**
  protected by 2PL; use `graphdb:*_txn(Tx, …)` to work in the statement's transaction. A `write` procedure makes the statement an
  updating statement (one transaction, rolled back as a whole on error); its writes must go through `Tx`.
- Errors raised by a procedure / function become execution errors (`procedure my.x failed: …`); the transaction layer's conflict
  restart signals pass through untouched.

## 13. openCypher TCK

The repository includes a runner for the official openCypher conformance suite (TCK, Gherkin scenarios):

```sh
apps/bitcask_cypher/test/tck/fetch.sh                 # fetch the openCypher 2024.3 scenarios into _build/tck/ (not committed)
rebar3 compile
escript apps/bitcask_cypher/test/tck/tck.escript      # [--filter substring] [--jobs N]; report in _build/tck/report.txt
```

Each scenario runs on a fresh graph and checks results (integers vs floats distinguished; nodes / relationships / paths compared by
labels, type, properties and direction; temporal values by the TCK's text form), side effects (the difference between graph states
before and after: nodes, relationships, the set of label names, property triples) and errors. Scenarios expecting an error
must match the phase (compile time = parse / semantic / plan, run time = execution), the error type and the detail code
(`SyntaxError: VariableAlreadyBound`, …); `--phase-only` compares the phase only (the old rule).

Current result (2024.3, 3880 scenarios): **all 3880 passed (100%)**, with type and detail code matched in all 695 error scenarios.

