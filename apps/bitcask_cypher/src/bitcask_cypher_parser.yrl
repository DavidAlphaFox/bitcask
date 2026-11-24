%% Cypher 子集的语法（doc/cypher-query-design-zh.md 第 5 节，一期）。产出 AST（见
%% bitcask_cypher_sema 模块头的形态说明）；语义检查（变量、聚合位置、子句顺序）不在这里。

Nonterminals
statement query_body clauses clause
proc_name call_args
match_clause unwind_clause with_clause return_clause create_clause set_clause
remove_clause delete_clause merge_clause merge_actions merge_action
case_expr case_alts case_alt opt_else
call_clause opt_yield yield_items yield_item opt_slice
comp_tail quantifier mp_items mp_item soft_kw pcomp_tail
opt_where projection proj_items proj_item opt_order sort_items sort_item sort_dir
opt_skip opt_limit opt_distinct
pattern pattern_part pattern_elem chain node_pattern opt_var opt_node_labels node_labels
opt_props rel_pattern rel_detail opt_rel_types opt_varlen varlen
set_items set_item remove_items remove_item expr_list opt_expr_list
expr uminus atom literal list_literal map_literal map_entries map_entry
symbolic_name var_name keyword set_target lexpr lterm lfactor lprimary
path_prefix path_count opt_pathkw group_kw pchain qgroup pquant.

Terminals
ident int float string param
'(' ')' '[' ']' '{' '}' ',' '.' ':' '|' '=' '<>' '<' '<=' '>' '>=' '+' '-' '*' '/' '%' '^'
';' '..' '+=' '<=>' '@@' '=~' '!'
'STARTS_WITH' 'ENDS_WITH' 'IS_NULL' 'IS_NOT_NULL'
'MATCH' 'OPTIONAL' 'WHERE' 'RETURN' 'WITH' 'UNWIND' 'AS' 'ORDER' 'BY' 'SKIP' 'LIMIT'
'ASC' 'ASCENDING' 'DESC' 'DESCENDING' 'DISTINCT' 'AND' 'OR' 'XOR' 'NOT' 'IN'
'NULL' 'TRUE' 'FALSE' 'CONTAINS' 'CREATE' 'SET' 'REMOVE' 'DELETE' 'DETACH' 'MERGE' 'ON'
'CASE' 'WHEN' 'THEN' 'ELSE' 'END' 'NULLS' 'CALL' 'YIELD'
'ALL' 'ANY' 'NONE' 'SINGLE' 'REDUCE' 'EXISTS' 'UNION'
'PATTERN' 'PATTERN_END'
raw_text
'INF' 'INFINITY' 'NAN' 'OFFSET' 'IS' '&' 'SHORTEST' 'PATH' 'PATHS' 'GROUP' 'GROUPS'.

Rootsymbol statement.

%% 预期的冲突（都按移进解决；冲突数一变，yecc 会报出来）：
%%   1. EXISTS '{' 既可能是子查询，也可能是对名叫 exists 的变量做映射投影——取子查询；
%%   2～4. 标签后面的 '|' 既可能接标签表达式（A|B），也可能是分隔符（[x IN l WHERE x:A | …]）
%%      ——取标签（要分隔就给表达式加括号）。标签表达式有三层（| / & / !），同一个歧义出现在三个状态里。
%% （'[' x 'IN' … 的推导 / 列表字面量歧义：x 是 var_name，列表字面量的元素走 expr，LALR 在 IN 之后才分叉，不再算冲突。）
Expect 4.

Left     100 'OR'.
Left     110 'XOR'.
Left     120 'AND'.
Unary    130 'NOT'.
%% 比较可以连写（a < b < c ⇒ a < b AND b < c，见 cmp/3），所以是 Left
Left     200 '=' '<>' '<' '<=' '>' '>=' '@@' '=~'.
Nonassoc 210 'IN' 'STARTS_WITH' 'ENDS_WITH' 'CONTAINS' 'IS_NULL' 'IS_NOT_NULL'.
Left     250 '<=>'.
Left     300 '+' '-'.
Left     400 '*' '/' '%'.
Left     500 '^'.                  %% openCypher：幂是左结合（2 ^ 3 ^ 2 = 64）
Unary    600 uminus.
Left     700 '.' '['.
Left     800 '('.

statement -> query_body     : '$1'.
statement -> query_body ';' : '$1'.

%% … UNION [ALL] …：{union, [{query, 子句}, {all | distinct, 子句}, …]}（第一段的标记是 first）
query_body -> clauses                          : {query, lists:reverse('$1')}.
query_body -> query_body 'UNION' clauses       : union('$1', distinct, '$3', loc('$2')).
query_body -> query_body 'UNION' 'ALL' clauses : union('$1', all, '$4', loc('$2')).
query_body -> query_body 'UNION' 'DISTINCT' clauses : union('$1', distinct, '$4', loc('$2')).

clauses -> clause         : ['$1'].
clauses -> clauses clause : ['$2' | '$1'].

clause -> match_clause  : '$1'.
clause -> unwind_clause : '$1'.
clause -> with_clause   : '$1'.
clause -> return_clause : '$1'.
clause -> create_clause : '$1'.
clause -> set_clause    : '$1'.
clause -> remove_clause : '$1'.
clause -> delete_clause : '$1'.
clause -> merge_clause  : '$1'.
clause -> call_clause   : '$1'.

%% CALL db.labels() [YIELD label [AS x], … [WHERE …]]：内置过程（二期，只读）。
call_clause -> 'CALL' proc_name call_args opt_yield :
    {Ys, W} = '$4',
    {call_proc, lower('$2'), '$3', Ys, W, loc('$1')}.

proc_name -> symbolic_name '.' symbolic_name : <<('$1')/binary, ".", ('$3')/binary>>.
proc_name -> proc_name '.' symbolic_name     : <<('$1')/binary, ".", ('$3')/binary>>.

%% 没有参数时括号可省（openCypher：CALL db.labels）
call_args -> '$empty'               : implicit.
call_args -> '(' opt_expr_list ')'  : '$2'.

