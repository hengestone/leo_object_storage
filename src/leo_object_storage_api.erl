%%======================================================================
%%
%% Leo Object Storage
%%
%% Copyright (c) 2012-2014 Rakuten, Inc.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% ---------------------------------------------------------------------
%% Leo Object Storage - API
%% @doc
%% @end
%%======================================================================
-module(leo_object_storage_api).

-author('Yosuke Hara').

-include("leo_object_storage.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([start/1,
         put/2, get/1, get/3, delete/2, head/1,
         fetch_by_addr_id/2, fetch_by_addr_id/3,
         fetch_by_key/2, fetch_by_key/3,
         store/2,
         stats/0
        ]).

-export([head_with_calc_md5/2]).

-export([get_object_storage_pid/1]).
-export([get_object_storage_pid_first/0]).

-ifdef(TEST).
-export([add_incorrect_data/1]).
-endif.

-define(SERVER_MODULE, 'leo_object_storage_server').

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------
%% @doc Create object-storage processes
%%
-spec(start([tuple()]) ->
             ok | {error, any()}).
start([]) ->
    {error, badarg};
start(ObjectStorageInfo) ->
    case start_app() of
        ok ->
            leo_object_storage_sup:start_child(ObjectStorageInfo);
        {error, Cause} ->
            {error, Cause}
    end.


