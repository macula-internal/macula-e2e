%% @doc mcl-tube's `lookup_content' as macula-portal calls it, and the io.macula
%% tube page's eight thumbnail MCIDs.
%%
%% macula-io/macula-portal#89: a normal load of a channel page fires its eight
%% thumbnails at once, from ONE pool, each inside the portal's own 5 s call
%% deadline. The live failure is 2 x 200 at 0.85 s and 6 x 404 at ~5.2 s, so a
%% probe has to be the PAGE's eight lookups against the real service: an echo
%% the harness advertises itself measures the harness.
%%
%% The portal's side of this contract is
%% `macula-io/macula-portal' `system/apps/tube/lib/tube/remote_lookup.ex',
%% last changed at commit f0246a23 (2026-10-05): provider org `mcl-tube',
%% payload `%{mcid => hex}', 5 s. The provider's side is
%% `macula-services/mcl-tube'
%% `apps/query_tube/src/advertise_content_lookup/advertise_content_lookup.erl',
%% which answers `#{bytes => Bytes}' and only for an MCID something public
%% still names.
%%
%% The MCIDs are the eight thumbnails the page named on 2026-11-01, read from
%% the page itself. Each is a SHA-384 raw block id (macula D24) --
%% `<<2, 16#55, SHA-384(Bytes):48>>', 100 hex characters -- so a caller can
%% check the bytes it got without trusting the service's word: they must hash
%% to the MCID that caller asked for. `bytes_match/2' is that check, and the
%% offline test pins it with a vector of its own rather than a page MCID.
-module(macula_e2e_mcl_tube).

-export([procedure/0, payload/1, mcids/0, deadline_ms/0, bytes_match/2,
         is_mcid/1]).

-define(TAG_SHA384, 2).
-define(CODEC_RAW, 16#55).

%% @doc The mesh procedure the portal calls: mcl-tube's org, its RPC name.
-spec procedure() -> macula:procedure().
procedure() ->
    <<"mcl-tube/lookup_content">>.

%% @doc The payload the portal sends. The key is an ATOM, as Elixir writes it
%% (`%{mcid: mcid_hex}'), so the probe sends the same bytes the portal does.
-spec payload(binary()) -> map().
payload(McidHex) ->
    #{mcid => McidHex}.

%% @doc The page's eight thumbnails, in the order the page asks for them.
-spec mcids() -> [binary()].
mcids() ->
    [<<"025530cf31ffa6665caae517375b95ca03399416d0640d8b5e9d8bd030e0d1f19224dbfb3e2464f56342e6a5540af0a5e4c3">>,
     <<"025575f6e1f9f46f6f1ca5e3def899496fa3ad68b82cc6cb7a0fa61ae9e67721ac14649fff20bf8a2780a2bbb241e3fe20b7">>,
     <<"0255771076b710b24209d7a887c086ae49d1825b2f56080756035caf24bd8b12abe70975a92de74d6263c359534570857f09">>,
     <<"02557d2a4ce2b309378d10d22674cc9653ed8d16a91ede7720a061b83cf058e6f94d1ed895e92fce507bbcf9abca95f9833b">>,
     <<"02558d8aea18c2018f498c2b52a164b5fbfdac59c00eaaacc5ce20aa15cebf12d5a6884b2befba500fa7d56207f4ee4fed38">>,
     <<"0255b209da69d0b68ab70df4be6f6a4ce94147f7e71fe1e1cb31b72f1008ff924b6b6f7a1facc1e224869e2b8c3a26dcbe78">>,
     <<"0255b35c6ab6573a4fd2486b67a8588f383de4ecbb1276e982e275d98172d180808d478d398389cc3d89ff8ab26b8c580f81">>,
     <<"0255badcfb602ff4f6c65429b52b396724019bebdbae3635fa373029c2db858c9e0e00b287717a30bc307a9c409bcfab4f2b">>].

%% @doc The portal's own call deadline for one lookup.
-spec deadline_ms() -> pos_integer().
deadline_ms() ->
    5_000.

%% @doc True when `Bytes' are the content `McidHex' names.
-spec bytes_match(binary(), binary()) -> boolean().
bytes_match(Bytes, McidHex) when is_binary(Bytes), is_binary(McidHex) ->
    case decode(McidHex) of
        {ok, <<?TAG_SHA384, ?CODEC_RAW, Hash:48/binary>>} ->
            crypto:hash(sha384, Bytes) =:= Hash;
        _ ->
            false
    end.

%% @doc True for a SHA-384 raw block id, the only kind lookup_content serves.
-spec is_mcid(term()) -> boolean().
is_mcid(McidHex) ->
    case decode(McidHex) of
        {ok, <<?TAG_SHA384, ?CODEC_RAW, _Hash:48/binary>>} -> true;
        _ -> false
    end.

decode(Hex) when is_binary(Hex), byte_size(Hex) =:= 100 ->
    case hex_only(Hex) of
        true  -> {ok, binary:decode_hex(Hex)};
        false -> error
    end;
decode(_Other) ->
    error.

hex_only(Hex) ->
    re:run(Hex, <<"\\A[0-9a-fA-F]{100}\\z">>, [{capture, none}]) =:= match.
