%% -------------------------------------------------------------------
%%
%% mi: Merge-Index Data Store
%%
%% Copyright (c) 2007-2010 Basho Technologies, Inc. All Rights Reserved.
%%
%% -------------------------------------------------------------------
-module(mi_buffer).
-author("Rusty Klophaus <rusty@basho.com>").
-include("merge_index.hrl").
-export([
    new/1,
    filename/1,
    close_filehandle/1,
    delete/1,
    filesize/1,
    size/1,
    write/7, write/2,
    info/4,
    iterator/1, iterator/4, iterators/6
]).

-ifdef(TEST).
-ifdef(EQC).
-include_lib("eqc/include/eqc.hrl").
-endif.
-include_lib("eunit/include/eunit.hrl").
-endif.


-record(buffer, {
    filename,
    handle,
    table,
    size
}).

%%% Creates a disk-based append-mode buffer file with support for a
%%% sorted iterator.

%% Open a new buffer. Returns a buffer structure.
new(Filename) ->
    %% Open the existing buffer file...
    filelib:ensure_dir(Filename),
    {ok, DelayedWriteSize} = application:get_env(merge_index, buffer_delayed_write_size),
    {ok, DelayedWriteMS} = application:get_env(merge_index, buffer_delayed_write_ms),
    FuzzedWriteSize = trunc(mi_utils:fuzz(DelayedWriteSize, 0.1)),
    FuzzedWriteMS = trunc(mi_utils:fuzz(DelayedWriteMS, 0.1)),
    {ok, FH} = file:open(Filename, [read, write, raw, binary, {delayed_write, FuzzedWriteSize, FuzzedWriteMS}]),

    %% Read into an ets table...
    Table = ets:new(buffer, [duplicate_bag, public]),
    open_inner(FH, Table),
    {ok, Size} = file:position(FH, cur),

    %% Return the buffer.
    #buffer { filename=Filename, handle=FH, table=Table, size=Size }.

open_inner(FH, Table) ->
    case read_value(FH) of
        {ok, Postings} ->
            write_to_ets(Table, Postings),
            open_inner(FH, Table);
        eof ->
            ok
    end.

filename(Buffer) ->
    Buffer#buffer.filename.