opt_yield -> '$empty'                      : {undefined, undefined}.
opt_yield -> 'YIELD' '*'                   : {all, undefined}.
opt_yield -> 'YIELD' yield_items opt_where : {lists:reverse('$2'), '$3'}.

yield_items -> yield_item                 : ['$1'].
yield_items -> yield_items ',' yield_item : ['$3' | '$1'].

yield_item -> var_name                 : {'$1', '$1'}.
yield_item -> var_name 'AS' var_name   : {'$1', '$3'}.

match_clause -> 'MATCH' pattern opt_where            : {Ps, W} = elem_where('$2', '$3'), {match, false, Ps, W, loc('$1')}.
match_clause -> 'OPTIONAL' 'MATCH' pattern opt_where : {Ps, W} = elem_where('$3', '$4'), {match, true, Ps, W, loc('$1')}.

%% MERGE 模式 [ON CREATE SET …] [ON MATCH SET …]（可多个、任意顺序）。
merge_clause -> 'MERGE' pattern_part merge_actions :
    {merge, '$2', [I || {create, Is} <- lists:reverse('$3'), I <- Is],
     [I || {match, Is} <- lists:reverse('$3'), I <- Is], loc('$1')}.

merge_actions -> '$empty'                   : [].
merge_actions -> merge_actions merge_action : ['$2' | '$1'].

merge_action -> 'ON' 'CREATE' 'SET' set_items : {create, lists:reverse('$4')}.
merge_action -> 'ON' 'MATCH' 'SET' set_items  : {match, lists:reverse('$4')}.

opt_where -> '$empty'      : undefined.
opt_where -> 'WHERE' expr  : '$2'.

unwind_clause -> 'UNWIND' expr 'AS' var_name : {unwind, '$2', '$4', loc('$1')}.

with_clause -> 'WITH' opt_distinct projection opt_order opt_skip opt_limit opt_where :
    {with, '$2', '$3', '$4', '$5', '$6', '$7', loc('$1')}.

return_clause -> 'RETURN' opt_distinct projection opt_order opt_skip opt_limit :
    {return, '$2', '$3', '$4', '$5', '$6', loc('$1')}.

opt_distinct -> '$empty'   : false.
opt_distinct -> 'DISTINCT' : true.

projection -> '*'                : {star, []}.
projection -> '*' ',' proj_items : {star, lists:reverse('$3')}.
projection -> proj_items         : {items, lists:reverse('$1')}.

proj_items -> proj_item                : ['$1'].
proj_items -> proj_items ',' proj_item : ['$3' | '$1'].

proj_item -> expr               : {item, '$1', undefined}.
proj_item -> expr 'AS' var_name : {item, '$1', '$3'}.
%% 记号预处理在没有别名的投影项前插的源文本（列名用）
proj_item -> raw_text expr      : {item, '$2', {raw, val('$1')}}.

opt_order -> '$empty'                 : [].
opt_order -> 'ORDER' 'BY' sort_items  : lists:reverse('$3').

sort_items -> sort_item                : ['$1'].
sort_items -> sort_items ',' sort_item : ['$3' | '$1'].

sort_item -> expr          : {'$1', asc}.
sort_item -> expr sort_dir : {'$1', '$2'}.
sort_item -> expr 'NULLS' ident          : {'$1', nulls(asc, '$3')}.
sort_item -> expr sort_dir 'NULLS' ident : {'$1', nulls('$2', '$4')}.

sort_dir -> 'ASC'        : asc.
sort_dir -> 'ASCENDING'  : asc.
sort_dir -> 'DESC'       : desc.
sort_dir -> 'DESCENDING' : desc.

opt_skip -> '$empty'     : undefined.
opt_skip -> 'SKIP' expr  : '$2'.
opt_skip -> 'OFFSET' expr : '$2'.                    %% openCypher 2024.3：OFFSET 是 SKIP 的同义词

opt_limit -> '$empty'     : undefined.
opt_limit -> 'LIMIT' expr : '$2'.

create_clause -> 'CREATE' pattern : {create, '$2', loc('$1')}.

set_clause -> 'SET' set_items : {set, lists:reverse('$2'), loc('$1')}.

set_items -> set_item               : ['$1'].
set_items -> set_items ',' set_item : ['$3' | '$1'].

%% SET 目标 = 值：目标是变量（整体赋值）或「后缀表达式 . 属性 / [键]」（openCypher 2024.3 的 <set property item>）
set_item -> set_target '=' expr                 : set_assign('$1', '$3').
set_item -> var_name '+=' expr                  : {set_props, '$1', '$3', merge}.
set_item -> var_name node_labels                : {set_labels, '$1', lists:reverse('$2')}.

remove_clause -> 'REMOVE' remove_items : {remove, lists:reverse('$2'), loc('$1')}.

remove_items -> remove_item                  : ['$1'].
remove_items -> remove_items ',' remove_item : ['$3' | '$1'].

remove_item -> set_target                 : remove_target('$1').
remove_item -> var_name node_labels       : {remove_labels, '$1', lists:reverse('$2')}.

set_target -> var_name                       : '$1'.
set_target -> '(' expr ')'                   : '$2'.
set_target -> set_target '.' symbolic_name   : {prop, '$1', '$3'}.
set_target -> set_target '[' expr ']'        : {index, '$1', '$3'}.

delete_clause -> 'DELETE' expr_list          : {delete, false, lists:reverse('$2'), loc('$1')}.
delete_clause -> 'DETACH' 'DELETE' expr_list : {delete, true, lists:reverse('$3'), loc('$1')}.

%% ---- 模式 ----------------------------------------------------------------

pattern -> pattern_part             : ['$1'].
pattern -> pattern ',' pattern_part : '$1' ++ ['$3'].

pattern_part -> pattern_elem              : part(undefined, '$1').
pattern_part -> var_name '=' pattern_elem : part('$1', '$3').
%% 路径搜索前缀（openCypher 2024.3）：ALL / ANY [k] / ALL SHORTEST / ANY SHORTEST / SHORTEST k / SHORTEST [k] GROUP(S)
pattern_part -> path_prefix pattern_elem              : {part, undefined, search('$1', '$2')}.
pattern_part -> var_name '=' path_prefix pattern_elem : {part, '$1', search('$3', '$4')}.

