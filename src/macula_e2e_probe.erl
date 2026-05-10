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
    cross_station_streaming_rpc/4,
    multi_publisher_pubsub/6,
    cross_station_multi_publisher_pubsub/6,
    many_concurrent_calls/5,
    cross_station_many_concurrent_calls/5,
    many_concurrent_streams/5,
    cross_station_many_concurrent_streams/5,
    many_concurrent_dht_records/3,
    cross_station_many_concurrent_dht_records/4,
    many_concurrent_blobs/2,
    cross_station_many_concurrent_blobs/3,
    tombstone_propagation/2,
    cross_station_tombstone_propagation/3,
    subscribe_records_local/2,
    subscribe_records_cross_station/3,
    put_get_content/1,
    cross_station_put_content/2,
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
    do_put_get_content(Pool, Pool).

%% Cross-station variant — Writer puts on one station, Reader fetches
%% from a different one. The reader's relay handles the local miss
%% via `_content.get_block' iterative fetch (one hop to peer
%% stations); the writer's eager-put landed the block on the writer's
%% relay only, so the reader has to walk out one hop.
-spec cross_station_put_content(macula:pool(), macula:pool()) -> result().
cross_station_put_content(WriterPool, ReaderPool) ->
    do_put_get_content(WriterPool, ReaderPool).

do_put_get_content(WriterPool, ReaderPool) ->
    Bytes = crypto:strong_rand_bytes(8192),
    classify_put_content(macula:put_content(WriterPool, Bytes),
                         ReaderPool, Bytes).

classify_put_content({ok, MCID}, ReaderPool, Bytes) ->
    classify_get_content(macula:get_content(ReaderPool, MCID), Bytes);
classify_put_content({error, _} = E, _ReaderPool, _Bytes) ->
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

%% @doc Cross-station streaming RPC roundtrip. Server advertises a
%% server_stream procedure on one station; Caller opens the stream
%% from a DIFFERENT station. Frames flow across the relay's
%% per-stream-id forwarding map (macula-station commit fa32bbd —
%% STREAM_OPEN routes by procedure like CALL, subsequent
%% STREAM_DATA / STREAM_END / STREAM_ERROR / STREAM_REPLY frames
%% relay by stream-id).
-spec cross_station_streaming_rpc(ServerPool :: macula:pool(),
                                  CallerPool :: macula:pool(),
                                  macula:realm(),
                                  macula:procedure()) -> result().
cross_station_streaming_rpc(ServerPool, CallerPool, Realm, Procedure) ->
    streaming_rpc(ServerPool, CallerPool, Realm, Procedure).

%%====================================================================
%% Concurrent / interleaved probes — pubsub
%%====================================================================

%% @doc N concurrent senders fire M publishes each through the same
%% pool; a single subscriber drains; assert all N*M unique tokens
%% land within the deadline. Stresses the relay's pubsub_server
%% gen_server mailbox + the fan-out path under burst load. Token
%% bytes encode (sender_idx, message_idx) so the assertion catches
%% duplicates AND drops.
%%
%% Same pool for all senders (sequential publish_seq counter
%% — the SDK's outbound_link gen_server serialises). The stress
%% is on the RELAY side, not on signing N distinct identities.
-spec multi_publisher_pubsub(NumSenders :: pos_integer(),
                             MsgsPerSender :: pos_integer(),
                             PubPool :: macula:pool(),
                             SubPool :: macula:pool(),
                             macula:realm(),
                             macula:topic()) -> result().
multi_publisher_pubsub(NumSenders, MsgsPerSender,
                      PubPool, SubPool, Realm, Topic) ->
    {ok, SubRef} = macula:subscribe(SubPool, Realm, Topic, self()),
    timer:sleep(?SUBSCRIBE_SETTLE_MS),
    Senders = [spawn_link(fun() ->
        run_sender(I, MsgsPerSender, PubPool, Realm, Topic)
    end) || I <- lists:seq(1, NumSenders)],
    Total  = NumSenders * MsgsPerSender,
    %% Drain budget: 200ms per expected event, floor 5s, ceiling
    %% 30s. Keeps cheap tests cheap and big tests bounded.
    Budget = max(5_000, min(30_000, Total * 200)),
    Result = drain_unique_pubsub_events(SubRef, Total, Budget),
    [exit(Pid, kill) || Pid <- Senders],
    catch macula:unsubscribe(SubPool, SubRef),
    Result.

%% @doc Cross-station variant — Pub side dials one station, Sub
%% side dials a different station. The N*M EVENTs all relay across
%% the mesh.
-spec cross_station_multi_publisher_pubsub(
        pos_integer(), pos_integer(),
        macula:pool(), macula:pool(),
        macula:realm(), macula:topic()) -> result().
cross_station_multi_publisher_pubsub(NumSenders, MsgsPerSender,
                                     PubPool, SubPool, Realm, Topic) ->
    multi_publisher_pubsub(NumSenders, MsgsPerSender,
                           PubPool, SubPool, Realm, Topic).

run_sender(SenderIdx, MsgsPerSender, Pool, Realm, Topic) ->
    [begin
        Token = <<SenderIdx:8, K:24>>,
        catch macula:publish(Pool, Realm, Topic, #{<<"token">> => Token})
     end || K <- lists:seq(1, MsgsPerSender)],
    ok.

drain_unique_pubsub_events(SubRef, Expected, TimeoutMs) ->
    drain_unique_pubsub_events(SubRef, Expected, sets:new(),
                               erlang:monotonic_time(millisecond) + TimeoutMs).

drain_unique_pubsub_events(_SubRef, Expected, _Got, _Deadline)
  when Expected =< 0 -> ok;
drain_unique_pubsub_events(SubRef, Expected, Got, Deadline) ->
    Remaining = max(1, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {macula_event, SubRef, _Topic, Payload, _Meta} ->
            Token = extract_token(Payload),
            NewGot = sets:add_element(Token, Got),
            case sets:size(NewGot) - sets:size(Got) of
                1 -> drain_unique_pubsub_events(SubRef,
                                                Expected - 1,
                                                NewGot, Deadline);
                0 -> drain_unique_pubsub_events(SubRef,
                                                Expected,
                                                NewGot, Deadline)
            end
    after Remaining ->
        {error, {missing_pubsub_events,
                 missing, Expected,
                 received_unique, sets:size(Got)}}
    end.

extract_token(Payload) ->
    case normalise_keys(Payload) of
        #{<<"token">> := T} -> T;
        Other               -> {no_token, Other}
    end.

%%====================================================================
%% Concurrent / interleaved probes — unary RPC
%%====================================================================

%% @doc N concurrent CALLs against one advertised proc. Each caller
%% sends a unique correlation id; the handler echoes it; the
%% assertion verifies each caller received its OWN correlation
%% back (catches crossed wires in the relay's `forwarded' call_id
%% routing map).
-spec many_concurrent_calls(NumCalls :: pos_integer(),
                            ServerPool :: macula:pool(),
                            CallerPool :: macula:pool(),
                            macula:realm(),
                            macula:procedure()) -> result().
