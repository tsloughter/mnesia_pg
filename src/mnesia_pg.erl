%%%
%%% Copyright (c) 2014-2015 Klarna AB
%%%
%%% This file is provided to you under the Apache License,
%%% Version 2.0 (the "License"); you may not use this file
%%% except in compliance with the License.  You may obtain
%%% a copy of the License at
%%%
%%%   http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing,
%%% software distributed under the License is distributed on an
%%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%%% KIND, either express or implied.  See the License for the
%%% specific language governing permissions and limitations
%%% under the License.

%% TODO:
%% io wait is high
%% index is scanned?

%%%header_doc_include

-module(mnesia_pg).

%% ----------------------------------------------------------------------------
%% BEHAVIOURS
%% ----------------------------------------------------------------------------

-behaviour(mnesia_backend_type).

%% ----------------------------------------------------------------------------
%% EXPORTS
%% ----------------------------------------------------------------------------

%%
%% CONVENIENCE API
%%

-export([register/0,
         dbg/1,
         default_alias/0]).

%%
%% DEBUG API
%%

-export([show_table/1,
         show_table/2,
         show_table/3,
         fold/6]).

%%
%% BACKEND CALLBACKS
%%

%% backend management
-export([init_backend/0,
         add_aliases/1,
         remove_aliases/1]).

%% schema level callbacks
-export([semantics/2,
         check_definition/4,
         create_table/3,
         load_table/4,
         close_table/2,
         sync_close_table/2,
         delete_table/2,
         info/3]).

%% table synch calls
-export([sender_init/4,
         sender_handle_info/5,
         receiver_first_message/4,
         receive_data/5,
         receive_done/4]).

%% low-level accessor callbacks.
-export([delete/3,
         first/2,
         fixtable/3,
         insert/3,
         last/2,
         lookup/3,
         match_delete/3,
         next/3,
         prev/3,
         repair_continuation/2,
         select/1,
         select/3,
         select/4,
         slot/3,
         update_counter/4]).

%% Index consistency
-export([index_is_consistent/3,
         is_index_consistent/2]).

%% record and key validation
-export([validate_key/6,
         validate_record/6]).

%% file extension callbacks
-export([real_suffixes/0,
         tmp_suffixes/0]).

-export([ix_prefixes/3]).

%%%header_doc_include

%%%impl_doc_include

%% ----------------------------------------------------------------------------
%% INCLUDES
%% ----------------------------------------------------------------------------

-include_lib("mnesia/src/mnesia.hrl").
-include_lib("kernel/include/file.hrl").

%% ----------------------------------------------------------------------------
%% DEFINES
%% ----------------------------------------------------------------------------

%% Data and meta data (a.k.a. info) are stored in the same table.
%% This is a table of the first byte in data
%% 0    = before meta data
%% 1    = meta data
%% 2    = before data
%% >= 8 = data

-ifdef(DEBUG).
-define(dbg(E), E).
-else.
-define(dbg(E), ok).
-endif.
%% ----------------------------------------------------------------------------
%% RECORDS
%% ----------------------------------------------------------------------------

-record(sel, {alias,                            % TODO: not used
             tab,
             ref,
             keypat,
             limit}).

%% ----------------------------------------------------------------------------
%% CONVENIENCE API
%% ----------------------------------------------------------------------------

register() ->
    Alias = default_alias(),
    Module = ?MODULE,
    mnesia:add_backend_type(Alias, Module),
    {ok, {Alias, Module}}.

default_alias() ->
    pg_copies.


%% ----------------------------------------------------------------------------
%% DEBUG API
%% ----------------------------------------------------------------------------

%% A debug function that shows the table content
show_table(Tab) ->
    show_table(default_alias(), Tab).

show_table(Alias, Tab) ->
    show_table(Alias, Tab, 100).

show_table(Alias, Tab, Limit) ->
    {C, _} = Ref = get_ref(Alias, Tab),
    try
        with_iterator(Ref, fun(Curs) -> i_show_table(Curs, Limit) end)
    after
        mnesia_pg_conns:free(C)
    end.

%% PRIVATE

i_show_table(_, 0) ->
    {error, skipped_some};
i_show_table(Curs, Limit) ->
    case fetch_next(Curs) of
        {ok, EncKey, EncVal} ->
            K = decode_key(EncKey),
            V = decode_val(EncVal),
            io:fwrite("~p: ~p~n", [K, V]),
            i_show_table(Curs, Limit-1);
        _ ->
            ok
    end.