path_prefix -> 'ALL' opt_pathkw                         : all.
path_prefix -> 'ANY' opt_pathkw                         : {any, {lit, 1}}.
path_prefix -> 'ANY' path_count opt_pathkw              : {any, '$2'}.
path_prefix -> 'ALL' 'SHORTEST' opt_pathkw              : all_shortest.
path_prefix -> 'ANY' 'SHORTEST' opt_pathkw              : any_shortest.
path_prefix -> 'SHORTEST' path_count opt_pathkw         : {shortest, '$2'}.
path_prefix -> 'SHORTEST' opt_pathkw group_kw           : {groups, {lit, 1}}.
path_prefix -> 'SHORTEST' path_count opt_pathkw group_kw : {groups, '$2'}.

path_count -> int   : {lit, val('$1')}.
path_count -> param : {param, val('$1'), loc('$1')}.

opt_pathkw -> '$empty' : ok.
opt_pathkw -> 'PATH'   : ok.
opt_pathkw -> 'PATHS'  : ok.

group_kw -> 'GROUP'  : ok.
group_kw -> 'GROUPS' : ok.

pattern_elem -> chain                 : '$1'.
pattern_elem -> ident '(' chain ')'   : shortest('$1', '$3').

%% 路径项（openCypher 2024.3）：节点、关系、量化关系、括号路径 / 量化组的序列；相邻的两个节点模式是同一个节点。
%% 收成元素列表，再由 norm_path/1 规范成 {chain, 起点, [{关系 | 量化组, 节点}]}。
chain -> pchain                                    : norm_path(lists:reverse('$1')).
pchain -> node_pattern                             : ['$1'].
pchain -> qgroup                                   : ['$1'].
pchain -> pchain node_pattern                      : ['$2' | '$1'].
pchain -> pchain qgroup                            : ['$2' | '$1'].
pchain -> pchain rel_pattern node_pattern          : ['$3', '$2' | '$1'].
pchain -> pchain rel_pattern pquant node_pattern   : ['$4', quant_rel('$2', '$3') | '$1'].

%% 括号路径：( [子路径变量 =] 路径 [WHERE …] ) [量词]
qgroup -> '(' pchain opt_where ')' pquant                  : group(undefined, '$2', '$3', '$5', loc('$1')).
qgroup -> '(' pchain opt_where ')'                         : group(undefined, '$2', '$3', {1, 1}, loc('$1')).
qgroup -> '(' var_name '=' pchain opt_where ')' pquant     : group('$2', '$4', '$5', '$7', loc('$1')).
qgroup -> '(' var_name '=' pchain opt_where ')'            : group('$2', '$4', '$5', {1, 1}, loc('$1')).

%% 量词：* = {0,}、+ = {1,}、{n}、{m,n}、{m,}、{,n}
pquant -> '*'                 : {0, infinity}.
pquant -> '+'                 : {1, infinity}.
pquant -> '{' int '}'         : {val('$2'), val('$2')}.
pquant -> '{' int ',' int '}' : {val('$2'), val('$4')}.
pquant -> '{' int ',' '}'     : {val('$2'), infinity}.
pquant -> '{' ',' int '}'     : {0, val('$3')}.
pquant -> '{' ',' '}'         : {0, infinity}.

node_pattern -> '(' opt_var opt_node_labels opt_props ')' :
    {node, '$2', lists:reverse('$3'), '$4', loc('$1')}.
%% 元素模式里的 WHERE（openCypher 2024.3：(n:L WHERE n.x > 1)，与属性映射二选一）
node_pattern -> '(' opt_var opt_node_labels 'WHERE' expr ')' :
    {node, '$2', lists:reverse('$3'), {where, '$5'}, loc('$1')}.

opt_var -> '$empty' : undefined.
opt_var -> var_name : '$1'.

opt_node_labels -> '$empty'    : [].
opt_node_labels -> node_labels : '$1'.
opt_node_labels -> 'IS' lexpr  : [label_term('$2')].

%% 标签：旧写法 :A:B（都要有），或 : / IS 后接标签表达式（openCypher 2024.3）
node_labels -> ':' lexpr             : [label_term('$2')].
node_labels -> node_labels ':' lexpr : [label_term('$3') | '$1'].

%% 标签表达式：| 任一、& 都要、! 没有、% 有任意标签、括号；关系的旧写法 :T|:U 也收
lexpr -> lterm               : '$1'.
lexpr -> lexpr '|' lterm     : {lor, '$1', '$3'}.
lexpr -> lexpr '|' ':' lterm : {lor, '$1', '$4'}.
lterm -> lfactor             : '$1'.
lterm -> lterm '&' lfactor   : {land, '$1', '$3'}.
lfactor -> lprimary          : '$1'.
lfactor -> '!' lfactor       : {lnot, '$2'}.
lprimary -> symbolic_name    : '$1'.
lprimary -> '(' lexpr ')'    : '$2'.
lprimary -> '%'              : wildcard.

opt_props -> '$empty'    : undefined.
opt_props -> map_literal : '$1'.
opt_props -> param       : {param, val('$1'), loc('$1')}.

rel_pattern -> '-' rel_detail '-' '>'     : rel('$2', out, loc('$1')).
rel_pattern -> '<' '-' rel_detail '-'     : rel('$3', in, loc('$1')).
rel_pattern -> '-' rel_detail '-'         : rel('$2', both, loc('$1')).
rel_pattern -> '<' '-' rel_detail '-' '>' : rel('$3', both, loc('$1')).

rel_detail -> '$empty' : {undefined, [], undefined, undefined}.
rel_detail -> '[' opt_var opt_rel_types opt_varlen opt_props ']' : {'$2', '$3', '$4', '$5'}.
rel_detail -> '[' opt_var opt_rel_types opt_varlen 'WHERE' expr ']' : {'$2', '$3', '$4', {where, '$6'}}.