delete(Buffer) ->
    ets:delete(Buffer#buffer.table),
    close_filehandle(Buffer),
    file:delete(Buffer#buffer.filename),
    file:delete(Buffer#buffer.filename ++ ".deleted"),
    ok.

close_filehandle(Buffer) ->
    file:close(Buffer#buffer.handle).

%% Return the current size of the buffer file.
filesize(Buffer) ->
    Buffer#buffer.size.

size(Buffer) ->
    ets:info(Buffer#buffer.table, size).

%% Write the value to the buffer.
%% Returns the new buffer structure.
write(Index, Field, Term, Value, Props, TS, Buffer) ->
    write([{Index, Field, Term, Value, Props, TS}], Buffer).

write(Postings, Buffer) ->
    %% Write to file...
    FH = Buffer#buffer.handle,
    BytesWritten = write_to_file(FH, Postings),

    %% Return a new buffer with a new tree and size...
    write_to_ets(Buffer#buffer.table, Postings),

    %% Return the new buffer.
    Buffer#buffer {
        size = (BytesWritten + Buffer#buffer.size)
    }.

%% Return the number of results under this IFT.
info(Index, Field, Term, Buffer) ->
    Table = Buffer#buffer.table,
    Key = {Index, Field, Term},
    length(ets:lookup(Table, Key)).

%% Return an iterator that traverses the entire buffer.
iterator(Buffer) ->
    Table = Buffer#buffer.table,
    List1 = lists:sort(ets:tab2list(Table)),
    List2 = [{I,F,T,V,K,P} || {{I,F,T},V,K,P} <- List1],
    fun() -> iterate_list(List2) end.
    
%% Return an iterator that traverses the values for a term in the buffer.
iterator(Index, Field, Term, Buffer) ->
    Table = Buffer#buffer.table,
    List1 = ets:lookup(Table, {Index, Field, Term}),
    List2 = [{V,K,P} || {_Key,V,K,P} <- List1],
    List3 = lists:sort(List2),
    fun() -> iterate_list(List3) end.

%% Return a list of iterators over a range.
iterators(Index, Field, StartTerm, EndTerm, Size, Buffer) ->
    Table = Buffer#buffer.table,
    Keys = mi_utils:ets_keys(Table),
    Filter = fun(Key) ->
                     Key >= {Index, Field, StartTerm} 
                         andalso 
                         Key =< {Index, Field, EndTerm}
                         andalso
                         (Size == all orelse erlang:size(element(3, Key)) == Size)
        end,
    MatchingKeys = lists:filter(Filter, Keys),
    [iterator(I,F,T, Buffer) || {I,F,T} <- MatchingKeys].

%% Turn a list into an iterator.
iterate_list([]) ->
    eof;
iterate_list([H|T]) ->
    {H, fun() -> iterate_list(T) end}.


%% ===================================================================
%% Internal functions
%% ===================================================================

read_value(FH) ->
    case file:read(FH, 4) of
        {ok, <<Size:32/unsigned-integer>>} ->
            {ok, B} = file:read(FH, Size),
            {ok, binary_to_term(B)};
        eof ->
            eof
    end.

write_to_file(FH, Terms) when is_list(Terms) ->
    %% Convert all values to binaries, count the bytes.
    B = term_to_binary(Terms),
    Size = erlang:size(B),
    Bytes = <<Size:32/unsigned-integer, B/binary>>,
    file:write(FH, Bytes),
    Size + 2.

write_to_ets(Table, Postings) ->
    ets:insert(Table, Postings).

%% %% ===================================================================
%% %% EUnit tests
%% %% ===================================================================
-ifdef(TEST).

-ifdef(EQC).

-define(QC_OUT(P),
        eqc:on_output(fun(Str, Args) -> io:format(user, Str, Args) end, P)).

-define(POW_2(N), trunc(math:pow(2, N))).

-define(FMT(Str, Args), lists:flatten(io_lib:format(Str, Args))).

g_iftv() ->
    non_empty(binary()).

g_i() ->
    non_empty(binary()).

g_f() ->
    non_empty(binary()).

g_t() ->
    non_empty(binary()).

g_ift() ->
    {g_i(), g_f(), g_t()}.

g_value() ->
    non_empty(binary()).

g_props() ->
    list({oneof([word_pos, offset]), choose(0, ?POW_2(31))}).

g_tstamp() ->
    choose(0, ?POW_2(31)).

g_ift_range(IFTs) ->
    ?SUCHTHAT({{I1, F1, _T1}=Start, {I2, F2, _T2}=End},
              {oneof(IFTs), oneof(IFTs)}, (End >= Start) andalso (I1 =:= I2) andalso (F1 =:= F2)).

fold_iterator(Itr, Fn, Acc0) ->
    fold_iterator_inner(Itr(), Fn, Acc0).

fold_iterator_inner(eof, _Fn, Acc) ->
    lists:reverse(Acc);
fold_iterator_inner({Term, NextItr}, Fn, Acc0) ->
    Acc = Fn(Term, Acc0),
    fold_iterator_inner(NextItr(), Fn, Acc).

fold_iterators([], _Fun, Acc) ->
    lists:reverse(Acc);
fold_iterators([Itr|Itrs], Fun, Acc0) ->
    Acc = fold_iterator(Itr, Fun, Acc0),
    fold_iterators(Itrs, Fun, Acc).

prop_basic_test(Root) ->
    ?FORALL(Entries, list({{g_iftv(), g_iftv(), g_iftv()}, g_iftv(), g_props(), g_tstamp()}),
            begin
                check_entries(Root, Entries)
            end).

prop_dups_test(Root) ->
    ?FORALL(Entries, list(default({{<<0>>,<<0>>,<<0>>},<<0>>,[],0},
                                  {{g_iftv(), g_iftv(), g_iftv()}, g_iftv(), g_props(), g_tstamp()})),
            begin
                check_entries(Root, Entries)
            end).

check_entries(Root, Entries) ->
    [file:delete(X) || X <- filelib:wildcard(filename:dirname(Root) ++ "/*")],
    Buffer = mi_buffer:write(Entries, mi_buffer:new(Root ++ "_buffer")),

    L1 = [{I, F, T, Value, Props, Tstamp}
          || {{I, F, T}, Value, Props, Tstamp} <- Entries],

    L2 = fold_iterator(mi_buffer:iterator(Buffer),
                       fun(Item, Acc0) -> [Item | Acc0] end, []),
    mi_buffer:delete(Buffer),
    equals(lists:sort(L1), lists:sort(L2)).

prop_iter_range_test(Root) ->
    ?LET({I, F}, {g_i(), g_f()},
         ?LET(IFTs, non_empty(list(frequency([{10, {I, F, g_t()}}, {1, g_ift()}]))),
              ?FORALL({Entries, Range},
                      {list({oneof(IFTs), g_value(), g_props(), g_tstamp()}), g_ift_range(IFTs)},
                      begin check_range(Root, Entries, Range) end))).

check_range(Root, Entries, Range) ->
    [file:delete(X) || X <- filelib:wildcard(filename:dirname(Root) ++ "/*")],
    Buffer = mi_buffer:write(Entries, mi_buffer:new(Root ++ "_buffer")),

    {Start, End} = Range,
    {Index, Field, StartTerm} = Start,
    {Index, Field, EndTerm} = End,
    Itrs = mi_buffer:iterators(Index, Field, StartTerm, EndTerm, all, Buffer),
    L1 = fold_iterators(Itrs, fun(Item, Acc0) -> [Item | Acc0] end, []),

    L2 = [{V, K, P}
          || {Ii, Ff, Tt, V, K, P} <- fold_iterator(mi_buffer:iterator(Buffer),
                                                    fun(I,A) -> [I|A] end, []),
             {Ii, Ff, Tt} >= Start, {Ii, Ff, Tt} =< End],
    mi_buffer:delete(Buffer),
    equals(lists:sort(L1), lists:sort(L2)).

prop_basic_test_() ->
    test_spec("/tmp/test/mi_buffer_basic", fun prop_basic_test/1).

prop_dups_test_() ->
    test_spec("/tmp/test/mi_buffer_basic", fun prop_dups_test/1).

prop_iter_range_test_() ->
    test_spec("/tmp/test/mi_buffer_iter", fun prop_iter_range_test/1).

test_spec(Root, PropertyFn) ->
    {timeout, 60, fun() ->
                          application:load(merge_index),
                          os:cmd(?FMT("rm -rf ~s; mkdir -p ~s", [Root, Root])),
                          ?assert(eqc:quickcheck(eqc:numtests(250, ?QC_OUT(PropertyFn(Root ++ "/t1")))))
                  end}.

-endif. %EQC
-endif.
