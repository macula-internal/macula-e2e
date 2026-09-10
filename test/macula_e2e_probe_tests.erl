%%% @doc Offline checks for macula_e2e_probe that the live fleet cannot make
%%% deterministic.
%%%
%%% The multi-publisher probe must tell a refused publish from a lost
%%% event, and name the events it lost. On 2026-09-10
%%% cross_station_multi_publisher_pubsub failed on the live fleet with 49 of
%%% 50 events. The probe could not say more: its senders threw away what
%%% `macula:publish/4' returned, so a publish refused on the sending side
%%% looked exactly like an event the mesh lost, and the error carried
%%% counts, not which event was missing. A missing first message points at
%%% subscription convergence, a missing middle one at delivery.
%%%
%%% The chunked content probe must prove the manifest path ran. Every other
%%% content probe puts 8 KiB, which is always one block, so a chunked fetch
%%% and its manifest check never ran in the harness.
-module(macula_e2e_probe_tests).
-include_lib("eunit/include/eunit.hrl").

-define(M, macula_e2e_probe).

%% A closed local port: the pool never gets a healthy link, and the SDK has
%% no fallback seeds, so nothing here reaches the fleet.
-define(DEAD_SEED, <<"https://127.0.0.1:9">>).

%% Every publish on a pool without a healthy link returns
%% {error, {transient, no_healthy_station}}. That must come back as
%% publish_failed naming each refused publish, next to what the drain saw.
refused_publish_is_reported_as_publish_failed_test_() ->
    {timeout, 30, fun() ->
        {ok, _} = application:ensure_all_started(macula),
        {ok, Dead} = macula:connect([?DEAD_SEED], #{}),
        Result = ?M:multi_publisher_pubsub(1, 2, Dead, Dead,
                                           macula_realm:id(<<"_test">>),
                                           <<"e2e.probe.refused">>),
        macula:close(Dead),
        Refused = {error, {transient, no_healthy_station}},
        ?assertEqual({error, {publish_failed,
                              [{1, 1, Refused}, {1, 2, Refused}],
                              drained,
                              {error, {missing_pubsub_events,
                                       missing, 2, received_unique, 0,
                                       missing_pairs, [{1, 1}, {1, 2}]}}}},
                     Result)
    end}.

%% Two of four events arrive, one of them twice, plus a payload with no
%% token. The error names the two missing (sender, message) pairs; the
%% duplicate and the stray payload count for nothing.
missing_events_are_named_by_sender_and_message_test() ->
    Ref = make_ref(),
    Deliver = fun(Payload) ->
        self() ! {macula_event, Ref, <<"e2e.probe.missing">>, Payload, #{}}
    end,
    Deliver(#{<<"token">> => <<1:8, 1:24>>}),
    Deliver(#{<<"token">> => <<1:8, 1:24>>}),
    Deliver(#{<<"other">> => 1}),
    Deliver(#{<<"token">> => <<2:8, 2:24>>}),
    Expected = sets:from_list([<<I:8, K:24>> || I <- [1, 2], K <- [1, 2]]),
    ?assertEqual({error, {missing_pubsub_events,
                          missing, 2, received_unique, 2,
                          missing_pairs, [{1, 2}, {2, 1}]}},
                 ?M:drain_pubsub_tokens(Ref, Expected, 50)).

%% An 8 KiB put mints a single-block MCID (codec 16#55), the same way
%% macula_content_transfer does. The chunked probe must refuse it rather
%% than pass on a round-trip that never chunked.
single_block_mcid_is_not_chunked_test() ->
    Bytes = crypto:strong_rand_bytes(8192),
    Mcid = <<1, 16#55, (macula_blake3_nif:hash(Bytes))/binary>>,
    ?assertEqual({error, {not_chunked, Mcid}}, ?M:chunked_mcid(Mcid)).

%% The chunked probe's blob, three full chunks and a partial one at the
%% SDK's default chunk size, gets a manifest MCID (codec 16#56) from
%% macula_manifest, and that MCID passes.
manifest_mcid_is_chunked_test() ->
    {ok, #{mcid := Mcid, chunk_count := 4}, _Chunks} =
        macula_manifest:create(crypto:strong_rand_bytes(3 * 262_144 + 1_000)),
    ?assertEqual({ok, Mcid}, ?M:chunked_mcid(Mcid)).

%% Seen live on 2026-09-10 (cross_station_pubsub_mpong_diag): every publish
%% returned ok, sentinel-a, the first fact published, never arrived, and the
%% suspect and sentinel-b did. The probe must name that outcome instead of
%% reporting partial_delivery, and still fail.
first_sentinel_missing_is_named_test() ->
    Ctx = #{sent_a_token  => <<"sentinel-a">>,
            suspect_token => <<"1">>,
            sent_b_token  => <<"sentinel-b">>},
    Events = [{<<"1">>, #{}}, {<<"sentinel-b">>, #{}}],
    ?assertMatch({error, {first_fact_missing_later_facts_delivered,
                          #{sentinel_a_got := false,
                            suspect_got    := true,
                            sentinel_b_got := true}}},
                 ?M:classify_mpong_diag(Events, Ctx)).
