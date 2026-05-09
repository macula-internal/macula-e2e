%%%-------------------------------------------------------------------
%%% @doc Reusable probes for the Macula relay fleet.
%%%
%%% Each function returns `ok | {error, Reason}'. The CT suite in
%%% `test/macula_e2e_SUITE.erl' wraps them as `ct:fail/1' on error;
%%% future iterations (a long-running probe daemon for the soft
%%% real-time dashboard) call the same functions on a schedule and
%%% emit results as structured events.
%%%
%%% The factoring is the lever — keep test bodies thin and the
%%% probe module reusable across:
%%%
%%%   Phase 0 (today)  — CT suite, hourly via container
%%%   Phase 1          — Erlang gen_server scheduling probes,
%%%                      Cowboy `/api/status' endpoint
%%%   Phase 2          — probe daemon publishes results to
%%%                      `_e2e.results' on the mesh; subscriber-side
%%%                      dashboard tallies per-vantage
%%%
%%% None of the probes write persistent state to the production DHT
%%% beyond an ephemeral `node_record' for a freshly-generated
%%% identity (which is harmless — stations rotate node records by
%%% TTL).
%%% @end
%%%-------------------------------------------------------------------
-module(macula_e2e_probe).

-export([
    pool_health/1,
    pubsub_roundtrip/4,
    realm_isolation/5,
    unary_rpc/4,
    streaming_rpc/4,
    dht_put_find/2,
    weather_subscribe/3,
    pool_close_cleanup/1,
    cross_station_pubsub/4,
    cross_station_unary_rpc/4,
    put_get_content/1,
    cross_station_dht_put_find/3
]).

-define(SUBSCRIBE_SETTLE_MS,  1_500).
-define(ADVERTISE_SETTLE_MS,  1_500).
-define(DHT_REPLICATION_MS,   2_000).

-type result() :: ok | {error, Reason :: term()}.

-export_type([result/0]).

%%====================================================================
%% Probes
%%====================================================================

%% @doc Assert the pool has at least one healthy link.
-spec pool_health(macula:pool()) -> result().
pool_health(Pool) ->
    on_status(macula:status(Pool)).

on_status({ok, #{healthy_links := N}}) when N > 0 -> ok;
on_status({ok, Status})                            -> {error, {no_healthy_links, Status}};
on_status({error, _} = E)                          -> E.

%% @doc Pubsub roundtrip — Pub publishes, Sub receives. Independent
%% pools, so the round-trip exercises the wire (not just an
%% in-pool short circuit).
-spec pubsub_roundtrip(PubPool :: macula:pool(),
                       SubPool :: macula:pool(),
                       macula:realm(),
                       macula:topic()) -> result().
pubsub_roundtrip(PubPool, SubPool, Realm, Topic) ->
    {ok, SubRef} = macula:subscribe(SubPool, Realm, Topic, self()),
    timer:sleep(?SUBSCRIBE_SETTLE_MS),
    Token = crypto:strong_rand_bytes(16),
    Payload = #{<<"token">> => Token},
    ok = macula:publish(PubPool, Realm, Topic, Payload),
    Result = await_event_match(SubRef, Topic, Payload, 5_000),
    catch macula:unsubscribe(SubPool, SubRef),
    Result.

%% @doc Realm isolation — a subscriber on RealmA must not see
%% events published on RealmB. Then sanity-check the A subscriber
%% does see an event on A (i.e., it's not just dead).
-spec realm_isolation(PubPool :: macula:pool(),
                      SubPool :: macula:pool(),
                      RealmA :: macula:realm(),
                      RealmB :: macula:realm(),
                      macula:topic()) -> result().
realm_isolation(PubPool, SubPool, RealmA, RealmB, Topic) ->
    {ok, SubRef} = macula:subscribe(SubPool, RealmA, Topic, self()),
    timer:sleep(?SUBSCRIBE_SETTLE_MS),
    %% Cross-realm publish must NOT be received.
    ok = macula:publish(PubPool, RealmB, Topic, #{<<"secret">> => <<"only_in_B">>}),
    Result = check_no_cross_realm(SubRef, PubPool, RealmA, Topic),
    catch macula:unsubscribe(SubPool, SubRef),
    Result.

check_no_cross_realm(SubRef, PubPool, RealmA, Topic) ->
    receive
        {macula_event, SubRef, _, _, _} ->
            {error, realm_isolation_breached}
    after 2_000 ->
        %% Same subscriber MUST see RealmA events — otherwise the
        %% test passed by accident (subscription wasn't wired).
        Mark = #{<<"mark">> => crypto:strong_rand_bytes(16)},
        ok = macula:publish(PubPool, RealmA, Topic, Mark),
        await_event_match(SubRef, Topic, Mark, 5_000)
    end.

%% @doc Unary RPC — Server advertises a procedure, Caller calls it.
-spec unary_rpc(ServerPool :: macula:pool(),
                CallerPool :: macula:pool(),
                macula:realm(),
                macula:procedure()) -> result().
unary_rpc(ServerPool, CallerPool, Realm, Procedure) ->
    Handler = fun(Args) -> {ok, #{<<"got">> => Args}} end,
    ok = macula:advertise(ServerPool, Realm, Procedure, Handler, #{}),
    timer:sleep(?ADVERTISE_SETTLE_MS),
    Args = #{<<"x">> => 42},
    Reply = macula:call(CallerPool, Realm, Procedure, Args, 5_000),
    catch macula:unadvertise(ServerPool, Realm, Procedure),
    classify_unary(Reply, Args).

%% Macula 4.2.x CBOR decoder converts short text keys to atoms on
%% receive but we send binary keys. Normalise both sides to binary
%% before equality so the probe survives encoder asymmetry without
%% becoming a typing test.
classify_unary({ok, #{<<"got">> := Got}}, Args) ->
    classify_unary_match(Got, Args);
classify_unary({ok, #{got := Got}}, Args) ->
    classify_unary_match(Got, Args);
classify_unary({ok, Other}, Args) ->
    {error, {unexpected_reply, Other, expected, Args}};
classify_unary({error, _} = E, _) ->
    E.

classify_unary_match(Got, Args) ->
    case normalise_keys(Got) =:= normalise_keys(Args) of
        true  -> ok;
        false -> {error, {unexpected_reply, Got, expected, Args}}
    end.

%% @doc Streaming RPC — Server advertises a server_stream that
%% emits N integer chunks, Caller drains them.
-spec streaming_rpc(ServerPool :: macula:pool(),
                    CallerPool :: macula:pool(),
                    macula:realm(),
                    macula:procedure()) -> result().
streaming_rpc(ServerPool, CallerPool, Realm, Procedure) ->
    Handler = fun(Stream, Args) ->
        N = case Args of
                #{<<"n">> := X} -> X;
                #{n         := X} -> X
            end,
        lists:foreach(
          fun(I) -> ok = macula:send(Stream, integer_to_binary(I)) end,
          lists:seq(1, N)),
        macula:close_stream(Stream)
    end,
    ok = macula:advertise_stream(ServerPool, Realm, Procedure,
                                  server_stream, Handler),
    timer:sleep(?ADVERTISE_SETTLE_MS),
    Result =
        case macula:call_stream(CallerPool, Realm, Procedure,
                                #{<<"n">> => 3}, #{}) of
            {ok, Stream} ->
                classify_stream(drain_stream(Stream, []));
            {error, _} = E ->
                E
        end,
    catch macula:unadvertise_stream(ServerPool, Realm, Procedure),
    Result.

classify_stream({ok, [<<"1">>, <<"2">>, <<"3">>]}) -> ok;
classify_stream({ok, Got})                          -> {error, {unexpected_chunks, Got}};
classify_stream({error, _} = E)                     -> E.

drain_stream(Stream, Acc) ->
    on_recv(macula:recv(Stream, 5_000), Stream, Acc).

on_recv({chunk, Bin}, Stream, Acc)        -> drain_stream(Stream, [Bin | Acc]);
on_recv({data, Term}, Stream, Acc)        -> drain_stream(Stream, [Term | Acc]);
on_recv(eof, _Stream, Acc)                -> {ok, lists:reverse(Acc)};
on_recv({error, _} = E, _Stream, _Acc)    -> E.

%% @doc DHT round-trip — put a fresh-identity node_record, find it
%% by its storage key. Replication delay budgeted at
%% `?DHT_REPLICATION_MS' before the find.
-spec dht_put_find(macula:pool(), macula:realm()) -> result().
dht_put_find(Pool, Realm) ->
    Identity = macula_identity:generate(),
    NodeId = macula_identity:public(Identity),
    Record = macula_record:node_record(NodeId, [Realm], 0),
    Signed = macula_record:sign(Record, Identity),
    Key = macula_record:storage_key(Signed),
    classify_put_find(macula:put_record(Pool, Signed), Pool, Key).