%% ----------------------------------------------------------------------------
%% BACKEND CALLBACKS
%% ----------------------------------------------------------------------------

%% backend management

init_backend() ->
    application:start(mnesia_pg).

add_aliases(_Aliases) ->
    ok.

remove_aliases(_Aliases) ->
    ok.

%% schema level callbacks

%% This function is used to determine what the plugin supports
%% semantics(Alias, storage)   ->
%%    ram_copies | disc_copies | disc_only_copies  (mandatory)
%% semantics(Alias, types)     ->
%%    [bag | set | ordered_set]                    (mandatory)
%% semantics(Alias, index_fun) ->
%%    fun(Alias, Tab, Pos, Obj) -> [IxValue]       (optional)
%% semantics(Alias, _) ->
%%    undefined.
%%
semantics(_Alias, storage) -> disc_only_copies;
semantics(_Alias, types  ) -> [set, ordered_set];
semantics(_Alias, index_types) -> [ordered];
semantics(_Alias, index_fun) -> fun index_f/4;
semantics(_Alias, _) -> undefined.

is_index_consistent(_Alias, _) ->
    true.

index_is_consistent(_Alias, _, __Bool) ->
    ok.

%% PRIVATE FUN
index_f(_Alias, _Tab, Pos, Obj) ->
    [element(Pos, Obj)].

ix_prefixes(_Tab, _Pos, Obj) ->
    lists:foldl(
      fun(V, Acc) when is_list(V) ->
              try Pfxs = prefixes(list_to_binary(V)),
                   Pfxs ++ Acc
              catch
                  error:_ ->
                      Acc
              end;
         (V, Acc) when is_binary(V) ->
              Pfxs = prefixes(V),
              Pfxs ++ Acc;
         (_, Acc) ->
              Acc
      end, [], tl(tuple_to_list(Obj))).

prefixes(<<P:3/binary, _/binary>>) ->
    [P];
prefixes(_) ->
    [].

%% For now, only verify that the type is set or ordered_set.
%% set is OK as ordered_set is a kind of set.
check_definition(Alias, Tab, Nodes, Props) ->
    Id = {Alias, Nodes},
    Props1 = lists:map(
               fun({type, T} = P) ->
                       if T==set; T==ordered_set ->
                               P;
                          true ->
                               mnesia:abort({combine_error,
                                             Tab,
                                             [Id, {type,T}]})
                       end;
                  ({user_properties, _} = P) ->
                       P;
                  (P) -> P
               end, Props),
    {ok, Props1}.

-ifdef(DEBUG).
pp_calls(I, [{M,F,A,Pos} | T]) ->
    Spc = lists:duplicate(I, $\s),
    Pp = fun(Mx,Fx,Ax,Px) ->
                 [atom_to_list(Mx),":",atom_to_list(Fx),"/",integer_to_list(Ax),
                  pp_pos(Px)]
         end,
    [Pp(M,F,A,Pos)|[["\n",Spc,Pp(M1,F1,A1,P1)] || {M1,F1,A1,P1} <- T]].
pp_pos([]) -> "";
pp_pos(L) when is_integer(L) ->
    [" (", integer_to_list(L), ")"];
pp_pos([{file,_},{line,L}]) ->
    [" (", integer_to_list(L), ")"].

dbg_caller() ->
    try 1=2
    catch
        error:_ ->
            tl(erlang:get_stacktrace())
    end.
-endif.

sync_close_table(_Alias, _Tab) ->
    ok.

info(Alias, Tab, size) ->
    table_count(Alias, Tab);			% not fast...
info(Alias, Tab, memory) ->
    table_size(Alias, Tab);
info(_Alias, _Tab, _) ->
    undefined.

