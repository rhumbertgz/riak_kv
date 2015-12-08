%%
%%  Equivalence tests between Erlang and NIF protobuf encoder/decoders
%%
-module(kv_ts_nif_eqc).
-compile([export_all]).

%-ifdef(EQC).
-include_lib("eqc/include/eqc.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("riak_pb/include/riak_ts_pb.hrl").

%% ====================================================================
%% Eunit
%% ====================================================================
-define(QC_OUT(P),
        eqc:on_output(fun(Str, Args) ->
                              io:format(user, Str, Args) end, P)).

encode_tsputreq_equivalent_test_() ->
    {timeout, 15000, % do not trust the docs - timeout is in msec
      ?_assertEqual(true, quickcheck(eqc:testing_time(10, ?QC_OUT(
                                     prop_encode_tsputreq_equivalent()))))}.

decode_tsputreq_equivalent_test_() ->
    {timeout, 15000, % do not trust the docs - timeout is in msec
      ?_assertEqual(true, quickcheck(eqc:testing_time(10, ?QC_OUT(
                                     prop_decode_tsputreq_equivalent()))))}.

decode_tsputreq_truncate_test_() ->
    {timeout, 15000, % do not trust the docs - timeout is in msec
      ?_assertEqual(true, quickcheck(eqc:testing_time(5, ?QC_OUT(
                                     prop_decode_tsputreq_truncate()))))}.
decode_tsputreq_fuzz_test_() ->
    {timeout, 15000, % do not trust the docs - timeout is in msec
      ?_assertEqual(true, quickcheck(eqc:testing_time(5, ?QC_OUT(
                                     prop_decode_tsputreq_fuzz()))))}.


encode_tsqueryresp_equivalent_test_() ->
    {timeout, 15000, % do not trust the docs - timeout is in msec
      ?_assertEqual(true, quickcheck(eqc:testing_time(10, ?QC_OUT(
                                     prop_encode_tsqueryresp_equivalent()))))}.

decode_tsqueryresp_equivalent_test_() ->
    {timeout, 15000, % do not trust the docs - timeout is in msec
      ?_assertEqual(true, quickcheck(eqc:testing_time(10, ?QC_OUT(
                                     prop_decode_tsqueryresp_equivalent()))))}.

decode_tsqueryresp_truncate_test_() ->
    {timeout, 15000, % do not trust the docs - timeout is in msec
      ?_assertEqual(true, quickcheck(eqc:testing_time(5, ?QC_OUT(
                                     prop_decode_tsqueryresp_truncate()))))}.
decode_tsqueryresp_fuzz_test_() ->
    {timeout, 15000, % do not trust the docs - timeout is in msec
      ?_assertEqual(true, quickcheck(eqc:testing_time(5, ?QC_OUT(
                                     prop_decode_tsqueryresp_fuzz()))))}.


%% ====================================================================
%% Generators
%% ====================================================================

table() ->
     non_empty(binary()).

row() ->
    #tsrow{cells = list(cell())}.

column() ->
    #tscolumndescription{name = non_empty(binary()),
                         type = oneof(['VARCHAR','SINT64','DOUBLE',
                                       'TIMESTAMP','BOOLEAN'])}.

cell() -> % generate a cell where only one is present
    ?LET(
       {Index, _Varchar, _Sint64, _TS, _Bool, _Double}=Seed,
       {choose(2,6), non_empty(binary()), largeint(), nat(), bool(), real()},
       begin
           Value = element(Index, Seed),
           setelement(Index, #tscell{}, Value)
       end).

%%
%% Generate #tsputreq{} record
%%
gen_tsputreq() ->
    #tsputreq{table = table(),
              columns = oneof([undefined, list(column())]),
              rows = non_empty(list(row()))
             }.

%%
%% Generate #tsqueryresp{} record
%%
gen_tsqueryresp() ->
    #tsqueryresp{columns = oneof([undefined, list(column())]),
                 rows = list(row()),
                 done = oneof([undefined, true, false])}.


%% ====================================================================
%% riak_pb_codec.cc eqc property
%% ====================================================================

