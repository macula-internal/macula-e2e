%%% @doc The multi-publisher probe must tell a refused publish from a lost
%%% event, and name the events it lost.
%%%
%%% On 2026-09-10 cross_station_multi_publisher_pubsub failed on the live
%%% fleet with 49 of 50 events. The probe could not say more: its senders
%%% threw away what `macula:publish/4' returned, so a publish refused on the
%%% sending side looked exactly like an event the mesh lost, and the error
%%% carried counts, not which event was missing. A missing first message
%%% points at subscription convergence, a missing middle one at delivery.
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