opt_rel_types -> '$empty'      : [].
opt_rel_types -> ':' lexpr     : rel_types('$2').
opt_rel_types -> 'IS' lexpr    : rel_types('$2').

opt_varlen -> '$empty'    : undefined.
opt_varlen -> '*' varlen  : '$2'.

varlen -> '$empty'        : {undefined, undefined}.
varlen -> int             : {val('$1'), val('$1')}.
varlen -> int '..'        : {val('$1'), undefined}.
varlen -> int '..' int    : {val('$1'), val('$3')}.
varlen -> '..' int        : {undefined, val('$2')}.
varlen -> '..'            : {undefined, undefined}.

%% ---- 表达式 ----------------------------------------------------------------

expr -> expr 'OR' expr          : {op, 'or', '$1', '$3'}.
expr -> expr 'XOR' expr         : {op, 'xor', '$1', '$3'}.
expr -> expr 'AND' expr         : {op, 'and', '$1', '$3'}.
expr -> 'NOT' expr              : {unop, 'not', '$2'}.
expr -> expr '=' expr           : cmp('$1', '=', '$3').
expr -> expr '<>' expr          : cmp('$1', '<>', '$3').
expr -> expr '<' expr           : cmp('$1', '<', '$3').
expr -> expr '<=' expr          : cmp('$1', '<=', '$3').
expr -> expr '>' expr           : cmp('$1', '>', '$3').
expr -> expr '>=' expr          : cmp('$1', '>=', '$3').
expr -> expr '@@' expr          : {op, '@@', '$1', '$3'}.
expr -> expr '=~' expr          : {op, regex, '$1', '$3'}.
expr -> expr '[' expr ']'       : {index, '$1', '$3'}.
expr -> expr '[' opt_slice '..' opt_slice ']' : {slice, '$1', '$3', '$5'}.
expr -> expr '<=>' expr         : {op, '<=>', '$1', '$3'}.
expr -> expr 'IN' expr          : {op, in, '$1', '$3'}.
expr -> expr 'STARTS_WITH' expr : {op, starts_with, '$1', '$3'}.
expr -> expr 'ENDS_WITH' expr   : {op, ends_with, '$1', '$3'}.
expr -> expr 'CONTAINS' expr    : {op, contains, '$1', '$3'}.
expr -> expr 'IS_NULL'          : {is_null, '$1', true}.
expr -> expr 'IS_NOT_NULL'      : {is_null, '$1', false}.
expr -> expr '+' expr           : {op, '+', '$1', '$3'}.
expr -> expr '-' expr           : {op, '-', '$1', '$3'}.
expr -> expr '*' expr           : {op, '*', '$1', '$3'}.
expr -> expr '/' expr           : {op, '/', '$1', '$3'}.
expr -> expr '%' expr           : {op, '%', '$1', '$3'}.
expr -> expr '^' expr           : {op, '^', '$1', '$3'}.
expr -> expr '.' symbolic_name  : {prop, '$1', '$3'}.
%% 带命名空间的函数（二期：检索的函数形式 fts.phrase(…)、search.hybrid(…)）
expr -> expr '.' symbolic_name '(' opt_expr_list ')' : ns_call('$1', '$3', '$5').
expr -> uminus                  : '$1'.
expr -> atom                    : '$1'.

uminus -> '-' expr : {unop, '-', '$2'}.
uminus -> '+' expr : '$2'.

atom -> literal                                  : '$1'.
atom -> param                                    : {param, val('$1'), loc('$1')}.
atom -> var_name                                 : '$1'.
atom -> var_name node_labels                     : {has_labels, '$1', lists:reverse('$2')}.
atom -> var_name 'IS' lexpr                      : {has_labels, '$1', [label_term('$3')]}.
atom -> ident '(' opt_distinct opt_expr_list ')' : call(lower(val('$1')), '$3', '$4', loc('$1')).
atom -> ident '(' '*' ')'                        : count_star('$1').
%% 括号里的比较 / AND 标一下：链式比较的改写（cmp/3）不能跨括号（(a = b) = c 不是 a = b AND b = c）
atom -> '(' expr ')'                             : paren('$2').
atom -> list_literal                             : '$1'.
atom -> case_expr                                : '$1'.
%% 列表推导 [x IN list [WHERE p] [| e]]（与「第一个元素是 x IN list 的列表字面量」有歧义，
%% 按 openCypher 取推导）
atom -> '[' var_name 'IN' expr comp_tail ']'      : {W, P} = '$5', {list_comp, '$2', '$4', W, P}.
%% 量词 all / any / none / single(x IN list WHERE p)
atom -> quantifier '(' var_name 'IN' expr 'WHERE' expr ')' : {quant, '$1', '$3', '$5', '$7'}.
%% reduce(acc = init, x IN list | e)
atom -> 'REDUCE' '(' var_name '=' expr ',' var_name 'IN' expr '|' expr ')' :
    {reduce, '$3', '$5', '$7', '$9', '$11'}.
%% exists(n.prop) / exists((a)-->(b))
atom -> 'EXISTS' '(' expr ')'                     : {exists, '$3', loc('$1')}.
%% 子查询表达式 EXISTS { … }（完整子查询，或「模式 [WHERE …]」简写）
atom -> 'EXISTS' '{' query_body '}'        : {subq, exists, '$3', loc('$1')}.
atom -> 'EXISTS' '{' pattern opt_where '}' : {Ps, W} = elem_where('$3', '$4'), {subq, exists, {pattern_form, Ps, W, loc('$1')}, loc('$1')}.
%% 模式谓词 (a)-[:T]->(b)：PATTERN / PATTERN_END 由 bitcask_cypher 的记号预处理在表达式位置插入
atom -> 'PATTERN' chain 'PATTERN_END'             : {pattern_pred, '$2', loc('$1')}.
%% 模式推导 [(a)-->(b) WHERE … | 表达式]、[p = (a)-->(b) | …]
atom -> '[' 'PATTERN' chain 'PATTERN_END' pcomp_tail ']' :
    {W0, P} = '$5', {[{part, _, C}], W} = elem_where([{part, undefined, '$3'}], W0),
    {pattern_comp, undefined, C, W, P, loc('$2')}.
