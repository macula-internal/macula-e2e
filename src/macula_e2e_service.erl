%%%-------------------------------------------------------------------
%%% @doc One service in the two-service torture — a pool pinned to ONE
%%% station, plus the full surface a real service exposes.
%%%
%%% The existing probe module opens two pools against the same
%%% bootstrap and calls them "server" and "caller". That measures the
%%% SDK talking to itself through one station. A service is more than a
%%% pool: it advertises procedures that can succeed, refuse and crash;
%%% it advertises a stream; it subscribes to an inbox and keeps
%%% listening. Those are the things that break in production, and none
%%% of them are exercised by a pool with no surface.
%%%
%%% Every name this service claims is namespaced by
%%% `{RunId, ServiceName}' so two services share one realm without
%%% colliding, and so a rerun never lands on the previous run's
%%% station-side state. That matters more than it looks: the SDK's
%%% `unsubscribe/2' is a local filter and the WIRE subscription
%%% persists for the pool's lifetime, so topic names accumulate on the
%%% station whether or not the client thinks it unsubscribed.
%%%
%%% == The advertised surface ==
%%%
%%% <ul>
%%%   <li>`echo'   — replies `{ok, #{got => Args}}'. The happy path.</li>
%%%   <li>`refuse' — replies `{error, <<"hold_full">>}'. This is macula
%%%       8.0.0's headline contract: a service can say WHY it refused.
%%%       Before 8.0.0 every refusal in the world arrived as
%%%       `{error, {call_error, 15, unknown_error}}'.</li>
%%%   <li>`crash'  — raises. A caller must get a failure, and the
%%%       service must still be serving afterwards.</li>
%%%   <li>`slow'   — sleeps past a short deadline, so a caller's
%%%       timeout can be observed rather than assumed.</li>
%%%   <li>`count'  — a `server_stream' emitting N ordered chunks.</li>
%%% </ul>
%%% @end
%%%-------------------------------------------------------------------
-module(macula_e2e_service).

-export([start/3, stop/1,
         pool/1, name/1, station/1, realm/1, node_id/1,
         procedure/2, topic/2,
         advertise_all/1, unadvertise/2,
         refusal_reason/0, slow_delay_ms/0]).

-export_type([service/0]).

-define(WAIT_HEALTHY_MS, 30_000).
-define(POLL_MS,            250).
-define(REFUSAL_REASON, <<"hold_full">>).
-define(SLOW_DELAY_MS,     3_000).

-record(service, {
    name    :: binary(),
    run_id  :: binary(),
    station :: string(),
    realm   :: macula:realm(),
    pool    :: macula:pool()
}).

-opaque service() :: #service{}.

%%====================================================================
%% Lifecycle
%%====================================================================

%% @doc Start a service: dial `Station', wait for a healthy link, then
%% claim the whole advertised surface. Fails rather than returning a
%% half-built service — a service that is up but not advertising is the
%% exact state that makes a torture result meaningless.
-spec start(binary(), string(), binary()) ->
    {ok, service()} | {error, term()}.
start(Name, Station, RunId) ->
    Seed = macula_e2e_fleet:seed_url(Station),
    on_connected(macula:connect([Seed], #{}), Name, Station, RunId).

on_connected({error, _} = E, _Name, _Station, _RunId) ->
    E;
on_connected({ok, Pool}, Name, Station, RunId) ->
    unlink(Pool),
    Service = #service{name = Name, run_id = RunId, station = Station,
                       realm = macula_realm:id(<<"_duel">>), pool = Pool},
    on_healthy(wait_healthy(Pool, ?WAIT_HEALTHY_MS), Service).

on_healthy(timeout, #service{pool = Pool, station = Station}) ->
    catch macula:close(Pool),
    {error, {station_not_reachable, Station}};
on_healthy(ok, Service) ->
    advertise_all(Service),
    {ok, Service}.

-spec stop(service()) -> ok.
stop(#service{pool = Pool} = Service) ->
    [catch macula:unadvertise(Pool, realm(Service), procedure(Service, P))
     || P <- unary_procedures()],
    catch macula:unadvertise_stream(Pool, realm(Service),
                                    procedure(Service, <<"count">>)),
    catch macula:close(Pool),
    ok.

%%====================================================================
%% Accessors
%%====================================================================

-spec pool(service()) -> macula:pool().
pool(#service{pool = P}) -> P.

-spec name(service()) -> binary().
name(#service{name = N}) -> N.

-spec station(service()) -> string().
station(#service{station = S}) -> S.

-spec realm(service()) -> macula:realm().
realm(#service{realm = R}) -> R.

%% @doc The station's node id as this service's pool sees it. Two
%% services reporting the SAME node id are not on two stations, and
%% every cross-station claim in the run would be fabricated.
-spec node_id(service()) -> binary() | undefined.
node_id(#service{pool = Pool}) ->
    {ok, Links} = macula:links(Pool),
    Ids = [maps:get(node_id, L) || L <- Links,
                                   maps:get(connected, L) =:= true,
                                   maps:get(node_id, L) =/= undefined],
    first_or_undefined(Ids).

first_or_undefined([])      -> undefined;
first_or_undefined([N | _]) -> N.

%% @doc Fully qualified procedure name owned by this service.
-spec procedure(service(), binary()) -> macula:procedure().
procedure(#service{name = Name, run_id = RunId}, Suffix) ->
    <<"duel.", RunId/binary, ".", Name/binary, ".", Suffix/binary>>.

%% @doc Fully qualified topic owned by this service.
-spec topic(service(), binary()) -> macula:topic().
topic(#service{name = Name, run_id = RunId}, Suffix) ->
    <<"duel.", RunId/binary, ".", Name/binary, ".", Suffix/binary>>.

%% @doc The reason the `refuse' handler answers with. A caller must see
%% this exact binary, not a generic transport error.
-spec refusal_reason() -> binary().
refusal_reason() -> ?REFUSAL_REASON.

%% @doc How long the `slow' handler sleeps before replying.
-spec slow_delay_ms() -> pos_integer().
slow_delay_ms() -> ?SLOW_DELAY_MS.

%%====================================================================
%% Advertised surface
%%====================================================================

%% @doc Claim every procedure and stream this service owns. Exposed so
%% a torture round can re-advertise after deliberately unadvertising.
-spec advertise_all(service()) -> ok.
advertise_all(#service{pool = Pool} = Service) ->
    Realm = realm(Service),
    [ok = macula:advertise(Pool, Realm, procedure(Service, P),
                           handler(P), #{})
     || P <- unary_procedures()],
    ok = macula:advertise_stream(Pool, Realm,
                                 procedure(Service, <<"count">>),
                                 server_stream, fun count_handler/2),
    ok.

%% @doc Drop one procedure. A call to it must then fail — which is the
%% assertion no probe in this repo has ever made.
-spec unadvertise(service(), binary()) -> ok | {error, term()}.
unadvertise(#service{pool = Pool} = Service, Suffix) ->
    macula:unadvertise(Pool, realm(Service), procedure(Service, Suffix)).

unary_procedures() ->
    [<<"echo">>, <<"refuse">>, <<"crash">>, <<"slow">>].

handler(<<"echo">>)   -> fun echo_handler/1;
handler(<<"refuse">>) -> fun refuse_handler/1;
handler(<<"crash">>)  -> fun crash_handler/1;
handler(<<"slow">>)   -> fun slow_handler/1.

echo_handler(Args) ->
    {ok, #{<<"got">> => Args}}.

%% The whole point of macula 8.0.0. If this reason does not survive the
%% hop, a caller cannot tell "the hold is full" from "the mesh broke".
refuse_handler(_Args) ->
    {error, ?REFUSAL_REASON}.

crash_handler(_Args) ->
    erlang:error(deliberate_handler_crash).

slow_handler(Args) ->
    timer:sleep(?SLOW_DELAY_MS),
    {ok, #{<<"got">> => Args}}.

%% Emits 1..N in order. Order is asserted by the caller — no pubsub
%% probe in this repo asserts ordering, because they all fold into a
%% set, so the stream is the one place ordering is checkable today.
count_handler(Stream, Args) ->
    N = count_arg(Args),
    [ok = macula:send(Stream, integer_to_binary(I)) || I <- lists:seq(1, N)],
    macula:close_stream(Stream).

count_arg(#{<<"n">> := N}) -> N;
count_arg(#{n := N})       -> N.

%%====================================================================
%% Internal
%%====================================================================

wait_healthy(_Pool, Left) when Left =< 0 ->
    timeout;
wait_healthy(Pool, Left) ->
    {ok, #{healthy_links := H}} = macula:status(Pool),
    on_health(H, Pool, Left).

on_health(H, _Pool, _Left) when H > 0 -> ok;
on_health(_H, Pool, Left) ->
    timer:sleep(?POLL_MS),
    wait_healthy(Pool, Left - ?POLL_MS).