classify_put_find(ok, Pool, Key) ->
    timer:sleep(?DHT_REPLICATION_MS),
    classify_find(macula:find_record(Pool, Key), Key);
classify_put_find({error, _} = E, _Pool, _Key) ->
    E.

%% Macula 4.2.x decoded record keeps the on-wire field names: `key',
%% `payload', `signature', `type', `version', `created_at',
%% `expires_at'. (Legacy `sig' was renamed.) Accept both for forward
%% compatibility.
classify_find({ok, #{type := _, payload := _, signature := _}}, _Key) -> ok;
classify_find({ok, #{type := _, payload := _, sig := _}},       _Key) -> ok;
classify_find({ok, Other}, Key) -> {error, {unexpected_record, Key, Other}};
classify_find({error, _} = E, _Key) -> E.

%% @doc Content put/get round-trip. Hashes a random blob, stores it
%% via `_content.put_block', fetches it back via `_content.get_block',
%% asserts the bytes match. Single-station: writer and reader share
%% the pool, so the blob lives on the station the daemon dialled.
-spec put_get_content(macula:pool()) -> result().
put_get_content(Pool) ->
    Bytes = crypto:strong_rand_bytes(8192),
    classify_put_content(macula:put_content(Pool, Bytes), Pool, Bytes).

classify_put_content({ok, MCID}, Pool, Bytes) ->
    classify_get_content(macula:get_content(Pool, MCID), Bytes);
classify_put_content({error, _} = E, _Pool, _Bytes) ->
    E.

classify_get_content({ok, Bytes}, Bytes) -> ok;
classify_get_content({ok, Other},  Bytes) ->
    {error, {content_mismatch, byte_size(Bytes), byte_size(Other)}};
classify_get_content({error, _} = E, _Bytes) -> E.

%% @doc Subscribe to the live `_mesh.weather' topic and assert at
%% least one event lands within `MaxWaitMs'. The real stub fleet
%% publishes there every 60s under realm `io.macula'.
-spec weather_subscribe(macula:pool(), macula:realm(),
                        MaxWaitMs :: pos_integer()) -> result().
weather_subscribe(Pool, Realm, MaxWaitMs) ->
    Topic = <<"_mesh.weather">>,
    {ok, SubRef} = macula:subscribe(Pool, Realm, Topic, self()),
    Result = await_any_event(SubRef, MaxWaitMs),
    catch macula:unsubscribe(Pool, SubRef),
    Result.

%% @doc Cross-station pub/sub roundtrip. PubPool is dialled into one
%% bootstrap station; SubPool into a DIFFERENT bootstrap station. The
%% published event MUST traverse the inter-station mesh edge to reach
%% the subscriber. Same wire shape as `pubsub_roundtrip/4'; the test
%% case wires distinct pools.
-spec cross_station_pubsub(PubPool :: macula:pool(),
                           SubPool :: macula:pool(),
                           macula:realm(),
                           macula:topic()) -> result().
cross_station_pubsub(PubPool, SubPool, Realm, Topic) ->
    pubsub_roundtrip(PubPool, SubPool, Realm, Topic).

%% @doc Cross-station unary RPC roundtrip. Server advertises through
%% one station; Caller dials a DIFFERENT station. The CALL frame must
%% route across the mesh (relay-side procedure registry must include
%% the cross-station link as a route to the advertising station).
-spec cross_station_unary_rpc(ServerPool :: macula:pool(),
                              CallerPool :: macula:pool(),
                              macula:realm(),
                              macula:procedure()) -> result().
cross_station_unary_rpc(ServerPool, CallerPool, Realm, Procedure) ->
    unary_rpc(ServerPool, CallerPool, Realm, Procedure).

%% @doc Cross-station DHT roundtrip. WriterPool puts through one
%% station; ReaderPool finds through a DIFFERENT station. The record
%% must replicate via DHT gossip across the inter-station mesh.
-spec cross_station_dht_put_find(WriterPool :: macula:pool(),
                                 ReaderPool :: macula:pool(),
                                 macula:realm()) -> result().
cross_station_dht_put_find(WriterPool, ReaderPool, Realm) ->
    Identity = macula_identity:generate(),
    NodeId = macula_identity:public(Identity),
    Record = macula_record:node_record(NodeId, [Realm], 0),
    Signed = macula_record:sign(Record, Identity),
    Key = macula_record:storage_key(Signed),
    classify_put_find(macula:put_record(WriterPool, Signed),
                      ReaderPool, Key).

%% @doc Pool close emits a `macula_event_gone' to every subscriber.
%% Opens its own pool so the suite-shared one is undisturbed.
-spec pool_close_cleanup(Bootstrap :: [binary()]) -> result().
pool_close_cleanup(Bootstrap) ->
    {ok, P} = macula:connect(Bootstrap, #{}),
    case wait_healthy(P, 10_000) of
        ok ->
            Realm = macula_realm:id(<<"_test">>),
            Topic = unique_topic(<<"e2e.cleanup">>),
            {ok, SubRef} = macula:subscribe(P, Realm, Topic, self()),
            timer:sleep(500),
            macula:close(P),
            await_event_gone(SubRef, 5_000);
        timeout ->
            macula:close(P),
            {error, pool_not_ready}
    end.

%%====================================================================
%% Helpers
%%====================================================================

-spec wait_healthy(macula:pool(), pos_integer()) -> ok | timeout.
wait_healthy(_Pool, Remaining) when Remaining =< 0 ->
    timeout;
wait_healthy(Pool, Remaining) ->
    case macula:status(Pool) of
        {ok, #{healthy_links := N}} when N > 0 -> ok;
        _ ->
            timer:sleep(500),
            wait_healthy(Pool, Remaining - 500)
    end.

-spec unique_topic(binary()) -> binary().
unique_topic(Prefix) ->
    Suffix = integer_to_binary(erlang:unique_integer([positive])),
    <<Prefix/binary, ".", Suffix/binary>>.

await_event_match(SubRef, Topic, ExpectedPayload, TimeoutMs) ->
    Expected1 = normalise_keys(ExpectedPayload),
    receive
        {macula_event, SubRef, Topic, Got, _Meta} ->
            case normalise_keys(Got) =:= Expected1 of
                true  -> ok;
                false -> {error, {payload_mismatch, expected,
                                  ExpectedPayload, got, Got}}
            end
    after TimeoutMs ->
        {error, {no_event, Topic, expected, ExpectedPayload}}
    end.

%% Strip the SDK's CBOR atom/text-tuple key encoding so probe
%% assertions can compare semantically. Accepts atom keys, plain
%% binary keys, and `{text, Bin}' keys; emits canonical binary keys.
normalise_keys(M) when is_map(M) ->
    maps:fold(fun(K, V, Acc) -> Acc#{normalise_key(K) => normalise_keys(V)} end,
              #{}, M);
normalise_keys(L) when is_list(L) ->
    [normalise_keys(X) || X <- L];
normalise_keys(X) ->
    X.

normalise_key({text, B}) when is_binary(B) -> B;
normalise_key(K) when is_atom(K)           -> atom_to_binary(K, utf8);
normalise_key(K)                           -> K.

await_any_event(SubRef, TimeoutMs) ->
    receive
        {macula_event, SubRef, _Topic, _Payload, _Meta} -> ok
    after TimeoutMs ->
        {error, {no_event_in, TimeoutMs}}
    end.

await_event_gone(SubRef, TimeoutMs) ->
    receive
        {macula_event_gone, SubRef, _Reason} -> ok
    after TimeoutMs ->
        {error, no_event_gone}
    end.
