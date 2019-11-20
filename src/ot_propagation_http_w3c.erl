%%%------------------------------------------------------------------------
%% Copyright 2019, OpenTelemetry Authors
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% @doc
%% @end
%%%-----------------------------------------------------------------------
-module(ot_propagation_http_w3c).

-export([inject/2,
         encode/1,
         extract/2,
         decode/1]).

-include_lib("opentelemetry_api/include/opentelemetry.hrl").

-define(VERSION, "00").

-define(ZERO_TRACEID, <<"00000000000000000000000000000000">>).
-define(ZERO_SPANID, <<"0000000000000000">>).

-define(HEADER_KEY, <<"traceparent">>).
-define(STATE_HEADER_KEY, <<"tracestate">>).

-spec inject(ot_propagation:http_headers(),
                 {opentelemetry:span_ctx(), opentelemetry:span_ctx() | undefined} | undefined)
                -> ot_propagation:http_headers().
inject(_, {#span_ctx{trace_id=TraceId,
                     span_id=SpanId}, _})
  when TraceId =:= 0 orelse SpanId =:= 0 ->
    [];
inject(_, {SpanCtx=#span_ctx{}, _}) ->
    EncodedValue = encode(SpanCtx),
    [{?HEADER_KEY, EncodedValue} | encode_tracestate(SpanCtx)];
inject(_, undefined) ->
    [].

-spec encode(opencensus:span_ctx()) -> iolist().
encode(#span_ctx{trace_id=TraceId,
                 span_id=SpanId,
                 trace_flags=TraceOptions}) ->
    Options = case TraceOptions band 1 of 1 -> <<"01">>; _ -> <<"00">> end,
    EncodedTraceId = io_lib:format("~32.16.0b", [TraceId]),
    EncodedSpanId = io_lib:format("~16.16.0b", [SpanId]),
    [?VERSION, "-", EncodedTraceId, "-", EncodedSpanId, "-", Options].

encode_tracestate(#span_ctx{tracestate=undefined}) ->
    [];
encode_tracestate(#span_ctx{tracestate=Entries}) ->
    StateHeaderValue = lists:join($,, [[Key, $=, Value] || {Key, Value} <- Entries]),
    [{?STATE_HEADER_KEY, StateHeaderValue}].

-spec extract(ot_propagation:http_headers(), term()) -> opentelemetry:span_ctx() | undefined.
extract(Headers, _) when is_list(Headers) ->
    case lists:keyfind(?HEADER_KEY, 1, Headers) of
        {_, Value} ->
            case decode(Value) of
                undefined ->
                    undefined;
                SpanCtx ->
                    Tracestate = tracestate_from_headers(Headers),
                    SpanCtx#span_ctx{tracestate=Tracestate}
            end;
        _ ->
            undefined
    end;
extract(_, _) ->
    undefined.

tracestate_from_headers(Headers) ->
    %% could be multiple tracestate headers. Combine them all with comma separators
    case combine_headers(?STATE_HEADER_KEY, Headers) of
        [] ->
            undefined;
        FieldValue ->
            tracestate_decode(FieldValue)
    end.

combine_headers(Key, Headers) ->
    lists:foldl(fun({K, V}, Acc) ->
                        case string:equal(K, Key) of
                            true ->
                                [V, $, | Acc];
                            false ->
                                Acc
                        end
                end, [], Headers).

tracestate_decode(Value) ->
    %% TODO: the 512 byte limit should not include optional white space that can
    %% appear between list members.
    case iolist_size(Value) of
        Size when Size =< 512 ->
            [split(Pair) || Pair <- string:lexemes(Value, [$,])];
        _ ->
            undefined
    end.

split(Pair) ->
    case string:split(Pair, "=") of
        [Key, Value] ->
            {iolist_to_binary(Key), iolist_to_binary(Value)};
        [Key] ->
            {iolist_to_binary(Key), <<>>}
    end.

decode(TraceContext) when is_list(TraceContext) ->
    decode(list_to_binary(TraceContext));
decode(<<?VERSION, "-", TraceId:32/binary, "-", SpanId:16/binary, _/binary>>)
  when TraceId =:= ?ZERO_TRACEID orelse SpanId =:= ?ZERO_SPANID ->
    undefined;
decode(<<?VERSION, "-", TraceId:32/binary, "-", SpanId:16/binary, "-", Opts:2/binary, _/binary>>) ->
    try
        #span_ctx{trace_id=binary_to_integer(TraceId, 16),
                  span_id=binary_to_integer(SpanId, 16),
                  trace_flags=case Opts of <<"01">> -> 1; _ -> 0 end}
    catch
        %% to integer from base 16 string failed
        error:badarg ->
            undefined
    end;
decode(_) ->
    undefined.