%% Generate a #tsputreq{} and compare the binary generated by the
%% Erlang code and the NIF
%%
%% Differences
%% - NIF does not permit empty columns and rows
%% - NIF does not encode column descriptions
prop_encode_tsputreq_equivalent() ->
    ?FORALL(TsPutReq,
            gen_tsputreq(),
            begin
                %% Error codes not exact, so just check for errors
                ErlBin = try
                             iolist_to_binary(riak_ts_pb:encode_tsputreq(TsPutReq))
                         catch
                             _:_ ->
                                 error
                         end,
                NifBin = try
                             MsgCode = riak_pb_messages:msg_code(tsputreq),
                             <<MsgCode:8, NifBin0/binary>> = riak_pb_codec:encode_tsputreq(TsPutReq),
                             NifBin0
                         catch
                             _:_ ->
                                 error
                         end,
                ?WHENFAIL(
                   begin
                       eqc:format("DecodedErlBin: ~w\n", [catch riak_ts_pb:decode_tsputreq(ErlBin)]),
                       eqc:format("DecodedNifBin: ~w\n", [catch riak_ts_pb:decode_tsputreq(NifBin)])
                   end,
                   equals(ErlBin, NifBin))
            end).

%% Generate an encoded #tsqueryresp{} binary and test the decoded record is the
%% same for Erlang code and the NIF
%%
%% Differences
%% - NIF flips the done bool
prop_decode_tsqueryresp_equivalent() ->
    ?FORALL(TSQueryResp,
            gen_tsqueryresp(),
            begin
                TSQueryRespBin = iolist_to_binary(riak_ts_pb:encode_tsqueryresp(TSQueryResp)),
                ErlTerm = riak_ts_pb:decode_tsqueryresp(TSQueryRespBin),
                MsgCode = riak_pb_messages:msg_code(tsqueryresp),
                NifTerm = riak_pb_codec:decode(MsgCode, TSQueryRespBin),
                case TSQueryRespBin of
                    <<>> ->   %% Erlang code decodes to atom name, NIF decodes to record
                        true; %% but still worth checking it doesn't explode
                    _ ->
                        equals(ErlTerm, NifTerm)
                end
            end).


%%
%% Generate valid encodings and truncate
%%
prop_decode_tsqueryresp_truncate() ->
    ?FORALL({TSQueryResp, TruncSeed},
            {gen_tsqueryresp(), nat()},
            begin
                %% Generate a plausible encoding then truncate it.  It may
                %% truncate on a field boundary and be safe
                TSQueryRespBin0 = iolist_to_binary(riak_ts_pb:encode_tsqueryresp(TSQueryResp)),
                TSQueryRespBin = case TSQueryRespBin0 of
                                     <<>> ->
                                         TSQueryRespBin0;
                                     _ ->
                                         TruncLen = 1 + (TruncSeed rem (size(TSQueryRespBin0) -1)),
                                         binary_part(TSQueryRespBin0, {0, TruncLen})
                                 end,
                ErlTerm = try
                              riak_ts_pb:decode_tsqueryresp(TSQueryRespBin)
                          catch
                              _:_ ->
                                  error
                          end,
                MsgCode = riak_pb_messages:msg_code(tsqueryresp),
                NifTerm = try
                              riak_pb_codec:decode(MsgCode, TSQueryRespBin)
                          catch
                              _:_ ->
                                  error
                          end,
                case TSQueryRespBin of
                    <<>> ->   %% Erlang code decodes to atom name, NIF decodes to record
                        true; %% but still worth checking it doesn't explode
                    _ ->
                        equals(ErlTerm, NifTerm)
                end
            end).

%%
%% Decode random binaries hunting for SEGV/other nasties
%% This ended up more complciated than the other _fuzz test
%% as the both decoders were more permissive
%%
prop_decode_tsqueryresp_fuzz() ->
    ?FORALL(TSQueryRespBin,
            non_empty(eqc_gen:largebinary()),
            begin
                %% Generate a random binary while looking for faults
                {ErlTerm,ErlBin} =
                    try
                        ET=riak_ts_pb:decode_tsqueryresp(TSQueryRespBin),
                        {ET, riak_ts_pb:encode_tsqueryresp(ET)}
                    catch
                        _:_ ->
                            {error, error}
                    end,
                MsgCode = riak_pb_messages:msg_code(tsqueryresp),
                {NifTerm,NifBin} =
                    try
                        NT=riak_pb_codec:decode(MsgCode, TSQueryRespBin),
                        <<MsgCode:8, NifBin0/binary>> = riak_pb_codec:encode_tsqueryresp(NT),
                        {NT, NifBin0}
                    catch
                        _:_ ->
                            {error, error}
                    end,
                case TSQueryRespBin of
                    <<>> ->   %% Erlang code decodes to atom name, NIF decodes to record
                        true; %% but still worth checking it doesn't explode
                    _ ->
                        %% Erlang decoder seems to be more tolerant of crap,
                        %% this is a negative test so just check both are errors.
                        %% If they can round trip back to the binary exactly,
                        %% expect the other one to.
                        case {ErlTerm, NifTerm} of
                            {error, error} ->
                                true;
                            {error, _} ->
                                %% It is an error if it can roundtrip, so ok
                                %% if the two are different.
                                TSQueryRespBin /= NifBin;
                            {_, error} ->
                                TSQueryRespBin /= ErlBin;
                            _ ->
                                equals(ErlTerm, NifTerm)
                        end
                end
            end).

