%%% @doc Offline pins for mcl-tube's lookup contract and the page's MCIDs.
%%%
%%% The probe calls the live service and trusts nothing else about it: what it
%%% accepts as an answer is that the bytes hash to the MCID that asked for
%%% them. These tests pin that rule with a vector of their own, and pin the
%%% page's eight MCIDs as eight DISTINCT SHA-384 raw block ids, so a
%%% mis-transcribed constant is caught here rather than read as a 404 from
%%% the fleet.
-module(macula_e2e_mcl_tube_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, macula_e2e_mcl_tube).

%% macula D24: every MCID lookup_content serves starts with the SHA-384 raw
%% block-id prefix, and is 100 hex characters long.
-define(MCID_PREFIX, <<"0255">>).

every_page_mcid_is_a_distinct_sha384_block_id_test() ->
    Mcids = ?M:mcids(),
    ?assertEqual(8, length(Mcids)),
    ?assertEqual(length(Mcids), length(lists:usort(Mcids))),
    [?assert(?M:is_mcid(Mcid)) || Mcid <- Mcids],
    [?assertEqual(?MCID_PREFIX, binary:part(Mcid, 0, 4)) || Mcid <- Mcids].

the_contract_is_the_portal_s_test() ->
    ?assertEqual(<<"mcl-tube/lookup_content">>, ?M:procedure()),
    ?assertEqual(5_000, ?M:deadline_ms()),
    [Mcid | _] = ?M:mcids(),
    ?assertEqual(#{mcid => Mcid}, ?M:payload(Mcid)).

bytes_match_accepts_the_bytes_the_mcid_names_test() ->
    Bytes = <<"a thumbnail, pretending to be JPEG">>,
    Mcid = mcid_hex(Bytes),
    ?assert(?M:bytes_match(Bytes, Mcid)),
    ?assertNot(?M:bytes_match(<<Bytes/binary, 0>>, Mcid)),
    ?assertNot(?M:bytes_match(<<>>, Mcid)).

bytes_match_refuses_anything_that_is_not_the_id_test() ->
    Bytes = <<"bytes">>,
    ?assertNot(?M:bytes_match(Bytes, mcid_hex(<<"other bytes">>))),
    %% A legacy BLAKE3 id, a wrong length, and 100 characters that are not hex.
    ?assertNot(?M:bytes_match(Bytes, <<"0115", (binary:copy(<<"00">>, 32))/binary>>)),
    ?assertNot(?M:bytes_match(Bytes, <<"0255ab">>)),
    ?assertNot(?M:bytes_match(Bytes, <<"0255", (binary:copy(<<"zz">>, 48))/binary>>)).

is_mcid_names_the_served_kind_and_only_that_test() ->
    ?assert(?M:is_mcid(mcid_hex(<<"anything">>))),
    %% Upper case is the same id; tube mints lower case, a caller may send
    %% upper (Elixir's Base.encode16 does by default).
    ?assert(?M:is_mcid(upper(mcid_hex(<<"anything">>)))),
    ?assertNot(?M:is_mcid(<<"0115", (binary:copy(<<"00">>, 32))/binary>>)),
    ?assertNot(?M:is_mcid(<<"0255ab">>)),
    ?assertNot(?M:is_mcid(<<"0255", (binary:copy(<<"zz">>, 48))/binary>>)).

%% The MCID the tube store mints: <<2, 16#55, SHA-384(Bytes):48>>, as hex.
mcid_hex(Bytes) ->
    binary:encode_hex(<<2, 16#55, (crypto:hash(sha384, Bytes))/binary>>, lowercase).

upper(Hex) ->
    binary:encode_hex(binary:decode_hex(Hex), uppercase).
