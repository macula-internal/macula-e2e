%%%-------------------------------------------------------------------
%%% @doc Mpong payload generators that mirror what hecate-daemon's
%%% `broadcast_game_state' and `advertise_game' actually publish.
%%%
%%% The harness includes mpong-specific scenarios so the daemon's
%%% production wire shape is exercised against the live fleet without
%%% needing a real hecate-daemon in the loop. The payloads here
%%% replicate the daemon's `mpong_game_engine:broadcast/1' output
%%% byte-for-byte (modulo the random Tick value), including the
%%% double-keyed `game_id' field that `broadcast_game_state:broadcast/2'
%%% builds (`StateMsg#{<<"game_id">> => GameId}' over an atom-keyed
%%% StateMsg).
%%%
%%% Public surface:
%%%
%%%   state_payload(Tick)           — full production state payload
%%%   state_payload(Tick, GameId)   — same with a caller-supplied game_id
%%%   advertised_payload(GameId)    — game_advertised_v1 shape
%%%   state_topic/0, advertise_topic/0 — production topic strings
%%%
%%% The variants in `axis_payload/1' below strip individual features
%%% of the full payload so probes can isolate which CBOR-encode or
%%% relay axis breaks delivery. Each variant carries a binary `token'
%%% field so the harness's existing `extract_token/1' assertion works.
%%% @end
%%%-------------------------------------------------------------------
-module(macula_e2e_mpong).

-export([
    state_payload/1, state_payload/2,
    advertised_payload/1,
    axis_payload/2,
    state_topic/0, advertise_topic/0,
    realm/0
]).

-define(REALM,        <<"io.macula">>).
-define(ORG,          <<"beam-campus">>).
-define(APP,          <<"hecate">>).
-define(DOMAIN,       <<"mpong">>).
-define(STATE_NAME,   <<"state_broadcast">>).
-define(ADV_NAME,     <<"game_advertised">>).
-define(VERSION,      1).

-define(DEFAULT_GAME_ID, <<"e2e-mpong">>).

%%====================================================================
%% Topics + realm
%%====================================================================

%% @doc Same realm string the daemon's `hecate_topics:realm/0' resolves to.
-spec realm() -> binary().
realm() -> ?REALM.

%% @doc Same topic the daemon's `broadcast_game_state:topic/0' builds.
-spec state_topic() -> binary().
state_topic() ->
    macula_topic:app_fact(?REALM, ?ORG, ?APP, ?DOMAIN, ?STATE_NAME, ?VERSION).

%% @doc Same topic the daemon's `advertise_game:topic/0' builds.
-spec advertise_topic() -> binary().
advertise_topic() ->
    macula_topic:app_fact(?REALM, ?ORG, ?APP, ?DOMAIN, ?ADV_NAME, ?VERSION).

%%====================================================================
%% Production payloads
%%====================================================================

%% @doc Full production state_broadcast_v1 payload, byte-equivalent to
%% `mpong_game_engine:broadcast/1' for the given tick. Atom keys
%% throughout the outer + nested maps; integer keys in `paddles' /
%% `alive' / `points' / `games_won'; negative ints in the ball
%% velocity. The trailing `token' field (binary) is harness-specific
%% so `extract_token/1' can dedupe sustained-rate runs.
-spec state_payload(non_neg_integer()) -> map().
state_payload(Tick) -> state_payload(Tick, ?DEFAULT_GAME_ID).

-spec state_payload(non_neg_integer(), binary()) -> map().
state_payload(Tick, GameId) ->
    StateMsg = #{
        game_id   => GameId,
        ball      => #{x  => 500, y  => 300,
                       vx =>  -3, vy =>   2,
                       r  =>   8, spin => 0},
        paddles   => #{0 => 498, 1 => 500},
        alive     => #{0 => true, 1 => true},
        points    => #{0 => Tick rem 11, 1 => (Tick * 7) rem 11},
        games_won => #{0 => 0, 1 => 0},
        serving   => 0,
        obstacles => [],
        paused    => false,
        tick      => Tick,
        arena     => #{w => 1000, h => 1000}
    },
    %% Match `broadcast_game_state:broadcast/2': it adds a separate
    %% binary-keyed `<<"game_id">>' over the atom-keyed StateMsg, so
    %% the wire map carries BOTH keys. Plus the harness `token' so
    %% the drain can dedupe by tick.
    StateMsg#{
        <<"game_id">> => GameId,
        <<"token">>   => integer_to_binary(Tick)
    }.

%% @doc game_advertised_v1 payload. Matches `advertise_game:announce/1'
%% — atom keys, four fields.
-spec advertised_payload(binary()) -> map().
advertised_payload(GameId) ->
    #{
        action       => <<"hosted">>,
        game_id      => GameId,
        host_node_id => <<"e2e-host">>,
        max_players  => 4,
        <<"token">>  => GameId
    }.

%%====================================================================
%% Axis-isolation payloads
%%
%% Each variant exercises one feature of the full state payload in
%% isolation. Probes that round-trip these can pinpoint which wire
%% feature breaks delivery. All carry a binary `<<"token">>' so
%% `extract_token/1' can match.
%%====================================================================

%% @doc Variant axes:
%%   `atom_keys_only'   — atom-keyed outer map, atom-keyed nested, no
%%                        integer keys, no negative ints.
%%   `int_keys_only'    — binary-keyed outer, ONE integer-keyed nested
%%                        map, no negatives.
%%   `neg_ints_only'    — binary-keyed outer, ONE negative integer in
%%                        a binary-keyed nested map, no int keys.
%%   `int_keys_neg_ints'— int keys AND negative ints, no atom keys.
%%   `atom_keys_neg_ints' — atom keys AND negative ints, no int keys.
%%   `full'             — same as `state_payload(Tick)'.
-spec axis_payload(atom(), non_neg_integer()) -> map().
axis_payload(atom_keys_only, Tick) ->
    #{
        token   => Tick,
        kind    => atom_keys_only,
        tick    => Tick,
        nested  => #{alpha => 1, beta => 2, gamma => 3},
        <<"token">> => integer_to_binary(Tick)
    };
axis_payload(int_keys_only, Tick) ->
    #{
        <<"token">> => integer_to_binary(Tick),
        <<"kind">>  => <<"int_keys_only">>,
        <<"tick">>  => Tick,
        <<"map">>   => #{0 => 100, 1 => 200, 2 => 300}
    };
axis_payload(neg_ints_only, Tick) ->
    #{
        <<"token">> => integer_to_binary(Tick),
        <<"kind">>  => <<"neg_ints_only">>,
        <<"tick">>  => Tick,
        <<"vec">>   => #{<<"vx">> => -3, <<"vy">> => 2}
    };
axis_payload(int_keys_neg_ints, Tick) ->
    #{
        <<"token">> => integer_to_binary(Tick),
        <<"kind">>  => <<"int_keys_neg_ints">>,
        <<"tick">>  => Tick,
        <<"score">> => #{0 => -1, 1 => 2}
    };
axis_payload(atom_keys_neg_ints, Tick) ->
    #{
        token   => Tick,
        kind    => atom_keys_neg_ints,
        tick    => Tick,
        ball    => #{vx => -3, vy => 2},
        <<"token">> => integer_to_binary(Tick)
    };
axis_payload(full, Tick) ->
    state_payload(Tick).
