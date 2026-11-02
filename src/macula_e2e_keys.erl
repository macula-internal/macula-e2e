%% @doc Node identities for the harness.
%%
%% macula 12 removed `macula_identity' (`4c5e2a89'), and with it the
%% `#{identity => Key}' pool option. The replacement is `macula_node_keys',
%% which returns tagged tuples and takes the node's crypto profile and, for an
%% identity the station will admit, a solved puzzle difficulty. This module is
%% the one place that knows that, so a probe never spells the sequence out and
%% the next shape change is a one-file edit.
%%
%% See macula-internal/macula-e2e#1.
-module(macula_e2e_keys).

-export([new/0, new/1, node_id/1]).

%% @doc An identity with no puzzle. Enough for a DHT record's node identity,
%% which never peers with a station.
-spec new() -> macula_node_keys:node_key().
new() ->
    generate(#{}).

%% @doc A puzzle-hardened identity, the kind macula generates by default and
%% the only kind a station admits. `puzzle => false' skips the puzzle.
-spec new(#{puzzle => boolean()}) -> macula_node_keys:node_key().
new(#{puzzle := true}) ->
    generate(#{puzzle_difficulty => macula_node_keys:puzzle_difficulty()});
new(#{puzzle := false}) ->
    generate(#{}).

%% @doc The node id of an identity, as the hex the harness compares against
%% the `caller' a handler reports.
-spec node_id(macula_node_keys:node_key()) -> binary().
node_id(Key) ->
    {ok, NodeId} = macula_node_keys:node_id(Key),
    NodeId.

%% The profile is the application's, exactly as the pools will run it, rather
%% than a constant this module could drift from.
generate(Options) ->
    {ok, Profile} = macula_crypto_profile:configured(),
    {ok, Key} = macula_node_keys:generate(identity, Profile, Options),
    Key.