%% ===========================================================
%% Table synch protocol
%% Callbacks are
%% Sender side:
%%  1. sender_init(Alias, Tab, RemoteStorage, ReceiverPid) ->
%%        {standard, InitFun, ChunkFun} | {InitFun, ChunkFun} when
%%        InitFun :: fun() -> {Recs, Cont} | '$end_of_table'
%%        ChunkFun :: fun(Cont) -> {Recs, Cont1} | '$end_of_table'
%%
%%       If {standard, I, C} is returned, the standard init message will be
%%       sent to the receiver. Matching on RemoteStorage can reveal if a
%%       different protocol can be used.
%%
%%  2. InitFun() is called
%%  3a. ChunkFun(Cont) is called repeatedly until done
%%  3b. sender_handle_info(Msg, Alias, Tab, ReceiverPid, Cont) ->
%%        {ChunkFun, NewCont}
%%
%% Receiver side:
%% 1. receiver_first_message(SenderPid, Msg, Alias, Tab) ->
%%        {Size::integer(), State}
%% 2. receive_data(Data, Alias, Tab, _Sender, State) ->
%%        {more, NewState} | {{more, Msg}, NewState}
%% 3. receive_done(_Alias, _Tab, _Sender, _State) ->
%%        ok
%%
%% The receiver can communicate with the Sender by returning
%% {{more, Msg}, St} from receive_data/4. The sender will be called through
%% sender_handle_info(Msg, ...), where it can adjust its ChunkFun and
%% Continuation. Note that the message from the receiver is sent once the
%% receive_data/4 function returns. This is slightly different from the
%% normal mnesia table synch, where the receiver acks immediately upon
%% reception of a new chunk, then processes the data.
%%

sender_init(Alias, Tab, _RemoteStorage, _Pid) ->
    %% Need to send a message to the receiver. It will be handled in
    %% receiver_first_message/4 below. There could be a volley of messages...
    {standard,
     fun() ->
             select(Alias, Tab, [{'_',[],['$_']}], 100)
     end,
     chunk_fun()}.

sender_handle_info(_Msg, _Alias, _Tab, _ReceiverPid, Cont) ->
    %% ignore - we don't expect any message from the receiver
    {chunk_fun(), Cont}.

receiver_first_message(_Pid, {first, Size} = _Msg, _Alias, _Tab) ->
    {Size, _State = []}.

receive_data(Data, Alias, Tab, _Sender, State) ->
    [insert(Alias, Tab, Obj) || Obj <- Data],
    {more, State}.

receive_done(_Alias, _Tab, _Sender, _State) ->
    ok.

chunk_fun() ->
    fun(Cont) ->
            select(Cont)
    end.

%% End of table synch protocol
%% ===========================================================

delete(Alias, Tab, Key) ->
    delete_from(Alias, Tab, encode_key(Key)).

%% Not relevant for an ordered_set
fixtable(_Alias, _Tab, _Bool) ->
    true.

insert(Alias, Tab, Obj) ->
    Pos = keypos(Tab),
    Key = element(Pos, Obj),
    PKey = encode_key(Key),
    SKey = encode_lookup_key(Key),
    Val = encode_val(Obj),
    upsert_into(Alias, Tab, PKey, SKey, Val).

find_row(_, _, []) ->
    [];
find_row(_, _, [Row]) ->
    [decode_val(element(1,Row))];
find_row(Key, Pos, [Row|Rs]) ->
    Rec = decode_val(element(1,Row)),
    case element(Pos, Rec) of
        Key ->
            [Rec];
        _ ->
            find_row(Key, Pos, Rs)
    end.

lookup(Alias, Tab0, Key) ->
    {C, Tab} = get_ref(Alias, Tab0),
    SKey = encode_lookup_key(Key),
    try
        {_, Rs} = pgsql_connection:extended_query(["select erlval from ", Tab, " where erlhash=$1"], [SKey], C),
        find_row(Key, keypos(Tab0), Rs)
    after
        mnesia_pg_conns:free(C)
    end.

match_delete(Alias, Tab, Pat) when is_atom(Pat) ->
    case is_wild(Pat) of
        true ->
            delete_all(Alias, Tab),
            ok;
        false ->
            %% can this happen??
            error(badarg)
    end;
match_delete(Alias, Tab, Pat) when is_tuple(Pat) ->
    KP = keypos(Tab),
    Key = element(KP, Pat),
    case is_wild(Key) of
        true ->
            delete_all(Alias, Tab),
            ok;
        false ->
            delete_from_pattern(Alias, Tab, Pat)
    end,
    ok.

%% It is tempting to use a cursor for next/prev, however, the ets semantics, used by mnesia,
%% imply that any call to next (prev) may position itself right after (before) the given key,
%% which may not always be the next row in logical order. As there is no open call,
%% it is not clear how to open a cursor that can be leveraged to efficiently find
%% a proper segment to iterate through.
%% Note: prev for a set in mnesia/ets equals next (sic!)
next(Alias, Tab0, Key) ->
    {C, Tab} = get_ref(Alias, Tab0),
    try
        {_, Res} = pgsql_connection:extended_query(["select erlkey from ", Tab, " where erlkey > $1 order by erlkey limit 1"], [encode_key(Key)], C),
        case (Res) of
            [] ->
                '$end_of_table';
            [{TKey}] ->				%check pattern
                decode_key(TKey)
        end
    after
        mnesia_pg_conns:free(C)
    end.