%% ====================================================================
%% riak_kv_pb_timeseries.cc eqc property
%% ====================================================================

prop_decode_tsputreq_equivalent() ->
    ?FORALL(TSPutReq,
            gen_tsputreq(),
            begin
                TSPutReqBin = iolist_to_binary(riak_ts_pb:encode_tsputreq(TSPutReq)),
                ErlTerm = riak_ts_pb:decode_tsputreq(TSPutReqBin),
                MsgCode = riak_pb_messages:msg_code(tsputreq),
                NifTerm = riak_pb_codec:decode(MsgCode, TSPutReqBin),
                case TSPutReqBin of
                    <<>> ->   %% Erlang code decodes to atom name, NIF decodes to record
                        true; %% but still worth checking it doesn't explode
                    _ ->
                        equals(ErlTerm, NifTerm)
                end
            end).


prop_decode_tsputreq_truncate() ->
    ?FORALL({TSPutReq, TruncSeed},
            {gen_tsputreq(), nat()},
            begin
                %% Generate a plausible encoding then truncate it.  It may
                %% truncate on a field boundary and be safe
                TSPutReqBin0 = iolist_to_binary(riak_ts_pb:encode_tsputreq(TSPutReq)),
                TSPutReqBin = case TSPutReqBin0 of
                                  <<>> ->
                                      TSPutReqBin0;
                                  _ ->
                                      TruncLen = 1 + (TruncSeed rem (size(TSPutReqBin0) -1)),
                                      binary_part(TSPutReqBin0, {0, TruncLen})
                              end,
                ErlTerm = try
                              riak_ts_pb:decode_tsputreq(TSPutReqBin)
                          catch
                              _:_ ->
                                  error
                          end,
                MsgCode = riak_pb_messages:msg_code(tsputreq),
                NifTerm = try
                              riak_pb_codec:decode(MsgCode, TSPutReqBin)
                          catch
                              _:_ ->
                                  error
                          end,
                case TSPutReqBin of
                    <<>> ->   %% Erlang code decodes to atom name, NIF decodes to record
                        true; %% but still worth checking it doesn't explode
                    _ ->
                        equals(ErlTerm, NifTerm)
                end
            end).

prop_decode_tsputreq_fuzz() ->
    ?FORALL(TSPutReqBin,
            non_empty(eqc_gen:largebinary()),
            begin
                %% Generate a random binary while looking for faults
                ErlTerm = try
                              riak_ts_pb:decode_tsputreq(TSPutReqBin)
                          catch
                              _:_ ->
                                  error
                          end,
                MsgCode = riak_pb_messages:msg_code(tsputreq),
                NifTerm = try
                              riak_pb_codec:decode(MsgCode, TSPutReqBin)
                          catch
                              _:_ ->
                                  error
                          end,
                case TSPutReqBin of
                    <<>> ->   %% Erlang code decodes to atom name, NIF decodes to record
                        true; %% but still worth checking it doesn't explode
                    _ ->
                        equals(ErlTerm, NifTerm)
                end
            end).
%%
%% Differences, cannot encode empty description/rows.
%%
prop_encode_tsqueryresp_equivalent() ->
    ?FORALL(TsQueryResp,
            ?SUCHTHAT(R, gen_tsqueryresp(), R#tsqueryresp.columns /= undefined andalso
                                             R#tsqueryresp.columns /= []),
            begin
                %% Error codes not exact, so just check for errors
                ErlBin = try
                             iolist_to_binary(riak_ts_pb:encode_tsqueryresp(TsQueryResp))
                         catch
                             _:_ ->
                                 error
                         end,
                NifBin = try
                             MsgCode = riak_pb_messages:msg_code(tsqueryresp),
                             <<MsgCode:8, NifBin0/binary>> = riak_pb_codec:encode_tsqueryresp(TsQueryResp),
                             NifBin0
                         catch
                             _:_ ->
                                 error
                         end,
                ?WHENFAIL(
                   begin
                       eqc:format("DecodedErlBin: ~w\n", [catch riak_ts_pb:decode_tsqueryresp(ErlBin)]),
                       eqc:format("DecodedNifBin: ~w\n", [catch riak_ts_pb:decode_tsqueryresp(NifBin)])
                   end,
                   equals(ErlBin, NifBin))
            end).


%-endif.
