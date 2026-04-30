%% bitcask 公共头文件。
%%
%% M6 之后这里只剩一条记录定义：iterator_next/1 和 fold_keys 的回调
%% 都需要返回 #bitcask_entry{}，所以保留这个外部契约。其它 legacy
%% 时代用的 file 头部宏（OFFSETFIELD / TSTAMPFIELD 等）和 #filestate /
%% #file_status 记录已经全部下沉到 C++ format 模块，这里不再暴露。
%%
%% offset 字段允许是 integer 或 binary：bitcask_cpp_nifs 旧的细粒度
%% keydir_get 会拿到 64-bit native binary 形态，自己拆包成 integer；
%% cask_cpp 走的 cask_iterator_next / cask_fold_next_full 直接给
%% integer。两种来源的下游处理一致。

-record(bitcask_entry, { key      :: binary(),
                         file_id  :: integer(),
                         total_sz :: integer(),
                         offset   :: integer() | binary(),
                         tstamp   :: integer() }).