prev(Alias, Tab0, Key) ->
    {C, Tab} = get_ref(Alias, Tab0),
    try
        {_, Res} = pgsql_connection:extended_query(["select erlkey from ", Tab, " where erlkey < $1 order by erlkey desc limit 1"], [encode_key(Key)], C),
        case (Res) of
            [] ->
                '$end_of_table';
            [{TKey}] ->
                decode_key(TKey)
        end
    after
        mnesia_pg_conns:free(C)
    end.

first(Alias, Tab0) ->
    {C, Tab} = get_ref(Alias, Tab0),
    try
        {_, Res} = pgsql_connection:extended_query(["select erlkey from ", Tab, " order by erlkey limit 1"], [], C),
        case (Res) of
            [] ->
                '$end_of_table';
            [{TKey}] ->
                decode_key(TKey)
        end
    after
        mnesia_pg_conns:free(C)
    end.

last(Alias, Tab0) ->
    {C, Tab} = get_ref(Alias, Tab0),
    try
        {_, Res} = pgsql_connection:extended_query(["select erlkey from ", Tab, " order by erlkey desc limit 1"], [], C),
        case (Res) of
            [] ->
                '$end_of_table';
            [{TKey}] ->
                decode_key(TKey)
        end
    after
        mnesia_pg_conns:free(C)
    end.

prefix_get({C, Tab}, IsPfx, Pfx) ->
    {Where,Vs} = case IsPfx of
                     true  -> {"erlkey >= $1", [Pfx]};
                     false -> {"erlkey = $1", [Pfx]}
                 end,
    {_, Res} =
        pgsql_connection:extended_query(["select erlkey, erlval from ", Tab, " where ",
                                         Where, " order by erlkey limit 2"], Vs, C),
    Res.

prefix_next({C, Tab}, IsPfx, Pfx) ->
    {Where,Vs} = case IsPfx of
                     true  -> {"erlkey >= $1", [Pfx]};
                     false -> {"erlkey > $1", [Pfx]}
                 end,
    {_, Res} =
        pgsql_connection:extended_query(["select erlkey, erlval from ", Tab, " where ",
                                         Where, " order by erlkey limit 2"], Vs, C),
    Res.

repair_continuation(Cont, _Ms) ->
    Cont.

select(C) ->
    Cont = get_sel_cont(C),
    Cont().

select(Alias, Tab, Ms) ->
    case select(Alias, Tab, Ms, infinity) of
        {Res, '$end_of_table'} ->
            Res;
        '$end_of_table' ->
            '$end_of_table'
    end.

select(Alias, Tab0, Ms, Limit) when Limit==infinity; is_integer(Limit) ->
    {C, _} = Ref = get_ref(Alias, Tab0),
    try
        do_select(Ref, Tab0, Ms, Limit)
    after
        mnesia_pg_conns:free(C)
    end.

slot(Alias, Tab0, Pos) when is_integer(Pos), Pos >= 0 ->
    {C, _} = Ref = get_ref(Alias, Tab0),
    F = fun(Curs) -> slot_iter_set(fetch_next(Curs), Curs, 0, Pos) end,
    try
        with_iterator(Ref, F)
    after
        mnesia_pg_conns:free(C)
    end;
slot(_, _, _) ->
    error(badarg).


%% Exactly which objects Mod:slot/2 is supposed to return is not defined,
%% so let's just use the same version for both set and bag. No one should
%% use this function anyway, as it is ridiculously inefficient.
slot_iter_set({ok, _K, V}, _Curs, P, P) ->
    [decode_val(V)];
slot_iter_set({ok, _, _}, Curs, P1, P) when P1 < P ->
    slot_iter_set(fetch_next(Curs), Curs, P1+1, P);
slot_iter_set(Res, _, _, _) when element(1, Res) =/= ok ->
    '$end_of_table'.

