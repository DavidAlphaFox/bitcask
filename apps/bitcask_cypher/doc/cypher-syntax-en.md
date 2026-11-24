# Graph query syntax reference

中文：[`cypher-syntax-zh.md`](cypher-syntax-zh.md). For the API, data model, write semantics, planning and performance see the guide
[`cypher-en.md`](cypher-en.md).

`bitcask_cypher` follows **openCypher 2024.3**: all 220 per-production probes of the repository's `grammar/openCypher.bnf` pass,
and so does the TCK of the same release (3880 scenarios, error types and detail codes included). Part 1 below is the openCypher
syntax; Part 2 is the **syntax specific to bitcask** (search operators, search functions, special properties, user procedures, …).

Notation: `[ ]` optional, `{ a | b }` one of, `…` repeatable; `UPPERCASE` are keywords (case-insensitive); lowercase words are
placeholders.

---

# Part 1: openCypher syntax

## 1. Statements

```
statement ::= query { UNION [ ALL | DISTINCT ] query }… [ ; ]
           |  CALL procedure [ ( arg, … ) ] [ YIELD { column [ AS name ], … | * } ]   -- standalone procedure call
query     ::= clause…                      -- ends with RETURN, or with an updating clause (no rows)
```

- `UNION` removes duplicates (same as `UNION DISTINCT`), `UNION ALL` keeps them; the parts are independent and return the same
  column names in the same order; the two can't be mixed.
- Comments: `// to end of line`, `/* … */`.

## 2. Reading clauses

| Clause | Syntax |
|---|---|
| Match | `MATCH pattern, … [ WHERE condition ]` |
| Optional match | `OPTIONAL MATCH pattern, … [ WHERE condition ]` (no match keeps the input row with the new variables `null`) |
| Unwind | `UNWIND expression AS name` |
| Projection / chaining | `WITH [ DISTINCT \| ALL ] item, … [ ORDER BY … ] [ SKIP \| OFFSET n ] [ LIMIT n ] [ WHERE condition ]` |
| Return | `RETURN [ DISTINCT \| ALL ] item, … [ ORDER BY … ] [ SKIP \| OFFSET n ] [ LIMIT n ]` |
| Procedure call | `CALL procedure [ ( arg, … ) ] [ YIELD column [ AS name ], … [ WHERE condition ] ]` |

- Projection item: `expression [ AS name ]`, or `*` (all variables, optionally followed by `, item…`). Without an alias the column
  name is the expression as written in the query.
- `ORDER BY expression [ ASC | ASCENDING | DESC | DESCENDING ], …`; `SKIP` / `OFFSET` / `LIMIT` take a non-negative integer literal,
  a parameter or a constant expression.
- Grouping is implicit: projection items without aggregates are the grouping keys.
- Procedure calls in the middle of a query must `YIELD` specific columns (`YIELD *` only in a standalone CALL); a standalone CALL
  without parentheses takes its arguments from the query parameters of the same names.

## 3. Updating clauses

| Clause | Syntax |
|---|---|
| Create | `CREATE pattern, …` (relationships directed with exactly one type; `CREATE p = (…)` allowed) |
| Merge | `MERGE pattern [ ON CREATE SET item, … ] [ ON MATCH SET item, … ]` |
| Set | `SET item, …`: `target.property = value`, `target[key] = value`, `variable = {map}`, `variable += {map}`, `variable:Label:…` |
| Remove | `REMOVE item, …`: `target.property`, `target[key]`, `variable:Label:…` |
| Delete | `[ DETACH ] DELETE expression, …` (nodes, relationships or paths) |

- The target of `SET` / `REMOVE` is any postfix expression: `n.p`, `(n).p`, `m.node.p` (`m.node` is a node), `n['p']`, `n[$k]`
  (the key is a string).
- `CREATE (n $props)`: a parameter as the property map only in `CREATE`.
- Labels written by updating clauses are plain names, not label expressions.

## 4. Patterns

```
pattern   ::= [ path_variable = ] [ path_search_prefix ] path_term
path_term ::= element …                   -- nodes, relationships, quantified relationships, parenthesized paths / groups
```

### 4.1 Nodes

`( [ variable ] [ labels ] [ {property: value, …} | WHERE condition ] )`

- `()`, `(n)`, `(:Person)`, `(n:Person {name: 'ann'})`, `(n:Person WHERE n.age > 30)`.
- Two adjacent node patterns are the same node: in `(a) (b)` both `a` and `b` are bound to one node.

### 4.2 Relationships

| Direction | Syntax (`[…]` optional; without it any relationship) |
|---|---|
| Right | `-[…]->`, `-->` |
| Left | `<-[…]-`, `<--` |
| Either | `-[…]-`, `--`, `<-[…]->`, `<-->` |