%% @doc Insert an object into the object-storage
%% @param Key = {$VNODE_ID, $OBJ_KEY}
%%
-spec(put(tuple(), #?OBJECT{}) ->
             {ok, integer()} | {error, any()}).
put(AddrIdAndKey, Object) ->
    do_request(put, [AddrIdAndKey, Object]).


%% @doc Retrieve an object and a metadata from the object-storage
%%
-spec(get(tuple()) ->
             {ok, list()} | not_found | {error, any()}).
get(AddrIdAndKey) ->
    get(AddrIdAndKey, 0, 0).

-spec(get(tuple(), integer(), integer()) ->
             {ok, #?METADATA{}, #?OBJECT{}} | not_found | {error, any()}).
get(AddrIdAndKey, StartPos, EndPos) ->
    do_request(get, [AddrIdAndKey, StartPos, EndPos]).


%% @doc Remove an object from the object-storage
%%
-spec(delete(tuple(), #?OBJECT{}) ->
             ok | {error, any()}).
delete(AddrIdAndKey, Object) ->
    do_request(delete, [AddrIdAndKey, Object]).


%% @doc Retrieve a metadata from the object-storage
%%
-spec(head(tuple()) ->
             {ok, binary()} | not_found | {error, any()}).
head(AddrIdAndKey) ->
    do_request(head, [AddrIdAndKey]).

%% @doc Retrieve a metada/data from backend_db/object-storage
%%      AND calc MD5 based on the body data
%%
-spec(head_with_calc_md5(tuple(), any()) ->
             {ok, metadata, any()} | {error, any()}).
head_with_calc_md5(AddrIdAndKey, MD5Context) ->
    do_request(head_with_calc_md5, [AddrIdAndKey, MD5Context]).


%% @doc Fetch objects by ring-address-id
%%
-spec(fetch_by_addr_id(_, fun()) ->
             {ok, []} | not_found).
fetch_by_addr_id(AddrId, Fun) ->
    fetch_by_addr_id(AddrId, Fun, undefined).
fetch_by_addr_id(AddrId, Fun, MaxKeys) ->
    case get_object_storage_pid(all) of
        [] ->
            not_found;
        List ->
            case fetch_by_addr_id_1(List, AddrId, Fun, MaxKeys, []) of
                Res ->
                    case MaxKeys of
                        undefined ->
                            {ok, Res};
                        _ ->
                            {ok, lists:sublist(Res, MaxKeys)}
                    end
            end
    end.

fetch_by_addr_id_1([],_,_,_,Acc) ->
    lists:reverse(lists:flatten(Acc));
fetch_by_addr_id_1([H|T], AddrId, Fun, MaxKeys, Acc) ->
    Acc_1 = case ?SERVER_MODULE:fetch(
                          H, {AddrId, <<>>}, Fun, MaxKeys) of
                {ok, Val} ->
                    [Val|Acc];
                _ ->
                    Acc
            end,
    fetch_by_addr_id_1(T, AddrId, Fun, MaxKeys, Acc_1).

%% @doc Fetch objects by key (object-name)
%%
-spec(fetch_by_key(binary(), function()) ->
             {ok, list()} | not_found).
fetch_by_key(Key, Fun) ->
    fetch_by_key(Key, Fun, undefined).
-spec(fetch_by_key(binary(), function(), pos_integer()|undefined) ->
             {ok, list()} | not_found).
fetch_by_key(Key, Fun, MaxKeys) ->
    case get_object_storage_pid(all) of
        [] ->
            not_found;
        List ->
            Res = lists:foldl(
                    fun(Id, Acc) ->
                            case ?SERVER_MODULE:fetch(Id, {0, Key}, Fun, MaxKeys) of
                                {ok, Values} ->
                                    [Values|Acc];
                                _ ->
                                    Acc
                            end
                    end, [], List),
            Res_1 = lists:reverse(lists:flatten(Res)),
            case MaxKeys of
                undefined ->
                    {ok, Res_1};
                _ ->
                    {ok, lists:sublist(Res_1, MaxKeys)}
            end
    end.


%% @doc Store metadata and data
%%
-spec(store(#?METADATA{}, binary()) ->
             ok | {error, any()}).
store(Metadata, Bin) ->
    do_request(store, [Metadata, Bin]).


%% @doc Retrieve the storage stats
%%
-spec(stats() ->
             {ok, list()} | not_found).
stats() ->
    case get_object_storage_pid(all) of
        [] ->
            not_found;
        List ->
            {ok, lists:reverse(
                   lists:foldl(fun(Id, Acc) ->
                                       [?SERVER_MODULE:get_stats(Id)|Acc]
                               end, [], List))}
    end.

-ifdef(TEST).
%% @doc Add incorrect datas on debug purpose
%%
-spec(add_incorrect_data(binary()) ->
             ok | {error, any()}).
add_incorrect_data(Bin) ->
    [Pid|_] = get_object_storage_pid(Bin),
    ?SERVER_MODULE:add_incorrect_data(Pid, Bin).
-endif.


%%--------------------------------------------------------------------
%% INNTERNAL FUNCTIONS
%%--------------------------------------------------------------------
%% @doc Launch the object storage application
%% @private
-spec(start_app() ->
             ok | {error, any()}).
start_app() ->
    Module = leo_object_storage,

    case application:start(Module) of
        ok ->
            ok = leo_misc:init_env(),
            catch ets:new(?ETS_CONTAINERS_TABLE,
                          [named_table, ordered_set, public, {read_concurrency, true}]),
            catch ets:new(?ETS_INFO_TABLE,
                          [named_table, set, public, {read_concurrency, true}]),
            ok;
        {error, {already_started, Module}} ->
            ok;
        {error, Cause} ->
            error_logger:error_msg("~p,~p,~p,~p~n",
                                   [{module, ?MODULE_STRING},
                                    {function, "start_app/0"},
                                    {line, ?LINE}, {body, Cause}]),
            {error, Cause}
    end.



%% @doc Retrieve an object storage process-id
%% @private
-spec(get_object_storage_pid(all | any()) ->
             [atom()]).
get_object_storage_pid(Arg) ->
    Ret = ets:tab2list(?ETS_CONTAINERS_TABLE),
    get_object_storage_pid(Ret, Arg).

%% @private
get_object_storage_pid([], _) ->
    [];
get_object_storage_pid(List, all) ->
    lists:map(fun({_, Value}) ->
                      leo_misc:get_value(obj_storage, Value)
              end, List);
get_object_storage_pid(List, Arg) ->
    Index = (erlang:crc32(Arg) rem erlang:length(List)) + 1,
    {_, Value} = lists:nth(Index, List),
    Id = leo_misc:get_value(obj_storage, Value),
    [Id].


%% @doc for debug purpose
%% @private
get_object_storage_pid_first() ->
    Key = ets:first(?ETS_CONTAINERS_TABLE),
    [{Key, First}|_] = ets:lookup(?ETS_CONTAINERS_TABLE, Key),
    Id = leo_misc:get_value(obj_storage, First),
    Id.


%% @doc Retrieve the status of object of pid
%% @private
-spec(get_status_by_id(atom()) ->
             storage_status()).
get_status_by_id(Pid) ->
    case leo_misc:get_env(?APP_NAME, {?ENV_COMPACTION_STATUS, Pid}) of
        {ok, Status} ->
            Status;
        _ ->
            ?STATE_ACTIVE
    end.


%% @doc Request an operation
%% @private
-spec(do_request(type_of_method(), list(_)) ->
             ok |
             {ok, binary()} |
             {ok, #?METADATA{}, #?OBJECT{}} |
             not_found |
             {error, any()}).
do_request(get, [{AddrId, Key}, StartPos, EndPos]) ->
    KeyBin = term_to_binary({AddrId, Key}),
    case get_object_storage_pid(KeyBin) of
        [Pid|_] ->
            ?SERVER_MODULE:get(Pid, {AddrId, Key}, StartPos, EndPos);
        _ ->
            {error, ?ERROR_PROCESS_NOT_FOUND}
    end;
do_request(store, [Metadata, Bin]) ->
    Metadata_1 = leo_object_storage_transformer:transform_metadata(Metadata),
    #?METADATA{addr_id = AddrId,
               key     = Key} = Metadata_1,
    case get_object_storage_pid(term_to_binary({AddrId, Key})) of
        [Pid|_] ->
            case get_status_by_id(Pid) of
                ?STATE_ACTIVE ->
                    ?SERVER_MODULE:store(Pid, Metadata_1, Bin);
                ?STATE_RUNNING_COMPACTION ->
                    {error, doing_compaction}
            end;
        _ ->
            {error, ?ERROR_PROCESS_NOT_FOUND}
    end;
do_request(put, [Key, Object]) ->
    KeyBin = term_to_binary(Key),
    case get_object_storage_pid(KeyBin) of
        [Pid|_] ->
            case get_status_by_id(Pid) of
                ?STATE_ACTIVE ->
                    ?SERVER_MODULE:put(Pid, Object);
                ?STATE_RUNNING_COMPACTION ->
                    {error, doing_compaction}
            end;
        _ ->
            {error, ?ERROR_PROCESS_NOT_FOUND}
    end;
do_request(delete, [Key, Object]) ->
    KeyBin = term_to_binary(Key),
    case get_object_storage_pid(KeyBin) of
    [Pid|_] ->
            case get_status_by_id(Pid) of
                ?STATE_ACTIVE ->
                    ?SERVER_MODULE:delete(Pid, Object);
                ?STATE_RUNNING_COMPACTION ->
                    {error, doing_compaction}
            end;
        _ ->
            {error, ?ERROR_PROCESS_NOT_FOUND}
    end;
do_request(head, [{AddrId, Key}]) ->
    KeyBin = term_to_binary({AddrId, Key}),
    case get_object_storage_pid(KeyBin) of
        [Pid|_] ->
            ?SERVER_MODULE:head(Pid, {AddrId, Key});
        _ ->
            {error, ?ERROR_PROCESS_NOT_FOUND}
    end;
do_request(head_with_calc_md5, [{AddrId, Key}, MD5Context]) ->
    KeyBin = term_to_binary({AddrId, Key}),
    case get_object_storage_pid(KeyBin) of
        [Pid|_] ->
            ?SERVER_MODULE:head_with_calc_md5(Pid, {AddrId, Key}, MD5Context);
        _ ->
            {error, ?ERROR_PROCESS_NOT_FOUND}
    end.