%% update value of key by incrementing
%% need select for update since the value in erlval is an int encoded as a binary
update_counter(Alias, Tab0, Key, Val) when is_integer(Val) ->
    {C, Tab} = get_ref(Alias, Tab0),
    PKey = encode_key(Key),
    try
        pgsql_connection:simple_query("begin", C),
        {_, Res} = pgsql_connection:extended_query(["select erlval from ", Tab, " where erlkey=$1 for update"], [PKey], C),
        case (length(Res)) of
            0 ->
                pgsql_connection:simple_query("commit", C),
                badarg;
            _ ->
                [Row] = Res,
                Rec = decode_val(element(1, Row)),
                case Rec of
                    {T,K,Old} when is_integer(Old) ->
                        New = Old+Val,
                        {_, _} = pgsql_connection:extended_query(
                                   ["update ", Tab, " set erlval=$2, change_time=current_timestamp where erlkey=$1"],
                                   [PKey, encode_val({T,K,New})], C
                                  ),
                        pgsql_connection:simple_query("commit", C);
                    _ ->
                        pgsql_connection:simple_query("rollback", C),
                        New = badarg
                end,
                New
        end
    after
        mnesia_pg_conns:free(C)
    end.

%% PRIVATE

with_iterator({C, Tab}, F) ->
    Curs = open_cursor(C, Tab),
    try
        R = F(Curs),
        commit_cursor(Curs),
        R
    catch
        error:Reason ->
            io:fwrite("Cursor ~p failed (~p): ~p~n", [Curs, Reason, erlang:get_stacktrace()]),
            rollback_cursor(Curs),
            '$end_of_table'
    end.

with_positioned_iterator({C, Tab}, Pat, F) ->
    Curs = open_cursor(C, Tab, Pat),
    try
        R = F(Curs),
        commit_cursor(Curs),
        R
    catch
        error:Reason ->
            io:fwrite("Cursor ~p failed (~p): ~p~n", [Curs, Reason, erlang:get_stacktrace()]),
            rollback_cursor(Curs),
            '$end_of_table'
    end.

%% record and key validation

validate_key(_Alias, _Tab, RecName, Arity, Type, _Key) ->
    {RecName, Arity, Type}.

validate_record(_Alias, _Tab, RecName, Arity, Type, _Obj) ->
    {RecName, Arity, Type}.

%% file extension callbacks

%% Extensions for files that are permanent. Needs to be cleaned up
%% e.g. at deleting the schema.
real_suffixes() ->
    [].

%% Extensions for temporary files. Can be cleaned up when mnesia
%% cleans up other temporary files.
tmp_suffixes() ->
    [].

%% ----------------------------------------------------------------------------
%% PRIVATE SELECT MACHINERY
%% ----------------------------------------------------------------------------

do_select(Ref, Tab, MS, Limit) ->
    do_select(Ref, Tab, MS, false, Limit).

do_select(Ref, Tab, MS, AccKeys, Limit) when is_boolean(AccKeys) ->
    Keypat = keypat(MS, keypos(Tab)),
    Sel = #sel{ref = Ref,
               keypat = Keypat,
               limit = Limit},
    {IsPfx, Pfx, _} = Keypat,
    CompMS = ets:match_spec_compile(MS),
    select_traverse(prefix_get(Ref, IsPfx, Pfx), Ref, Limit, Pfx, IsPfx, Pfx,
                    CompMS, Sel, AccKeys, []).
%% case (Pfx) of
%%  <<>> ->
%%      with_iterator(Ref,
%%            fun(Curs) ->
%%                select_traverse(fetch_next_n(Curs), Curs, Limit, Pfx, CompMS, Sel, AccKeys, [])
%%            end);
%%  _ ->
%%      with_positioned_iterator(Ref, Pfx,
%%                   fun(Curs) ->
%%                       select_traverse(fetch_next_n(Curs), Curs, Limit, Pfx, CompMS, Sel, AccKeys, [])
%%                   end)
%% end.

extract_vars([H|T]) ->
    extract_vars(H) ++ extract_vars(T);
extract_vars(T) when is_tuple(T) ->
    extract_vars(tuple_to_list(T));
extract_vars(T) when T=='$$'; T=='$_' ->
    [T];
extract_vars(T) when is_atom(T) ->
    case is_wild(T) of
        true ->
            [T];
        false ->
            []
    end;
extract_vars(_) ->
    [].

intersection(A,B) when is_list(A), is_list(B) ->
    A -- (A -- B).

select_traverse([_|_] = L, Curs, Limit, Pfx, IsPfx, Prev, MS, Sel, AccKeys, Acc) ->
    select_traverse_(L, Curs, Limit, Pfx, IsPfx, Prev, MS, Sel, AccKeys, Acc);