`[ [ variable ] [ types ] [ * length ] [ {property: value, …} | WHERE condition ] ]`

- Types: `:T`, `:T|U`, `:T|:U` (old form), or a label expression (4.3).
- Variable length: `*` (one hop up, unbounded), `*n`, `*n..m`, `*..m`, `*n..`, `*0..1`; a variable-length relationship's variable
  is a list of relationships.
- No `WHERE` inside a variable-length relationship (write it after the pattern).

### 4.3 Label expressions

After `:` or `IS` in node / relationship patterns, and in `WHERE n:…` / `WHERE n IS …`:

| Syntax | Meaning |
|---|---|
| `:A`, `IS A` | has label A (relationships: type is A) |
| `:A:B` | has both (old form) |
| `:A\|B` | either |
| `:A&B` | both |
| `:!A` | not A |
| `:%` | has some label |
| `:(A\|B)&!C` | grouping; `!` binds tighter than `&`, which binds tighter than `\|` |

### 4.4 Parenthesized and quantified paths

```
parenthesized_path ::= ( [ subpath_variable = ] path_term [ WHERE condition ] ) [ quantifier ]
quantified_rel     ::= relationship_pattern quantifier
quantifier         ::= *  |  +  |  {n}  |  {m,n}  |  {m,}  |  {,n}         -- * = {0,}, + = {1,}
```

- `(a:Person) ((x)-[r:KNOWS]->(y)){1,3} (b)`: the group repeats 1 to 3 times, consecutive repetitions joined end to start; `a` is
  the first repetition's `x` and `b` the last one's `y`. Labels, properties and `WHERE` inside the group must hold on every
  repetition; variables inside the group are lists outside it (`[n IN x | n.name]`, `size(r)`).
- `-[:KNOWS]->{1,3}`, `-->+`: quantified relationships (without a `WHERE` inside they are variable-length relationships `*1..3`).
- An unquantified `((a)-[r]->(b) WHERE r.w > 1)` is the same as putting the condition in `WHERE`; a whole pattern `(p = …)` is
  the same as `p = …`.
- Limits: no nested groups; no variable-length relationships inside a group; at least one relationship; subpath variables only on
  a whole pattern; quantified groups aren't supported in expression patterns.

### 4.5 Path search prefixes

Written after the path variable: `MATCH p = SHORTEST 2 (a)-[*]->(b)`.

| Prefix | Selection per (start, end) pair |
|---|---|
| `ALL [PATH\|PATHS]` | all (the default) |
| `ANY [k] [PATH\|PATHS]` | any k paths (default 1) |
| `ANY SHORTEST [PATH\|PATHS]` | one shortest path |
| `ALL SHORTEST [PATH\|PATHS]` | all shortest paths |
| `SHORTEST k [PATH\|PATHS]` | the k shortest paths |
| `SHORTEST [k] [PATH\|PATHS] {GROUP\|GROUPS}` | all paths whose length is among the k smallest |

`k` is an integer literal or a parameter. `WHERE` filters before selection (as in Neo4j). The old forms
`shortestPath((a)-[*]-(b))` / `allShortestPaths(…)` are accepted too, also as expressions
(`RETURN length(shortestPath((a)-[*]-(b)))`).

## 5. Expressions

### 5.1 Literals

| Kind | Syntax |
|---|---|
| Integers | `42`, `-7`, `1_000_000`, `0x1F`, `0X_1f`, `0o17` (64-bit; out of range is a compile error) |
| Floats | `1.5`, `.5`, `1e3`, `1.5e-3`, `1_0.5`, suffixes `1.5f` / `2.5d`; `INF`, `INFINITY`, `-INF`, `NAN` |
| Strings | `'…'` or `"…"`; escapes `\\ \' \" \` \t \b \n \r \f \uXXXX \UXXXXXX`; a doubled quote stands for one (`'it''s'`) |
| Others | `true` / `false`, `null`, lists `[1, 'a', null]`, maps `{k: 1, name: 'a'}` (keys may be backtick names) |

### 5.2 Names and parameters