atom -> '[' var_name '=' 'PATTERN' chain 'PATTERN_END' pcomp_tail ']' :
    {W0, P} = '$7', {[{part, _, C}], W} = elem_where([{part, undefined, '$5'}], W0),
    {pattern_comp, '$2', C, W, P, loc('$4')}.
%% 映射投影 n {.name, .*, k: e, v}
atom -> var_name '{' mp_items '}'                 : {map_proj, '$1', lists:reverse('$3')}.
atom -> var_name '{' '}'                          : {map_proj, '$1', []}.
atom -> map_literal                              : '$1'.

%% CASE：通用形式 CASE WHEN 条件 THEN 值 … [ELSE 值] END；简单形式 CASE 表达式 WHEN 值 THEN …
case_expr -> 'CASE' case_alts opt_else 'END'      : {case_expr, undefined, searched_alts(lists:reverse('$2')), '$3', loc('$1')}.
case_expr -> 'CASE' expr case_alts opt_else 'END' : {case_expr, '$2', [{W, V} || {Ws, V} <- lists:reverse('$3'), W <- Ws], '$4', loc('$1')}.

case_alts -> case_alt           : ['$1'].
case_alts -> case_alts case_alt : ['$2' | '$1'].

case_alt -> 'WHEN' expr_list 'THEN' expr : {lists:reverse('$2'), '$4'}.

comp_tail -> '$empty'                  : {undefined, undefined}.
comp_tail -> 'WHERE' expr              : {'$2', undefined}.
comp_tail -> '|' expr                  : {undefined, '$2'}.
comp_tail -> 'WHERE' expr '|' expr     : {'$2', '$4'}.

pcomp_tail -> '|' expr               : {undefined, '$2'}.
pcomp_tail -> 'WHERE' expr '|' expr  : {'$2', '$4'}.

quantifier -> 'ALL'    : all.
quantifier -> 'ANY'    : any.
quantifier -> 'NONE'   : none.
quantifier -> 'SINGLE' : single.

mp_items -> mp_item              : ['$1'].
mp_items -> mp_items ',' mp_item : ['$3' | '$1'].

mp_item -> '.' symbolic_name     : {prop_sel, '$2'}.
mp_item -> '.' '*'               : all_props.
mp_item -> symbolic_name ':' expr : {entry, '$1', '$3'}.
mp_item -> var_name              : {var_sel, '$1'}.

opt_slice -> '$empty' : undefined.
opt_slice -> expr     : '$1'.

opt_else -> '$empty'     : undefined.
opt_else -> 'ELSE' expr  : '$2'.

literal -> int     : {lit, val('$1')}.
literal -> float   : {lit, val('$1')}.
literal -> string  : {lit, val('$1')}.
literal -> 'TRUE'  : {lit, true}.
literal -> 'FALSE' : {lit, false}.
literal -> 'NULL'  : {lit, null}.
%% 浮点特殊值字面量（openCypher 2024.3：INF / INFINITY / NAN；-INF 是取负）
literal -> 'INF'      : {lit, 'Infinity'}.
literal -> 'INFINITY' : {lit, 'Infinity'}.
literal -> 'NAN'      : {lit, 'NaN'}.

list_literal -> '[' opt_expr_list ']' : {list, '$2'}.

map_literal -> '{' '}'             : {map, []}.
map_literal -> '{' map_entries '}' : {map, lists:reverse('$2')}.

map_entries -> map_entry                 : ['$1'].
map_entries -> map_entries ',' map_entry : ['$3' | '$1'].

map_entry -> symbolic_name ':' expr : {'$1', '$3'}.

opt_expr_list -> '$empty'  : [].
opt_expr_list -> expr_list : lists:reverse('$1').

expr_list -> expr               : ['$1'].
expr_list -> expr_list ',' expr : ['$3' | '$1'].