select_traverse([], _, _, _, _, _, _, _, _, Acc) ->
    {lists:reverse(Acc), '$end_of_table'}.

select_traverse_([{K,V}|T], Curs, Limit, Pfx, _, Prev, MS, Sel, AccKeys, Acc) ->
    case is_prefix(Pfx, K) of
        true ->
            Rec = decode_val(V),
            case ets:match_spec_run([Rec], MS) of
                [] ->
                    select_traverse_(T, Curs, Limit, Pfx, false, K,
                                     MS, Sel, AccKeys, Acc);
                [Match] ->
                    Fun = fun(NewLimit, NewAcc) ->
                                  select_traverse_(
                                    T, Curs, NewLimit, Pfx, false, K,
                                    MS, Sel, AccKeys, NewAcc)
                          end,
                    Acc1 = if AccKeys ->
                                   [{K, Match}|Acc];
                              true ->
                                   [Match|Acc]
                           end,
                    traverse_continue(decr(Limit), Fun, Acc1, Sel)
            end;
        false ->
            {lists:reverse(Acc), '$end_of_table'}
    end;
select_traverse_([], Curs, Limit, Pfx, IsPfx, Prev, MS, Sel, AccKeys, Acc) ->
    select_traverse(prefix_next(Curs, IsPfx, Prev),
                    Curs, Limit, Pfx, IsPfx, Prev, MS, Sel, AccKeys, Acc).



is_prefix(A, B) when is_binary(A), is_binary(B) ->
    Sa = byte_size(A),
    case B of
        <<A:Sa/binary, _/binary>> ->
            true;
        _ ->
            false
    end.

decr(I) when is_integer(I) ->
    I-1;
decr(infinity) ->
    infinity.