- Names start with a letter or `_` (Unicode letters too: `ñ`, `名字`), or are backtick-quoted `` `any text` `` (`` `a``b` `` is
  ``a`b``).
- Keywords aren't reserved: they can be variable names (`AS order`, `MATCH (match)`), property names, labels and map keys.
- Parameters: `$name`, `$0`, `` $`with spaces` ``.

### 5.3 Operators (lowest precedence first)

| Level | Operators |
|---|---|
| 1 | `OR` |
| 2 | `XOR` |
| 3 | `AND` |
| 4 | `NOT` |
| 5 | `=` `<>` `<` `<=` `>` `>=` `=~` (chainable: `1 < x <= 3`) |
| 6 | `IN`, `STARTS WITH`, `ENDS WITH`, `CONTAINS`, `IS [NOT] NULL` |
| 7 | `+` `-` |
| 8 | `*` `/` `%` |
| 9 | `^` (left-associative) |
| 10 | unary `+` `-` |
| 11 | `.property`, `[index]`, `[a..b]` slicing |

- Label tests `n:A`, `n IS A` (the label expressions of 4.3) are atoms and bind tighter than every operator:
  `n IS A = true` is `(n IS A) = true`.
- `=~` matches the whole string (Erlang `re` syntax, `(?i)` for case-insensitive). Negative indexes count from the end, out of
  range gives `null`; either end of a slice may be omitted or negative.

### 5.4 Other expressions

| Name | Syntax |
|---|---|
| CASE | `CASE WHEN condition THEN value … [ELSE value] END`; `CASE expression WHEN value [, value…] THEN value … [ELSE value] END` |
| List comprehension | `[x IN list [WHERE condition] [\| expression]]` |
| Pattern comprehension | `[ [p =] pattern [WHERE condition] \| expression ]` |
| Quantifiers | `all / any / none / single(x IN list WHERE condition)` |
| reduce | `reduce(acc = initial, x IN list \| expression)` |
| Map projection | `n {.name, .*, k: expression, variable}` |
| Subquery | `EXISTS { clauses… }`, `EXISTS { pattern [WHERE condition] }` |
| Pattern predicate | `WHERE (a)-[:T]->(:L)`, `exists((a)--())` (predicates only) |
| Existence | `exists(n.prop)` (same as `IS NOT NULL`) |
| Count | `count(*)` |

## 6. Functions

| Kind | Functions |
|---|---|
| Graph | `id`, `labels`, `type`, `properties`, `keys`, `nodes`, `relationships`, `startNode`, `endNode`, `length` |
| General | `coalesce`, `size`, `head`, `tail`, `last`, `reverse`, `range(start, end[, step])`, `timestamp()` |
| Conversion | `toInteger`, `toFloat`, `toString`, `toBoolean` |
| Strings | `toLower`, `toUpper`, `trim`, `ltrim`, `rtrim`, `substring(s, start[, len])`, `replace`, `split`, `left`, `right` |
| Maths | `abs`, `ceil`, `floor`, `round`, `sign`, `rand()`, `sqrt`, `exp`, `log`, `log10`, `e()`, `pi()`, `isNaN` |
| Trigonometry | `sin`, `cos`, `tan`, `cot`, `asin`, `acos`, `atan`, `atan2(y, x)`, `degrees`, `radians`, `haversin` |
| Aggregates | `count`, `sum`, `avg`, `min`, `max`, `collect`, `percentileCont`, `percentileDisc`, `stDev`, `stDevP` (all accept `DISTINCT`) |
| Temporal | `date`, `time`, `localtime`, `datetime`, `localdatetime`, `duration` with `.truncate`, `.statement`, `.transaction`, `.realtime`, `datetime.fromEpoch`, `datetime.fromEpochMillis`, `duration.between`, `duration.inMonths` / `inDays` / `inSeconds` (see [`cypher-en.md`](cypher-en.md) section 11) |

Function names are case-insensitive; namespaced functions are written `ns.f(…)`.

## 7. Not supported

- Neo4j extension syntax (not in the openCypher 2024.3 grammar): `FOREACH`, `CALL { … }` subqueries (including `CALL (a) { … }`,
  `OPTIONAL CALL`, `IN TRANSACTIONS`), `COUNT { … }` / `COLLECT { … }`, `LOAD CSV`.
- Also not supported: `||` string concatenation (use `+`), `filter()` / `extract()` (use list comprehensions), Unicode arrows /
  em dashes, returning a pattern directly in `RETURN` (use a pattern comprehension or `exists(…)`), `WITH … WHERE … ORDER BY`
  (`WHERE` goes after `ORDER BY` / `SKIP` / `LIMIT`).

---

# Part 2: syntax specific to bitcask

These forms aren't in the openCypher grammar; bitcask adds them for its own search capabilities and data model, and they don't
work on other openCypher implementations.

## 8. Full-text match `@@`

```cypher
MATCH (n:Doc) WHERE n.text @@ 'graph OR vector -cooking' RETURN n.title, score(n) ORDER BY score(n) DESC
```

- `n.text @@ query`: full-text match on the vertex text (the store must be opened in index mode, `{analyzer, _}`). Only `n.text`.
- Query syntax: `a b` (both), `a OR b` (either; uppercase `OR`, binds tighter than juxtaposition), `-a` (exclude), `"phrase"`,
  `prefix*`, `fuzzy~` (edit distance 1).
- `score(n)`: BM25 score (summed over terms, the larger one for `OR`); `null` on rows that didn't go through a full-text match.
- Same precedence as comparisons (level 5 in 5.3). As a conjunct of `WHERE` it is the starting point (search first, then expand).

## 9. Vector distance `<=>`

```cypher
MATCH (n:Doc) RETURN n.title ORDER BY n.embedding <=> $q LIMIT 10
MATCH (n:Doc) WHERE n.embedding <=> $q < 0.3 RETURN n
```

- `n.embedding <=> vector`: the vector is a list of numbers or a little-endian f32 binary; the value is the negated engine
  similarity score (smaller is closer: negative inner product under cosine / dot, squared distance under L2). `null` when the
  vertex has no vector. The store needs `{vector_dim, N}`.
- Precedence between level 6 (`IN` …) and `+ -`. The forms `ORDER BY … <=> … LIMIT k` and `WHERE … <=> … < t` use the vector
  index; other uses compute exact distances one by one.

## 10. Search functions

| Function | Meaning |
|---|---|
| `fts.phrase(n.text, 'phrase')` | phrase |
| `fts.near(n.text, 'a b', distance)` | proximity (at most that many words between) |
| `fts.wildcard(n.text, 'gr*h')` | wildcard |
| `fts.fuzzy(n.text, 'word'[, edits])` | fuzzy (default 1, at most 2) |
| `fts.fields(n, 'title:x body:y')` | named-field query |
| `search.hybrid(n, 'text', $vector[, k])` | full text + vector fused by RRF, top k (default 10) |

As a conjunct of `WHERE` they are the starting point and yield rows by descending score, with `score(n)` the engine's score;
elsewhere they test whether the vertex is a hit.

## 11. Special properties `text` and `embedding`

- `n.text`: the vertex text (what full-text search looks at). `n.embedding`: the vertex vector. Both read and write like
  properties: `CREATE (n {text: '…', embedding: [1.0, 0.0]})`, `SET n.text = '…'`, `SET n.embedding = null` (removes the vector).
- They aren't in the property metadata: no pushdown to engine filters, no property indexes, `MERGE` can't match on `embedding`;
  `SET n = {…}` clears the text (the vector stays unless the map gives `embedding`).
- Property names starting with an underscore are reserved for the implementation (`_labels`, `_types`, `_raw`).

## 12. User procedures and functions

Registered from Erlang, called by namespaced name:

```erlang
ok = bitcask_cypher:register_procedure(<<"my.range">>, #{args => [<<"n">>, {<<"step">>, 1}], outputs => [<<"i">>],
                                                         fn => fun(_Ctx, [N, S]) -> [#{i => I} || I <- lists:seq(1, N, S)] end}),
ok = bitcask_cypher:register_function(<<"my.slug">>, #{arity => 1, fn => fun(_Ctx, [S]) -> slug(S) end}).
```

```cypher
CALL my.range(3)
UNWIND [2, 3] AS n CALL my.range(n) YIELD i RETURN n, sum(i)
RETURN my.slug('Hello World')
```

Names need a namespace (`a.b`, `a.b.c`) and can't use a built-in namespace (`db`, `fts`, `search`, `date`, `time`, `localtime`,
`datetime`, `localdatetime`, `duration`, `point`). Argument types, read / write mode, streamed results and so on: see
[`cypher-en.md`](cypher-en.md) section 12.

## 13. Built-in procedures

| Procedure | Output |
|---|---|
| `CALL db.labels()` | `label`: labels with at least one vertex |
| `CALL db.relationshipTypes()` | `relationshipType`: registered relationship types |
| `CALL db.propertyKeys()` | `propertyKey`: property names found in vertex documents (a full scan, slow on large stores) |

Parentheses may be omitted when there are no arguments.

## 14. Other differences from openCypher

| Form / behaviour | Notes |
|---|---|
| `ORDER BY … NULLS FIRST` / `NULLS LAST` | puts `null` first / last regardless of direction (from SQL / GQL; not in the openCypher grammar) |
| A trailing `;` | optional |
| `MERGE … ON CREATE SET … ON MATCH SET … ON CREATE SET …` | several actions in any order (the grammar allows one; the TCK uses several) |
| `point({…})`, `point.distance`, `distance`, `point.withinBBox` | spatial types (from Neo4j; see [`cypher-en.md`](cypher-en.md) section 11) |
| `id(n)` / `id(r)` | vertex ids are u64; relationship ids are `[start, type id, end, rank]` (ids of deleted relationships aren't reused) |
| NaN / Infinity | the atoms `'NaN'` / `'Infinity'` / `'-Infinity'` in results and parameters (Erlang floats can't represent them) |
| Temporal / spatial values | tuples in results (`{date, {Y, M, D}}` …), stored as text plus a `_types` tag |
| Errors | `#{stage, message, type, detail, line, column}`; `type` / `detail` are openCypher's error type and detail code |
