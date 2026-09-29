%% -------------------------------------------------------------------
%% bitcask_test_util: 测试共用的小工具。
%%
%%   with_dir(Prefix, Fun)：建一个唯一的临时目录交给 Fun，结束后删掉。
%%   以前每个测试模块各拷一份，写死 /tmp、用 os:cmd("rm -rf ...") 删
%%   （每次 fork 一个 shell）。现在认 TMPDIR（没设才用 /tmp），用
%%   file:del_dir_r/1 删。
%% -------------------------------------------------------------------
-module(bitcask_test_util).

-export([with_dir/2, tmp_root/0]).

-spec with_dir(string(), fun((string()) -> T)) -> T.
with_dir(Prefix, Fun) ->
    Dir = filename:join(tmp_root(),
                        Prefix ++ os:getpid() ++ "_" ++
                            integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_path(Dir),
    try Fun(Dir)
    after _ = file:del_dir_r(Dir)
    end.

tmp_root() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        ""    -> "/tmp";
        T     -> T
    end.