traverse_continue(0, F, Acc, #sel{limit = Limit, ref = Ref}) ->
    {lists:reverse(Acc),
     fun() ->
             with_iterator(Ref,
                           fun(_) ->
                                   F(Limit, [])
                           end)
     end};
traverse_continue(Limit, F, Acc, _) ->
    F(Limit, Acc).

keypat([{HeadPat,Gs,_}|_], KeyPos) when is_tuple(HeadPat) ->
    KP      = element(KeyPos, HeadPat),
    KeyVars = extract_vars(KP),
    Guards  = relevant_guards(Gs, KeyVars),
    {IsPfx,Pfx} = mnesia_sext:enc_prefix_sb32(KP),
    {IsPfx, Pfx, [{KP, Guards, [true]}]};
keypat(_, _) ->
    {true, <<>>, [{'_',[],[true]}]}.

relevant_guards(Gs, Vars) ->
    case Vars -- ['_'] of
        [] ->
            [];
        Vars1 ->
            Fun =
                fun(G) ->
                        Vg = extract_vars(G),
                        intersection(Vg, Vars1) =/= [] andalso (Vg--Vars1) == []
                end,
            lists:filter(Fun, Gs)
    end.

get_sel_cont(C) ->
    Cont = case C of
               {?MODULE, C1} -> C1;
               _ -> C
           end,
    case Cont of
        _ when is_function(Cont, 0) ->
            case erlang:fun_info(Cont, module) of
                {_, ?MODULE} ->
                    Cont;
                _ ->
                    erlang:error(badarg)
            end;
        '$end_of_table' ->
            fun() -> '$end_of_table' end;
        _ ->
            erlang:error(badarg)
    end.


%% ----------------------------------------------------------------------------
%% COMMON PRIVATE
%% ----------------------------------------------------------------------------

%% Note that since a callback can be used as an indexing backend, we
%% cannot assume that keypos will always be 2. For indexes, the tab
%% name will be {Tab, index, Pos}, and The object structure will be
%% {{IxKey,Key}} for an ordered_set index, and {IxKey,Key} for a bag
%% index.
%%
keypos({_, index, _}) ->
    1;
keypos({_, retainer, _}) ->
    2;
keypos(Tab) when is_atom(Tab) ->
    2.

encode_lookup_key(Key) ->
    erlang:phash2(Key).  % not necessarily unique, but good for lookups

encode_key_prefix(Key) ->
    mnesia_sext:enc_prefix_sb32(Key).

encode_key(Key) ->
    mnesia_sext:encode_sb32(Key).

decode_key(CodedKey) ->
    mnesia_sext:decode_sb32(CodedKey).

encode_val(Val) ->
    term_to_binary(Val).  %term_to_binary(Val,[{compressed,5},{minor_version, 1}]).

decode_val(CodedVal) ->
    binary_to_term(CodedVal).

fold(Alias, Tab0, Fun, Acc, MS, N) ->
    {C, _} = Ref = get_ref(Alias, Tab0),
    try
        do_fold(Ref, Tab0, Fun, Acc, MS, N)
    after
        mnesia_pg_conns:free(C)
    end.

do_fold(Ref, Tab, Fun, Acc, MS, N) ->
    {AccKeys, F} =
        if is_function(Fun, 3) ->
                {true, fun({K,Obj}, Acc1) ->
                               Fun(Obj, K, Acc1)
                       end};
           is_function(Fun, 2) ->
                {false, Fun}
        end,
    do_fold1(do_select(Ref, Tab, MS, AccKeys, N), F, Acc).

do_fold1('$end_of_table', _, Acc) ->
    Acc;
do_fold1({L, Cont}, Fun, Acc) ->
    Acc1 = lists:foldl(Fun, Acc, L),
    do_fold1(select(Cont), Fun, Acc1).

is_wild('_') ->
    true;
is_wild(A) when is_atom(A) ->
    case atom_to_list(A) of
        "\$" ++ S ->
            try begin
                    _ = list_to_integer(S),
                    true
                end
            catch
                error:_ ->
                    false
            end;
        _ ->
            false
    end;
is_wild(_) ->
    false.


%% PG interface
%% Each table has 3 columns: encoded key encoded value change time
open_cursor(C, Tab) ->
    CursorName = "cursor_" ++ Tab ++ integer_to_list(mnesia_pg_conns:ref()),
    pgsql_connection:simple_query("begin", C),
    pgsql_connection:simple_query(["declare ", CursorName, " cursor for select erlkey,erlval from ", Tab, " order by erlkey asc"], C),
    {C, CursorName}.

open_cursor(C, Tab, Pat) ->
    CursorName = "cursor_" ++ Tab ++ integer_to_list(mnesia_pg_conns:ref()),
    pgsql_connection:simple_query("begin", C),
    pgsql_connection:simple_query(["declare ", CursorName, " cursor for select erlkey,erlval from ", Tab, " where erlkey >= '", Pat, "' order by erlkey asc"], C),
    {C, CursorName}.

commit_cursor({C, CursorName}) ->
    pgsql_connection:simple_query(["close ", CursorName], C),
    pgsql_connection:simple_query("commit", C).

rollback_cursor({C, CursorName}) ->
    pgsql_connection:simple_query(["close ", CursorName], C),
    pgsql_connection:simple_query("rollback", C).

fetch_next({C, CursorName}) ->
    Res = pgsql_connection:extended_query(["fetch next from ", CursorName], [], C),
    case (Res) of
        {{_, 0}, _} ->
            void;
        {_, [R]} ->
            {ok, element(1, R), element(2, R)}
    end.

fetch_next_n(C) ->
    fetch_next_n(1, C).

fetch_next_n(N, {C, CursorName}) ->
    Res = pgsql_connection:extended_query(["fetch ", integer_to_list(N),
                                           " from ", CursorName], [], C),
    case Res of
        {{_, 0}, _} ->
            [];
        {_, Rows} ->
            [{element(1, R), element(2, R)} || R <- Rows]
    end.

upsert_into(Alias, Tab0, PKey, SKey, Val) ->
    {C, Tab} = get_ref(Alias, Tab0),
    try
        {{insert,_,_}, _} = pgsql_connection:extended_query("insert into " ++ Tab ++ " (erlkey,erlhash,erlval,change_time) values ($1,$2,$3,CURRENT_TIMESTAMP)", [PKey,SKey,Val], C),
                                                % ON CONFLICT DO UPDATE SET erlval=$3, erlhash=$2, change_time=CURRENT_TIMESTAMP
        ok
    after
        mnesia_pg_conns:free(C)
    end.

delete_from(Alias, Tab0, PKey) ->
    {C, Tab} = get_ref(Alias, Tab0),
    try
        {_, N} = pgsql_connection:extended_query(["delete from ", Tab, " where erlkey=$1"], [PKey], C),
        N
    after
        mnesia_pg_conns:free(C)
    end.

delete_list(Alias, Tab0, PKeyList) ->
    {C, Tab} = get_ref(Alias, Tab0),
    try
        N = lists:foldl(fun(PKey, Sum) ->
                                {_, N} = pgsql_connection:extended_query(["delete from ", Tab, " where erlkey=$1"], [PKey], C),
                                Sum + N
                        end,
                       0,
                       PKeyList),
        N
    after
        mnesia_pg_conns:free(C)
    end.

delete_all(Alias, Tab0) ->
    {C, Tab} = get_ref(Alias, Tab0),
    try
        pgsql_connection:simple_query(["delete from ", Tab], C)
    after
        mnesia_pg_conns:free(C)
    end.

delete_from_pattern(Alias, Tab0, Pat) ->
    {C, _} = Ref = get_ref(Alias, Tab0),
    Fun = fun(_, Key, Acc) -> [Key|Acc] end,
    try
        Keys = do_fold(Ref, Tab0, Fun, [], [{Pat,[],['$_']}], 30),
        if Keys == [] ->
                ok;
           true ->
                delete_list(Alias, Ref, Keys),
                ok
        end
    after
        mnesia_pg_conns:free(C)
    end.

%% TODO: check that Tab syntax is compatible with postgresql
create_table(Alias, Tab0, _Props) ->
    {C, Tab} = get_ref(Alias, Tab0),
    try
        pgsql_connection:simple_query(["drop index if exists ", Tab, "_term_idx"], C),
        pgsql_connection:simple_query(["drop table if exists ", Tab], C),
        pgsql_connection:simple_query(["create table ", Tab, "( erlkey character varying(2048) primary key, erlhash bigint not null, erlval bytea not null, change_time timestamp not null )"], C),
        pgsql_connection:simple_query(["create index ", Tab, "_term_idx on " ++ Tab ++ " using hash (erlhash)"], C),
        ok
    after
        mnesia_pg_conns:free(C)
    end.

delete_table(Alias, Tab0) ->
    {C, Tab} = get_ref(Alias, Tab0),
    try
        pgsql_connection:simple_query(["drop table if exists ", Tab], C)
    after
        mnesia_pg_conns:free(C)
    end.

load_table(_Alias, _Tab, _LoadReason, _Opts) ->
    ok.

close_table(_Alias, _Tab) ->
    ok.

table_count(Alias, Tab0) ->
    {C, Tab} = get_ref(Alias, Tab0),
    try
        {_, [{X}]} = pgsql_connection:extended_query(["select count(*) from ", Tab], [], C),
        X
    catch
        error:_ ->
            0
    after
        mnesia_pg_conns:free(C)
    end.

table_size(Alias, Tab0) ->
    {C, Tab} = get_ref(Alias, Tab0),
    try
        {_, [{X}]} = pgsql_connection:extended_query(["select pg_total_relation_size('", Tab, "')"], [], C),
        X div 4 % word definition of mnesia?
    catch
        error:_ ->
            1
    after
        mnesia_pg_conns:free(C)
    end.

get_ref(_Alias, Tab) ->
    C = mnesia_pg_conns:alloc(Tab),
    {C, tabname(Tab)}.

tabname({Tab, index, {{Pos},_}}) ->
    "ix2_" ++ atom_to_list(Tab) ++ "_" ++ atom_to_list(Pos);
tabname({Tab, index, {Pos,_}}) ->
    "ix_" ++ atom_to_list(Tab) ++ "_" ++ integer_to_list(Pos);
tabname({Tab, retainer, Name}) ->
    "ret_" ++ atom_to_list(Tab) ++ "_" ++ retainername(Name);
tabname(Tab) when is_atom(Tab) ->
    "tab_" ++ atom_to_list(Tab).

retainername(Name) when is_atom(Name) ->
    atom_to_list(Name);
retainername(Name) when is_list(Name) ->
    try binary_to_list(list_to_binary(Name))
    catch
        error:_ ->
            lists:flatten(io_lib:write(Name))
    end;
retainername(Name) ->
    lists:flatten(io_lib:write(Name)).

dbg(on) ->
    dbg:start(),
    dbg:tracer(),
    dbg:tpl(mnesia, '_', []),
    dbg:tpl(mnesia_pg, '_', []),
    dbg:tpl(mnesia_pg_conns, '_', []),
    dbg:tpl(mnesia_pg_sup, '_', []),
    dbg:tpl(mnesia_pg_app, '_', []),
    dbg:tpl(pgsql, '_', []),
    dbg:p(all,c);
dbg(off) ->
    dbg:stop_clear().

%%%impl_doc_include
