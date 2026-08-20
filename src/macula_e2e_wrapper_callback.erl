%%%-------------------------------------------------------------------
%%% @doc Shared callback module for the supervised-primitive-wrapper
%%% probes in `macula_e2e_probe' (macula 9.2.0's macula_subscriber /
%%% macula_response / macula_request / macula_streamer /
%%% macula_stream_sink / macula_feeder / macula_download, and macula
%%% 9.4.0's macula_publisher).
%%%
%%% One module implements every callback these eight behaviours need
%%% (`init/1' is shared verbatim across all of them) and forwards each
%%% event to the parent pid passed as `Args', tagged so a single probe
%%% process can `receive' unambiguously regardless of how many of
%%% these behaviours it has started.
%%% @end
%%%-------------------------------------------------------------------
-module(macula_e2e_wrapper_callback).

-behaviour(macula_subscriber).
-behaviour(macula_publisher).
-behaviour(macula_response).
-behaviour(macula_request).
-behaviour(macula_streamer).
-behaviour(macula_stream_sink).
-behaviour(macula_feeder).
-behaviour(macula_download).

-export([init/1,
         handle_event/4,
         handle_published/2,
         handle_request/2,
         handle_reply/2,
         handle_open/2,
         handle_chunk/2,
         handle_close/2,
         handle_fed/2,
         handle_downloaded/2]).

init(Parent) -> {ok, Parent}.

%% macula_subscriber
handle_event(Topic, Payload, Meta, Parent) ->
    Parent ! {e2e_wrapper, sub_event, Topic, Payload, Meta},
    {noreply, Parent}.

%% macula_publisher (producer side of pubsub)
handle_published(Result, Parent) ->
    Parent ! {e2e_wrapper, published, Result},
    {stop, normal, Parent}.

%% macula_response (provider side of RPC) — echoes the payload back
%% wrapped under an `echo' key, mirroring `unary_rpc/4''s handler.
handle_request(Payload, Parent) ->
    {reply, #{echo => Payload}, Parent}.

%% macula_request (consumer side of RPC)
handle_reply(Result, Parent) ->
    Parent ! {e2e_wrapper, req_reply, Result},
    {stop, normal, Parent}.

%% macula_streamer (provider side of streaming RPC)
handle_open(StreamArgs, Parent) ->
    Parent ! {e2e_wrapper, stream_opened, StreamArgs, self()},
    {ok, Parent}.

%% macula_stream_sink (consumer side of streaming RPC)
handle_chunk(Data, Parent) ->
    Parent ! {e2e_wrapper, sink_chunk, Data},
    {noreply, Parent}.

handle_close(Reason, Parent) ->
    Parent ! {e2e_wrapper, sink_closed, Reason},
    ok.

%% macula_feeder (content put side)
handle_fed(Result, Parent) ->
    Parent ! {e2e_wrapper, fed, Result},
    {stop, normal, Parent}.

%% macula_download (content get side)
handle_downloaded(Result, Parent) ->
    Parent ! {e2e_wrapper, downloaded, Result},
    {stop, normal, Parent}.