many_concurrent_calls(NumCalls, ServerPool, CallerPool, Realm, Procedure) ->
    Handler = fun(Args) -> {ok, #{<<"echo">> => Args}} end,
    ok = macula:advertise(ServerPool, Realm, Procedure, Handler, #{}),
    timer:sleep(?ADVERTISE_SETTLE_MS),
    Parent = self(),
    Callers = [spawn_link(fun() ->
        Corr   = list_to_binary("c-" ++ integer_to_list(I)),
        Args   = #{<<"correlation">> => Corr},
        Reply  = macula:call(CallerPool, Realm, Procedure, Args, 10_000),
        Parent ! {caller_done, self(), I, Corr, Reply}
    end) || I <- lists:seq(1, NumCalls)],
    Result = gather_caller_results(Callers, NumCalls, []),
    catch macula:unadvertise(ServerPool, Realm, Procedure),
    Result.

%% @doc Cross-station variant — Server advertises on one station,
%% Callers dial a DIFFERENT station. All N CALLs traverse the
%% relay's per-call_id `forwarded' map under burst load.
-spec cross_station_many_concurrent_calls(
        pos_integer(), macula:pool(), macula:pool(),
        macula:realm(), macula:procedure()) -> result().
cross_station_many_concurrent_calls(NumCalls, ServerPool, CallerPool,
                                    Realm, Procedure) ->
    many_concurrent_calls(NumCalls, ServerPool, CallerPool,
                          Realm, Procedure).

gather_caller_results([], 0, Errors) ->
    case Errors of
        []     -> ok;
        _      -> {error, {caller_errors, lists:reverse(Errors)}}
    end;
gather_caller_results(Pids, Remaining, Errors) ->
    receive
        {caller_done, Pid, I, Corr, Reply} ->
            NewErrors = classify_concurrent_call(I, Corr, Reply, Errors),
            gather_caller_results(lists:delete(Pid, Pids),
                                  Remaining - 1, NewErrors)
    after 30_000 ->
        {error, {timeout_waiting_for_callers,
                 outstanding, Remaining,
                 partial_errors, lists:reverse(Errors)}}
    end.

classify_concurrent_call(_I, Corr, {ok, Reply}, Errors) ->
    case normalise_keys(Reply) of
        #{<<"echo">> := #{<<"correlation">> := Corr}} ->
            Errors;
        Other ->
            [{caller_payload_mismatch, Corr, got, Other} | Errors]
    end;
classify_concurrent_call(I, Corr, Other, Errors) ->
    [{caller_failed, I, Corr, Other} | Errors].

%%====================================================================
%% Concurrent / interleaved probes — streaming RPC
%%====================================================================

%% @doc N concurrent open_stream against one advertised
%% server_stream procedure. Each caller asks for `seed' integer
%% chunks where seed is its own ordinal; each must drain
%% `["1", "2", ..., "<seed>"]' in order. Catches per-stream-id
%% routing crossings in the relay's `streams' map.
-spec many_concurrent_streams(NumStreams :: pos_integer(),
                              ServerPool :: macula:pool(),
                              CallerPool :: macula:pool(),
                              macula:realm(),
                              macula:procedure()) -> result().
many_concurrent_streams(NumStreams, ServerPool, CallerPool,
                        Realm, Procedure) ->
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
    Parent = self(),
    Callers = [spawn_link(fun() ->
        N = I + 2,    % each stream has a distinct length
        Reply = case macula:call_stream(CallerPool, Realm, Procedure,
                                        #{<<"n">> => N}, #{}) of
                    {ok, Stream}     -> drain_stream(Stream, []);
                    {error, _} = E   -> E
                end,
        Parent ! {stream_done, self(), I, N, Reply}
    end) || I <- lists:seq(1, NumStreams)],
    Result = gather_stream_results(Callers, NumStreams, []),
    catch macula:unadvertise_stream(ServerPool, Realm, Procedure),
    Result.

-spec cross_station_many_concurrent_streams(
        pos_integer(), macula:pool(), macula:pool(),
        macula:realm(), macula:procedure()) -> result().
cross_station_many_concurrent_streams(NumStreams, ServerPool, CallerPool,
                                      Realm, Procedure) ->
    many_concurrent_streams(NumStreams, ServerPool, CallerPool,
                            Realm, Procedure).

gather_stream_results([], 0, Errors) ->
    case Errors of
        [] -> ok;
        _  -> {error, {stream_errors, lists:reverse(Errors)}}
    end;
gather_stream_results(Pids, Remaining, Errors) ->
    receive
        {stream_done, Pid, I, N, Reply} ->
            NewErrors = classify_concurrent_stream(I, N, Reply, Errors),
            gather_stream_results(lists:delete(Pid, Pids),
                                  Remaining - 1, NewErrors)
    after 30_000 ->
        {error, {timeout_waiting_for_streams,
                 outstanding, Remaining,
                 partial_errors, lists:reverse(Errors)}}
    end.

classify_concurrent_stream(I, N, {ok, Chunks}, Errors) ->
    Expected = [integer_to_binary(K) || K <- lists:seq(1, N)],
    case Chunks =:= Expected of
        true  -> Errors;
        false -> [{stream_chunks_mismatch, I, expected, Expected,
                   got, Chunks} | Errors]
    end;
classify_concurrent_stream(I, _N, Other, Errors) ->
    [{stream_failed, I, Other} | Errors].

%%====================================================================
%% Concurrent / interleaved probes — DHT
%%====================================================================

%% @doc N concurrent put_record calls; after replication delay, find
%% each record back. Asserts every put becomes a successful find.
%% Single-pool variant — both sides of the round-trip on the same
%% station.
-spec many_concurrent_dht_records(NumRecords :: pos_integer(),
                                  macula:pool(),
                                  macula:realm()) -> result().
many_concurrent_dht_records(NumRecords, Pool, Realm) ->
    do_many_concurrent_dht_records(NumRecords, Pool, Pool, Realm).

%% @doc Cross-station variant — Writer puts on one station, Reader
%% finds on a different station. Stresses the eager-replication
%% (k=8) + 1-hop iterative fallback path under burst load.
-spec cross_station_many_concurrent_dht_records(
        pos_integer(), macula:pool(), macula:pool(),
        macula:realm()) -> result().
cross_station_many_concurrent_dht_records(NumRecords, WriterPool,
                                          ReaderPool, Realm) ->
    do_many_concurrent_dht_records(NumRecords, WriterPool,
                                   ReaderPool, Realm).

do_many_concurrent_dht_records(NumRecords, WriterPool, ReaderPool, Realm) ->
    Records = [begin
        Identity = macula_identity:generate(),
        NodeId   = macula_identity:public(Identity),
        Record   = macula_record:node_record(NodeId, [Realm], 0),
        Signed   = macula_record:sign(Record, Identity),
        {macula_record:storage_key(Signed), Signed}
    end || _ <- lists:seq(1, NumRecords)],
    Parent = self(),
    Writers = [spawn_link(fun() ->
        R = macula:put_record(WriterPool, Signed),
        Parent ! {put_done, self(), Key, R}
    end) || {Key, Signed} <- Records],
    PutErrors = gather_put_results(Writers, NumRecords, []),
    timer:sleep(?DHT_REPLICATION_MS),
    case PutErrors of
        [] ->
            FindErrors = run_concurrent_finds(ReaderPool,
                                              [Key || {Key, _} <- Records]),
            classify_dht_concurrency([], FindErrors);
        _ ->
            classify_dht_concurrency(PutErrors, [])
    end.

gather_put_results([], 0, Errors) -> lists:reverse(Errors);
gather_put_results(Pids, Remaining, Errors) ->
    receive
        {put_done, Pid, _Key, ok} ->
            gather_put_results(lists:delete(Pid, Pids),
                               Remaining - 1, Errors);
        {put_done, Pid, Key, {error, Reason}} ->
            gather_put_results(lists:delete(Pid, Pids),
                               Remaining - 1,
                               [{put_failed, Key, Reason} | Errors])
    after 30_000 ->
        [{put_timeout, outstanding, Remaining} | lists:reverse(Errors)]
    end.

run_concurrent_finds(ReaderPool, Keys) ->
    Parent = self(),
    Finders = [spawn_link(fun() ->
        R = macula:find_record(ReaderPool, Key),
        Parent ! {find_done, self(), Key, R}
    end) || Key <- Keys],
    gather_find_results(Finders, length(Keys), []).

gather_find_results([], 0, Errors) -> lists:reverse(Errors);
gather_find_results(Pids, Remaining, Errors) ->
    receive
        {find_done, Pid, _Key, {ok, _}} ->
            gather_find_results(lists:delete(Pid, Pids),
                                Remaining - 1, Errors);
        {find_done, Pid, Key, Other} ->
            gather_find_results(lists:delete(Pid, Pids),
                                Remaining - 1,
                                [{find_failed, Key, Other} | Errors])
    after 30_000 ->
        [{find_timeout, outstanding, Remaining} | lists:reverse(Errors)]
    end.

classify_dht_concurrency([], []) -> ok;
classify_dht_concurrency(PutErrors, FindErrors) ->
    {error, #{put_errors  => PutErrors,
              find_errors => FindErrors}}.

%%====================================================================
%% Concurrent / interleaved probes — content sharing
%%====================================================================

%% @doc N concurrent put_content calls; after replication delay,
%% get each content back; assert byte-for-byte match. Single-pool
%% variant.
-spec many_concurrent_blobs(NumBlobs :: pos_integer(),
                            macula:pool()) -> result().
many_concurrent_blobs(NumBlobs, Pool) ->
    do_many_concurrent_blobs(NumBlobs, Pool, Pool).

%% @doc Cross-station variant — Writer puts on one station, Reader
%% fetches from a different one. Stresses content's eager k=3
%% replication + 1-hop iterative fetch under burst load.
-spec cross_station_many_concurrent_blobs(
        pos_integer(), macula:pool(), macula:pool()) -> result().
cross_station_many_concurrent_blobs(NumBlobs, WriterPool, ReaderPool) ->
    do_many_concurrent_blobs(NumBlobs, WriterPool, ReaderPool).

do_many_concurrent_blobs(NumBlobs, WriterPool, ReaderPool) ->
    Blobs = [{N, crypto:strong_rand_bytes(8192)}
             || N <- lists:seq(1, NumBlobs)],
    Parent = self(),
    Writers = [spawn_link(fun() ->
        R = macula:put_content(WriterPool, Bytes),
        Parent ! {blob_put_done, self(), N, Bytes, R}
    end) || {N, Bytes} <- Blobs],
    Mcids = gather_blob_puts(Writers, NumBlobs, []),
    case Mcids of
        {error, _} = E -> E;
        Pairs ->
            timer:sleep(?DHT_REPLICATION_MS),
            run_concurrent_gets(ReaderPool, Pairs)
    end.

gather_blob_puts([], 0, Acc) -> lists:reverse(Acc);
gather_blob_puts(Pids, Remaining, Acc) ->
    receive
        {blob_put_done, Pid, N, Bytes, {ok, MCID}} ->
            gather_blob_puts(lists:delete(Pid, Pids),
                             Remaining - 1,
                             [{N, MCID, Bytes} | Acc]);
        {blob_put_done, _Pid, N, _Bytes, Other} ->
            {error, {blob_put_failed, N, Other,
                     remaining, Remaining - 1,
                     completed, length(Acc)}}
    after 30_000 ->
        {error, {blob_put_timeout, outstanding, Remaining,
                 completed, length(Acc)}}
    end.

run_concurrent_gets(ReaderPool, Pairs) ->
    Parent = self(),
    Getters = [spawn_link(fun() ->
        R = macula:get_content(ReaderPool, MCID),
        Parent ! {blob_get_done, self(), N, Bytes, R}
    end) || {N, MCID, Bytes} <- Pairs],
    gather_blob_gets(Getters, length(Pairs), []).

gather_blob_gets([], 0, Errors) ->
    case Errors of
        [] -> ok;
        _  -> {error, {blob_get_errors, lists:reverse(Errors)}}
    end;
gather_blob_gets(Pids, Remaining, Errors) ->
    receive
        {blob_get_done, Pid, _N, Bytes, {ok, Got}} when Got =:= Bytes ->
            gather_blob_gets(lists:delete(Pid, Pids),
                             Remaining - 1, Errors);
        {blob_get_done, Pid, N, _Bytes, {ok, Other}} ->
            gather_blob_gets(lists:delete(Pid, Pids),
                             Remaining - 1,
                             [{blob_byte_mismatch, N,
                               size(Other)} | Errors]);
        {blob_get_done, Pid, N, _Bytes, Other} ->
            gather_blob_gets(lists:delete(Pid, Pids),
                             Remaining - 1,
                             [{blob_get_failed, N, Other} | Errors])
    after 30_000 ->
        [{blob_get_timeout, outstanding, Remaining} | lists:reverse(Errors)]
    end.

%%====================================================================
%% DNS-readiness probes — tombstone propagation latency
%%====================================================================

%% @doc Single-station tombstone propagation. Same pool puts the
%% record then the tombstone; the reader on the same station polls
%% find_record and measures time-to-tombstone-visible.
-spec tombstone_propagation(macula:pool(), macula:realm()) -> result().
tombstone_propagation(Pool, Realm) ->
    do_tombstone_propagation(Pool, Pool, Realm, 60_000).

%% @doc Cross-station tombstone propagation — Writer puts on one
%% station, then puts the tombstone; Reader on a DIFFERENT station
%% polls. Measures the cross-station replication path's tombstone
%% propagation latency. Target for DNS: p95 ≤ 30s (gives 30s
%% headroom on DNS-over-mesh's 60s success criterion).
-spec cross_station_tombstone_propagation(macula:pool(), macula:pool(),
                                          macula:realm()) -> result().
cross_station_tombstone_propagation(WriterPool, ReaderPool, Realm) ->
    do_tombstone_propagation(WriterPool, ReaderPool, Realm, 60_000).

do_tombstone_propagation(WriterPool, ReaderPool, Realm, MaxWaitMs) ->
    Identity = macula_identity:generate(),
    NodeId   = macula_identity:public(Identity),
    Record   = macula_record:node_record(NodeId, [Realm], 0),
    Signed   = macula_record:sign(Record, Identity),
    Key      = macula_record:storage_key(Signed),
    case macula:put_record(WriterPool, Signed) of
        ok ->
            timer:sleep(?DHT_REPLICATION_MS),
            case wait_until_visible(ReaderPool, Key, fun is_node_record/1, 10_000) of
                ok ->
                    Tombstone = macula_record:sign(
                        macula_record:tombstone(NodeId,
                            macula_record_type_node_record(),
                            superseded), Identity),
                    PutAt = erlang:monotonic_time(millisecond),
                    case macula:put_record(WriterPool, Tombstone) of
                        ok ->
                            classify_tombstone_visible(
                                wait_until_visible(ReaderPool, Key,
                                                   fun is_tombstone/1, MaxWaitMs),
                                erlang:monotonic_time(millisecond) - PutAt);
                        {error, _} = E -> E
                    end;
                {error, _} = E -> {error, {original_not_visible, E}}
            end;
        {error, _} = E -> E
    end.

classify_tombstone_visible(ok, LatencyMs) ->
    %% Returning the latency in `ok' tuple lets a future test assert
    %% on a threshold; CT case currently only treats this as ok|error.
    {ok, LatencyMs};
classify_tombstone_visible({error, Reason}, _) ->
    {error, {tombstone_not_visible, Reason}}.

%% Hardcoded: 0x01 = ?TYPE_NODE_RECORD per macula_record.erl.
%% Avoids depending on a non-exported macro.
macula_record_type_node_record() -> 16#01.

%% Poll find_record at 250ms intervals until Pred(Record) returns
%% true or MaxWaitMs elapses. Used both for "wait until original
%% visible" and "wait until tombstone visible".
wait_until_visible(Pool, Key, Pred, MaxWaitMs) ->
    Deadline = erlang:monotonic_time(millisecond) + MaxWaitMs,
    wait_until_visible_loop(Pool, Key, Pred, Deadline).

wait_until_visible_loop(Pool, Key, Pred, Deadline) ->
    case macula:find_record(Pool, Key) of
        {ok, Rec} ->
            case Pred(Rec) of
                true  -> ok;
                false ->
                    sleep_or_timeout(Pool, Key, Pred, Deadline)
            end;
        _NotFoundOrError ->
            sleep_or_timeout(Pool, Key, Pred, Deadline)
    end.

sleep_or_timeout(Pool, Key, Pred, Deadline) ->
    case erlang:monotonic_time(millisecond) > Deadline of
        true  -> {error, {wait_until_visible_timeout, Key}};
        false -> timer:sleep(250),
                 wait_until_visible_loop(Pool, Key, Pred, Deadline)
    end.

is_node_record(#{type := T}) when T =:= 16#01 -> true;
is_node_record(_)                             -> false.

is_tombstone(#{type := T}) when T =:= 16#0C -> true;
is_tombstone(_)                             -> false.

%%====================================================================
%% DNS-readiness probes — subscribe_records semantics
%%====================================================================

%% @doc Single-station baseline: SubPool subscribes to records of
%% type 0x01 (node_record); WriterPool puts a record of that type;
%% assert subscriber's callback fires within bounded window. Same
%% pool variant — confirms the local subscribe path works at all.
-spec subscribe_records_local(macula:pool(), macula:realm()) -> result().
subscribe_records_local(Pool, Realm) ->
    do_subscribe_records(Pool, Pool, Realm, 5_000).

%% @doc Cross-station: WriterPool puts on one station; SubPool
%% subscribes from a DIFFERENT station; assert the callback fires
%% within 10s. The DNS slice's `on_record_observed_invalidate_cache'
%% PM depends on this firing for cross-station-replicated records;
%% if it doesn't, the cache-invalidation logic is structurally
%% broken and the slice serves stale records forever.
-spec subscribe_records_cross_station(macula:pool(), macula:pool(),
                                      macula:realm()) -> result().
subscribe_records_cross_station(WriterPool, ReaderPool, Realm) ->
    do_subscribe_records(WriterPool, ReaderPool, Realm, 10_000).

do_subscribe_records(WriterPool, ReaderPool, Realm, MaxWaitMs) ->
    Self = self(),
    Tag  = make_ref(),
    Callback = fun(Rec) -> Self ! {sub_record, Tag, Rec} end,
    case macula:subscribe_records(ReaderPool,
                                  macula_record_type_node_record(),
                                  Callback) of
        {ok, SubRef} ->
            timer:sleep(?SUBSCRIBE_SETTLE_MS),
            Identity = macula_identity:generate(),
            NodeId   = macula_identity:public(Identity),
            Record   = macula_record:node_record(NodeId, [Realm], 0),
            Signed   = macula_record:sign(Record, Identity),
            Key      = macula_record:storage_key(Signed),
            PutAt    = erlang:monotonic_time(millisecond),
            Result =
                case macula:put_record(WriterPool, Signed) of
                    ok ->
                        await_record_callback(Tag, Key, PutAt, MaxWaitMs);
                    {error, _} = E -> E
                end,
            catch macula:unsubscribe_records(ReaderPool, SubRef),
            Result;
        {error, _} = E -> {error, {subscribe_failed, E}}
    end.

await_record_callback(Tag, ExpectedKey, PutAt, TimeoutMs) ->
    receive
        {sub_record, Tag, #{key := Key} = _Rec}
          when Key =:= ExpectedKey ->
            {ok, erlang:monotonic_time(millisecond) - PutAt};
        {sub_record, Tag, _OtherRec} ->
            %% Some other record observation — ignore + keep waiting.
            await_record_callback(Tag, ExpectedKey, PutAt, TimeoutMs)
    after TimeoutMs ->
        {error, {no_record_callback_within_ms, TimeoutMs}}
    end.

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
