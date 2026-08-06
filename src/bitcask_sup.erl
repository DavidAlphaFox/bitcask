%% =========================================================================
%% bitcask_sup
%%
%%   bitcask 的顶层 supervisor。child：
%%
%%     bitcask_merge_worker    — 全局 merge 调度器（窗口 + 去重 + 限流）
%%     bitcask_embedder_server — **可选**，只在 application env 里配了
%%                               {embedder, Spec} 时才有。见下。
%%
%%   旧的 bitcask_merge_delete 已经随 legacy 一并删除——cask_cpp 在
%%   merge 完成时直接 unlink 掉旧 data file，不需要单独的延迟删除 worker
%%   来跟 fold 迭代器协调。
%%
%%   重启策略 one_for_one：一个挂掉只重启它自己。
%%   maxR=5, maxT=10：10 秒内重启 5 次以上就放弃，让上层 application 决定怎么办。
%%
%%   === embedder（可选 child） ===
%%
%%   application env：
%%
%%     {bitcask, [{embedder,
%%         #{name     => my_embedder,     %% 可选注册名；缺省只有 pid
%%           provider => {custom, bitcask_embedder_llama},
%%           config   => #{model_path => <<"/models/qwen3-emb.gguf">>,
%%                         pooling => last, n_ctx => 512}}}]}
%%
%%   多卡（数据并行，一卡一个 instance）加 instances，此时 name 必填：
%%
%%     {bitcask, [{embedder,
%%         #{name      => my_embedder,
%%           provider  => {custom, bitcask_embedder_llama},
%%           instances => [0, 1, 2, 3],   %% 或 [[0,1],[2,3]]（单卡装不下时）/ auto
%%           config    => #{model_path => ..., pooling => last}}}]}
%%
%%   **没配就没有这个 child**——bitcask 不依赖 embedder，绝大多数部署不配。
%%
%%   ⚠️ **配了却起不来（路径写错、pooling 解析成 NONE …）会让整个 bitcask
%%      application 起不来，这是有意的。** 配置了嵌入模型就说明业务要用它，
%%      此时"静静地降级成没有嵌入能力"比当场死掉危险得多：前者要等到检索
%%      结果不对才发现，而那时候库已经写脏了（向量维度/语义都不对）。
%%      配合 bitcask:open/2 不再吞 application:start 的失败，用户会当场看到
%%      `{error, {bitcask_app_start_failed, _}}` 而不是一个装作正常的句柄。
%%
%% Copyright (c) 2010 Basho Technologies, Inc. — Apache License 2.0.
%% =========================================================================
-module(bitcask_sup).

-behaviour(supervisor).

-ifdef(PULSE).
-compile({parse_transform, pulse_instrument}).
-include_lib("pulse_otp/include/pulse_otp.hrl").
-endif.

-export([start_link/0]).
-export([init/1]).

%% supervisor child spec 缩写：永久子进程，shutdown 等 5s。
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{one_for_one, 5, 10},
          [?CHILD(bitcask_merge_worker, worker) | embedder_children()]}}.

%% application env 里配了 {embedder, Spec} 才有这个 child。
%%
%% Spec 里 name 可选：给了就注册（`{embedder, my_embedder}` 那样按名字引用），
%% 不给就只能拿 pid（supervisor:which_children/1 里找）。
embedder_children() ->
    case application:get_env(bitcask, embedder) of
        undefined       -> [];
        {ok, undefined} -> [];
        {ok, Spec} when is_map(Spec) ->
            Opts = maps:without([name], Spec),
            Name = maps:get(name, Spec, undefined),
            case maps:is_key(instances, Spec) of
                true ->
                    %% 池：N 个各绑一张（组）卡的 worker，数据并行。
                    %% ⚠️ 必须有注册名——worker 的稳定名字由池名派生。
                    case Name of
                        N when is_atom(N), N =/= undefined ->
                            [bitcask_embedder_pool:child_spec(
                               bitcask_embedder, {local, N}, Opts)];
                        _ ->
                            erlang:error({bad_embedder_env,
                                          {instances_requires_name, Name}})
                    end;
                false ->
                    case Name of
                        undefined ->
                            [bitcask_embedder_server:child_spec(bitcask_embedder, Opts)];
                        N when is_atom(N) ->
                            [bitcask_embedder_server:child_spec(
                               bitcask_embedder, {local, N}, Opts)];
                        N ->
                            %% {global,_} / {via,_,_} 原样透给 gen_server:start_link/4
                            [bitcask_embedder_server:child_spec(bitcask_embedder, N, Opts)]
                    end
            end;
        {ok, Bad} ->
            %% 配错了就当场死，别静静地不起——这条与"配了模型却起不来要死掉"
            %% 是同一个判断：embedder 的配置错误必须在启动期可见。
            erlang:error({bad_embedder_env, Bad})
    end.