var_name -> ident : {var, val('$1'), loc('$1')}.
%% 函数式关键字（all / any / none / single / reduce / exists）后面不跟 ( 时就是变量名
var_name -> soft_kw : {var, kw_name('$1'), loc('$1')}.

soft_kw -> 'ALL'    : '$1'.
soft_kw -> 'ANY'    : '$1'.
soft_kw -> 'NONE'   : '$1'.
soft_kw -> 'SINGLE' : '$1'.
soft_kw -> 'REDUCE' : '$1'.
soft_kw -> 'EXISTS' : '$1'.

%% 属性名、标签、关系类型、映射键可以是关键字（n.order、:Order、{limit: 1}）。
symbolic_name -> ident   : val('$1').
symbolic_name -> keyword : kw_name('$1').

keyword -> 'MATCH'      : '$1'.
keyword -> 'OPTIONAL'   : '$1'.
keyword -> 'WHERE'      : '$1'.
keyword -> 'RETURN'     : '$1'.
keyword -> 'WITH'       : '$1'.
keyword -> 'UNWIND'     : '$1'.
keyword -> 'AS'         : '$1'.
keyword -> 'ORDER'      : '$1'.
keyword -> 'BY'         : '$1'.
keyword -> 'SKIP'       : '$1'.
keyword -> 'LIMIT'      : '$1'.
keyword -> 'ASC'        : '$1'.
keyword -> 'ASCENDING'  : '$1'.
keyword -> 'DESC'       : '$1'.
keyword -> 'DESCENDING' : '$1'.
keyword -> 'DISTINCT'   : '$1'.
keyword -> 'AND'        : '$1'.
keyword -> 'OR'         : '$1'.
keyword -> 'XOR'        : '$1'.
keyword -> 'NOT'        : '$1'.
keyword -> 'IN'         : '$1'.
keyword -> 'NULL'       : '$1'.
keyword -> 'TRUE'       : '$1'.
keyword -> 'FALSE'      : '$1'.
keyword -> 'CONTAINS'   : '$1'.
keyword -> 'CREATE'     : '$1'.
keyword -> 'SET'        : '$1'.
keyword -> 'REMOVE'     : '$1'.
keyword -> 'DELETE'     : '$1'.
keyword -> 'DETACH'     : '$1'.
keyword -> 'MERGE'      : '$1'.
keyword -> 'ON'         : '$1'.
keyword -> 'CASE'       : '$1'.
keyword -> 'WHEN'       : '$1'.
keyword -> 'THEN'       : '$1'.
keyword -> 'ELSE'       : '$1'.
keyword -> 'END'        : '$1'.
keyword -> 'NULLS'      : '$1'.
keyword -> 'CALL'       : '$1'.
keyword -> 'YIELD'      : '$1'.
keyword -> 'ALL'        : '$1'.
keyword -> 'ANY'        : '$1'.
keyword -> 'NONE'       : '$1'.
keyword -> 'SINGLE'     : '$1'.
keyword -> 'REDUCE'     : '$1'.
keyword -> 'EXISTS'     : '$1'.
keyword -> 'UNION'      : '$1'.
keyword -> 'INF'        : '$1'.
keyword -> 'INFINITY'   : '$1'.
keyword -> 'NAN'        : '$1'.
keyword -> 'OFFSET'     : '$1'.
keyword -> 'IS'         : '$1'.
keyword -> 'SHORTEST'   : '$1'.
keyword -> 'PATH'       : '$1'.
keyword -> 'PATHS'      : '$1'.
keyword -> 'GROUP'      : '$1'.
keyword -> 'GROUPS'     : '$1'.

Erlang code.

loc(Tok) -> element(2, Tok).
val(Tok) -> element(3, Tok).

lower(B) -> string:lowercase(B).

%% 关键字当名字用（n.order、:Order）：取源文本原样（词法在关键字记号里留了原文）。
kw_name({_Cat, _Loc, Text}) -> Text.

%% ---- 路径项的规范化（量化路径）-------------------------------------------------
%% 元素序列 → {chain, N0, Steps}；Steps 的每项是 {关系, 节点} 或 {{qpp, 组体链, WHERE, Min, Max}, 节点}。
%%   * 相邻的节点模式合成一个（变量至多一个名字；标签合并；属性 / WHERE 至多一边有）；
%%   * 量化组前后没有节点就补匿名节点（组的两端与相邻节点是同一个节点）；
%%   * 不带量词（或 {1}）的括号路径直接展开进外层（WHERE 挂到组里第一个空着的节点上，随后与子句 WHERE 做 AND）；
%%     子路径变量只能用在整条模式就是这个括号路径时（等同 p = …）。
part(PV, {subpath, P, Chain}) ->
    case PV of
        undefined -> {part, P, Chain};
        {var, _, L} -> return_error(L, "a path variable can't be declared both outside and inside the parentheses")
    end;
part(PV, Elem) -> {part, PV, Elem}.

group(SubVar, Rev, Where, {Min, Max}, Loc) ->
    {group, SubVar, norm_path(lists:reverse(Rev)), Where, Min, Max, Loc}.

%% 量化关系：没有 WHERE 的就是变长关系（-[r:T]->{1,2} ≡ -[r:T*1..2]->）；带 WHERE 的改成单关系的量化组
quant_rel({rel, _, _, _, _, VL, L}, _Q) when VL =/= undefined ->
    return_error(L, "a quantified relationship can't also have a variable length (*)");
quant_rel({rel, V, Ts, {where, _} = W, Dir, undefined, L}, {Min, Max}) ->
    Anon = fun() -> {node, undefined, [], undefined, L} end,
    {group, undefined, {chain, Anon(), [{{rel, V, Ts, W, Dir, undefined, L}, Anon()}]}, undefined, Min, Max, L};
quant_rel({rel, V, Ts, Ps, Dir, undefined, L}, {Min, Max}) ->
    {rel, V, Ts, Ps, Dir, {Min, case Max of infinity -> undefined; _ -> Max end}, L}.

norm_path([{group, SV, Body, W, 1, 1, L}]) when SV =/= undefined ->
    {chain, B0, Steps} = Body,
    case W of
        undefined -> {subpath, SV, Body};
        _ -> {subpath, SV, {chain, add_where(B0, W, L), Steps}}
    end;
norm_path(Elems) ->
    norm_elems(Elems, undefined, []).

%% Cur：当前的边界节点（undefined = 还没有）；Acc：倒序的 Steps
norm_elems([], Cur, Acc) ->
    finish(Cur, lists:reverse(Acc));
norm_elems([{node, _, _, _, _} = N | Rest], Cur, Acc) ->
    {Cur2, Acc2} = juxt(Cur, N, Acc),
    norm_elems(Rest, Cur2, Acc2);
norm_elems([{rel, _, _, _, _, _, L} = R, {node, _, _, _, _} = N | Rest], Cur, Acc) ->
    Left = case Cur of undefined -> return_error(L, "a relationship pattern needs a node pattern before it"); _ -> Cur end,
    norm_elems(Rest, N, [{R, Left, N} | Acc]);
norm_elems([{group, SV, _, _, _, _, L} | _], _Cur, _Acc) when SV =/= undefined ->
    return_error(L, "subpath variables are only supported when the parenthesized path is the whole pattern");
norm_elems([{group, undefined, {chain, B0, BSteps}, W, 1, 1, L} | Rest], Cur, Acc) ->
    %% 不带量词：展开
    B0w = case W of undefined -> B0; _ -> add_where(B0, W, L) end,
    {Left, Acc1} = juxt(Cur, B0w, Acc),
    {Acc2, Last} = lists:foldl(fun({R, N}, {A, Prev}) -> {[{R, Prev, N} | A], N} end, {Acc1, Left}, BSteps),
    norm_elems(Rest, Last, Acc2);
norm_elems([{group, undefined, Body, W, Min, Max, L} | Rest], Cur, Acc) ->
    Left = case Cur of undefined -> anon_node(L); _ -> Cur end,
    Right = anon_node(L),
    {Body2, W2} = qpp_body(Body, W),
    norm_elems(Rest, Right, [{{qpp, Body2, W2, Min, Max, L}, Left, Right} | Acc]);
norm_elems([Other | _], _Cur, _Acc) ->
    return_error(element(tuple_size(Other), Other), "unexpected element in a path pattern").

%% Acc 里存的是 {关系, 左, 右}：右端之后可能又与相邻节点合并过，所以每一步的右端取下一步的左端，最后一步取
%% 最终的当前节点 Last
finish(Last, []) -> {chain, Last, []};
finish(Last, [{_, Left0, _} | _] = Triples) -> {chain, Left0, relink(Triples, Last)}.

relink([{R, _L, _Right}], Last) -> [{R, Last}];
relink([{R, _L, _Right}, {_, NextLeft, _} = Next | Rest], Last) -> [{R, NextLeft} | relink([Next | Rest], Last)].

anon_node(L) -> {node, undefined, [], undefined, L}.

%% 组体：组里元素模式的 WHERE 抽出来与组的 WHERE 做 AND（每次重复各算一次），不并进子句
qpp_body(Chain, W) ->
    {Chain2, Preds} = elem_where_chain(Chain, []),
    {Chain2, lists:foldl(fun(P, undefined) -> P; (P, Acc) -> {op, 'and', Acc, P} end, W, lists:reverse(Preds))}.

%% 相邻的节点模式（同一个节点）：能合并就合成一个（变量至多一个名字、属性 / WHERE 至多一边有）；合并不了
%% （两个不同的名字、两边都有属性）就在中间插一条长度为 0 的匿名关系（-[*0..0]-：起点就是终点），两个名字都绑到它。
juxt(undefined, N, Acc) -> {N, Acc};
juxt({node, V1, L1, P1, Loc} = A, {node, V2, L2, P2, _} = B, Acc) ->
    SameVar = V1 =:= undefined orelse V2 =:= undefined orelse element(2, V1) =:= element(2, V2),
    OneProps = P1 =:= undefined orelse P2 =:= undefined,
    case SameVar andalso OneProps of
        true ->
            V = case V1 of undefined -> V2; _ -> V1 end,
            P = case P1 of undefined -> P2; _ -> P1 end,
            {{node, V, L1 ++ [X || X <- L2, not lists:member(X, L1)], P, Loc}, Acc};
        false ->
            {B, [{{rel, undefined, [], undefined, both, {0, 0}, Loc}, A, B} | Acc]}
    end.

%% 把括号路径的 WHERE 挂到节点上（{where, E}，与属性映射互斥；节点已有属性 → 与之 AND 不了，报错）
add_where({node, V, Ls, undefined, NL}, W, _L) -> {node, V, Ls, {where, W}, NL};
add_where({node, V, Ls, {where, W0}, NL}, W, _L) -> {node, V, Ls, {where, {op, 'and', W0, W}}, NL};
add_where(_, _W, L) -> return_error(L, "move the property map of the first node into the WHERE of the parenthesized path").

%% 路径搜索前缀：ALL 就是缺省（全部路径）；别的包成 {search, 方式, 链, 位置}
search(all, Elem) -> Elem;
search(Mode, {chain, {node, _, _, _, L}, _} = C) -> {search, Mode, C, L};
search(_Mode, {shortest, _, _, L}) -> return_error(L, "a path search prefix can't be combined with shortestPath(...)").

%% 元素模式里的 WHERE 抽出来，与子句的 WHERE 做 AND（变长关系上的 WHERE 有歧义，不收）
elem_where(Parts, Where) ->
    {Parts2, Preds} = lists:mapfoldl(fun elem_where_part/2, [], Parts),
    {Parts2, lists:foldl(fun(P, undefined) -> P;
                            (P, Acc) -> {op, 'and', Acc, P}
                         end, Where, lists:reverse(Preds))}.

elem_where_part({part, PV, {search, M, Chain, L}}, Acc) ->
    {Chain2, Acc2} = elem_where_chain(Chain, Acc),
    {{part, PV, {search, M, Chain2, L}}, Acc2};
elem_where_part({part, PV, {shortest, K, Chain, L}}, Acc) ->
    {Chain2, Acc2} = elem_where_chain(Chain, Acc),
    {{part, PV, {shortest, K, Chain2, L}}, Acc2};
elem_where_part({part, PV, Chain}, Acc) ->
    {Chain2, Acc2} = elem_where_chain(Chain, Acc),
    {{part, PV, Chain2}, Acc2}.

elem_where_chain({chain, N0, Steps}, Acc0) ->
    {N0b, Acc1} = elem_where_node(N0, Acc0),
    {Steps2, Acc2} = lists:mapfoldl(fun({Rel, N}, A) ->
                                            {Rel2, A1} = elem_where_rel(Rel, A),
                                            {N2, A2} = elem_where_node(N, A1),
                                            {{Rel2, N2}, A2}
                                    end, Acc1, Steps),
    {{chain, N0b, Steps2}, Acc2}.

elem_where_node({node, V, Ls, {where, E}, L}, Acc) -> {{node, V, Ls, undefined, L}, [E | Acc]};
elem_where_node(N, Acc) -> {N, Acc}.

elem_where_rel({rel, V, Ts, {where, E}, Dir, undefined, L}, Acc) -> {{rel, V, Ts, undefined, Dir, undefined, L}, [E | Acc]};
elem_where_rel({rel, _, _, {where, _}, _, _, L}, _Acc) ->
    return_error(L, "WHERE inside a variable-length relationship pattern is not supported; use WHERE after the pattern");
elem_where_rel(R, Acc) -> {R, Acc}.

%% 标签表达式 → 标签项：名字（有）、{any, [项]}（任一）、{all, [项]}（都要）、{'not', 项}、wildcard（有任意标签）
label_term({lor, A, B}) -> {any, flat(lor, {lor, A, B})};
label_term({land, A, B}) -> {all, flat(land, {land, A, B})};
label_term({lnot, A}) -> {'not', label_term(A)};
label_term(T) -> T.                                  %% 名字或 wildcard

flat(Op, {Op, A, B}) -> flat(Op, A) ++ flat(Op, B);
flat(_, T) -> [label_term(T)].

%% 关系类型：只是名字的「任一」→ 名字列表（按类型取边）；更复杂的（&、!、%、括号）→ {lexpr, 项}，按类型名过滤
rel_types(E) ->
    case label_term(E) of
        N when is_binary(N) -> [N];
        {any, Ns} = T -> case lists:all(fun is_binary/1, Ns) of true -> Ns; false -> {lexpr, T} end;
        T -> {lexpr, T}
    end.

%% SET 目标 = 值
set_assign({var, _, _} = V, E) -> {set_props, V, E, replace};
set_assign({prop, T, K}, E) -> {set_prop, T, K, E};
set_assign({index, T, KE}, E) -> {set_prop, T, {dyn, KE}, E};
set_assign(T, _E) -> return_error(expr_loc(T), "SET needs a variable, a property (x.p) or a key (x['k']) on the left of =").

remove_target({prop, T, K}) -> {remove_prop, T, K};
remove_target({index, T, KE}) -> {remove_prop, T, {dyn, KE}};
remove_target(T) -> return_error(expr_loc(T), "REMOVE needs a property (x.p), a key (x['k']) or labels (x:L)").

expr_loc({var, _, L}) -> L;
expr_loc(T) when is_tuple(T) -> case element(tuple_size(T), T) of {_, _} = L -> L; _ -> 1 end;
expr_loc(_) -> 1.

%% 通用 CASE 的 WHEN 只能有一个条件
searched_alts(Alts) ->
    [case Ws of
         [W] -> {W, V};
         [W | _] -> return_error(expr_loc(W), "only the simple form CASE x WHEN a, b THEN … can list several values")
     end || {Ws, V} <- Alts].

%% 函数调用；shortestPath((a)-[*]-(b)) / allShortestPaths(…) 当表达式用（openCypher 2024.3 的 <shortest path
%% expression>）：改写成 COLLECT { MATCH p = shortestPath(…) RETURN p }（单条取 head）
call(Name, false, [{pattern_pred, Chain, PL}], Loc) when Name =:= <<"shortestpath">>; Name =:= <<"allshortestpaths">> ->
    Kind = case Name of <<"shortestpath">> -> single; _ -> all end,
    P = {var, <<"  sp">>, PL},
    Q = {query, [{match, false, [{part, P, {shortest, Kind, Chain, PL}}], undefined, Loc},
                 {return, false, {items, [{item, P, undefined}]}, [], undefined, undefined, Loc}]},
    Sub = {subq, collect, Q, Loc},
    case Kind of
        single -> {call, <<"head">>, false, [Sub], Loc};
        all -> Sub
    end;
call(Name, Distinct, Args, Loc) -> {call, Name, Distinct, Args, Loc}.

union({query, C1}, Mode, C2, Loc) -> {union, [{first, C1}, {Mode, lists:reverse(C2), Loc}]};
union({union, Parts}, Mode, C2, Loc) -> {union, Parts ++ [{Mode, lists:reverse(C2), Loc}]}.

%% 链式比较：左边已经是比较（a < b）时，a < b < c ⇒ a < b AND b < c（中间项求两次，没有副作用）。
cmp({op, Op0, _, Mid} = Left, Op, Right) when Op0 =:= '='; Op0 =:= '<>'; Op0 =:= '<'; Op0 =:= '<=';
                                              Op0 =:= '>'; Op0 =:= '>=' ->
    {op, 'and', Left, {op, Op, Mid, Right}};
cmp({op, 'and', _, {op, Op0, _, Mid}} = Left, Op, Right) when Op0 =:= '='; Op0 =:= '<>'; Op0 =:= '<';
                                                             Op0 =:= '<='; Op0 =:= '>'; Op0 =:= '>=' ->
    {op, 'and', Left, {op, Op, Mid, Right}};
cmp(Left, Op, Right) -> {op, Op, Left, Right}.

%% 带命名空间的函数调用 ns.f(…) / a.b.f(…)：名字小写；是不是已知函数在语义检查时看
%% （内置的 fts.* / search.* / 时间 / 空间函数，或注册的用户函数）。
paren({op, Op, _, _} = E) when Op =:= '='; Op =:= '<>'; Op =:= '<'; Op =:= '<='; Op =:= '>'; Op =:= '>=';
                               Op =:= 'and' -> {paren, E};
paren(E) -> E.

ns_call(E, Name, Args) ->
    case dotted(E) of
        {ok, Prefix, Loc} -> {call, string:lowercase(<<Prefix/binary, ".", Name/binary>>), false, Args, Loc};
        error -> return_error(element(tuple_size(E), E), "only namespaced functions (ns.name(…)) can be called this way")
    end.

dotted({var, NS, Loc}) -> {ok, NS, Loc};
dotted({prop, Inner, K}) ->
    case dotted(Inner) of
        {ok, P, Loc} -> {ok, <<P/binary, ".", K/binary>>, Loc};
        error -> error
    end;
dotted(_) -> error.

nulls(Dir, {ident, Loc, W}) ->
    case string:lowercase(W) of
        <<"first">> -> {Dir, first};
        <<"last">>  -> {Dir, last};
        _ -> return_error(Loc, "expected FIRST or LAST after NULLS")
    end.

count_star({ident, Loc, Name}) ->
    case string:lowercase(Name) of
        <<"count">> -> {count_star, Loc};
        _           -> return_error(Loc, "only count(*) accepts *")
    end.

shortest({ident, Loc, Name}, Chain) ->
    case string:lowercase(Name) of
        <<"shortestpath">>    -> {shortest, single, Chain, Loc};
        <<"allshortestpaths">> -> {shortest, all, Chain, Loc};
        _ -> return_error(Loc, "unknown path function " ++ binary_to_list(Name))
    end.

rel({Var, Types, VarLen, Props}, Dir, Loc) ->
    {rel, Var, Types, Props, Dir, VarLen, Loc}.

