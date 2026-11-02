%%% @doc Offline pins for io.macula's realm key.
%%%
%%% The key is 3118 bytes of public material, copied from the portal. A wrong
%%% nibble does not fail loudly where it is used: the pool simply distrusts
%%% the realm, every `mcl-*' call burns its full deadline, and the run looks
%%% like the bug (#89) rather than like a bad constant. The two identifiers
%%% here are the ones a reviewer can recompute, so a typo turns into a red
%%% eunit run instead of a mystery 5 s.
-module(macula_e2e_io_macula_realm_tests).

-include_lib("eunit/include/eunit.hrl").

-define(M, macula_e2e_io_macula_realm).

%% SHA-256 of the realm NAME, computed here from the name rather than asked
%% of macula, so the pin is not macula's own answer echoed back at it.
realm_id_is_sha256_of_the_realm_name_test() ->
    ?assertEqual(crypto:hash(sha256, <<"io.macula">>), ?M:realm_id()),
    ?assertEqual(32, byte_size(?M:realm_id())).

realm_key_is_the_published_key_test() ->
    Key = ?M:realm_key(),
    ?assertEqual(3118, byte_size(Key)),
    %% sha256 of the key's hex text, as published beside it in the portal.
    Digest = crypto:hash(sha256, hex(Key)),
    ?assertMatch(<<16#99, 16#e4, 16#f0, 16#8c, 16#1a, 16#a3, 16#04, 16#05,
                   16#c1, 16#eb, 16#1e, 16#0e, _/binary>>, Digest),
    %% And the key id the portal's documentation prints.
    ?assertEqual(<<"a50fef96e52b4d68ad112ff42b55dc916cd70e5b283280e8cf3cc5e492459cf6">>,
                 hex(?M:key_id())).

trust_pins_the_realm_id_to_its_key_test() ->
    ?assertEqual(#{?M:realm_id() => ?M:realm_key()}, ?M:trust()).

hex(Bin) ->
    binary:encode_hex(Bin, lowercase).
