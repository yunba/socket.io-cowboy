%% @author Kirill Trofimov <sinnus@gmail.com>
%% @copyright 2012 Kirill Trofimov
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%    http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
-module(socketio_handler).
-author('Kirill Trofimov <sinnus@gmail.com>').
-include("socketio_internal.hrl").

-export([init/3, handle/2, info/3, terminate/3,
         websocket_init/3, websocket_handle/3,
         websocket_info/3, websocket_terminate/3]).

-record(http_state, {action, config, sid, heartbeat_tref, messages, pid, version, jsonp}).
-record(websocket_state, {config, pid, messages, version}).

init({_, http}, Req, [Config]) ->
    Req2 = enable_cors(Req),
    {PathInfo, _} = cowboy_req:path_info(Req2),
    case PathInfo of
        [<<"1">>] ->
            {ok, Req2, #http_state{action = create_session, config = Config, version = 0}};
        [<<"1">>, <<"xhr-polling">>, Sid] ->
            handle_polling(Req2, Sid, Config, 0, undefined);
        [<<"1">>, <<"websocket">>, _Sid] ->
            {upgrade, protocol, cowboy_websocket};
        _ ->
            {Sid, _} = cowboy_req:qs_val(<<"sid">>, Req2),
            {Transport, _} = cowboy_req:qs_val(<<"transport">>, Req2),
            {JsonP, _} = cowboy_req:qs_val(<<"j">>, Req2),

            case {Transport, Sid} of
                {<<"polling">>, undefined} ->
                    {ok, Req2, #http_state{action = create_session, config = Config, version = 1, jsonp = JsonP}};
                {<<"polling">>, _} when is_binary(Sid) ->
                    handle_polling(Req2, Sid, Config, 1, JsonP);
                {<<"websocket">>, _} ->
                    {upgrade, protocol, cowboy_websocket};
                _ ->
                    {ok, Req2, #http_state{config = Config}}
            end
    end.

%% Http handlers
handle(Req, HttpState = #http_state{action = create_session, version = Version, jsonp = JsonP, config = #config{
    heartbeat = HeartbeatInterval,
    heartbeat_timeout = HeartbeatTimeout,
    session_timeout = SessionTimeout,
    opts = Opts,
    callback = Callback
}}) ->
    <<SidInt:64/integer>> = snowflake:new(socketio),
    Sid = integer_to_binary(SidInt),
    PeerAddress = cowboy_req:peer(Req),

    _Pid = socketio_session:create(Sid, SessionTimeout, Callback, Opts, PeerAddress),

    case Version of
        0 ->
            HeartbeatTimeoutBin = list_to_binary(integer_to_list(HeartbeatTimeout div 1000)),
            SessionTimeoutBin = list_to_binary(integer_to_list(SessionTimeout div 1000)),

            Result = <<":", HeartbeatTimeoutBin/binary, ":", SessionTimeoutBin/binary, ":websocket,xhr-polling">>,
            Result2 = <<Sid/binary, Result/binary>>,

            {ok, Req1} = cowboy_req:reply(200, text_headers(), <<Result2/binary>>, Req);
        1 ->
            Result = jiffy:encode({[
                {<<"sid">>, Sid},
                {<<"pingInterval">>, HeartbeatInterval}, {<<"pingTimeout">>, HeartbeatTimeout},
                {<<"upgrades">>, [<<"websocket">>]}
            ]}),

            case JsonP of
                undefined ->
                    {Result2, HttpHeaders} =
                        case cowboy_req:header(<<"user-agent">>, Req) of
                            {<<"node-XMLHttpRequest">>, _} ->
                                %% nodejs client
                                ResultLen = byte_size(Result) + 1,
                                ResultLenBin = integer_to_binary(ResultLen),
                                {<<ResultLenBin/binary, ":0", Result/binary>>, text_headers()};
                            _ ->
                                ResultLen = [list_to_integer([D]) || D <- integer_to_list(byte_size(Result) + 1)],
                                ResultLenBin = list_to_binary(ResultLen),
                                {<<0, ResultLenBin/binary, 255, "0", Result/binary>>, stream_headers()}
                        end;
                Num ->
                    ResultLenBin = integer_to_binary(byte_size(Result) + 1),
                    Rs = binary:replace(Result, <<"\"">>, <<"\\\"">>, [global]),
                    Result2 = <<"___eio[", Num/binary, "](\"", ResultLenBin/binary, ":0", Rs/binary, "\");">>,
                    HttpHeaders = javascript_headers()
            end,

            {ok, Req1} = cowboy_req:reply(200, HttpHeaders, <<Result2/binary>>, Req)
    end,
    {ok, Req1, HttpState};

handle(Req, HttpState = #http_state{action = data, messages = Messages, config = Config, version = Version, jsonp = JsonP}) ->
    {ok, Req1} = reply_messages(Req, Messages, Config, false, Version, JsonP),
    {ok, Req1, HttpState};

handle(Req, HttpState = #http_state{action = not_found}) ->
    {ok, Req1} = cowboy_req:reply(404, [], <<>>, Req),
    {ok, Req1, HttpState};

handle(Req, HttpState = #http_state{action = send}) ->
    {ok, Req1} = cowboy_req:reply(200, [], <<>>, Req),
    {ok, Req1, HttpState};

handle(Req, HttpState = #http_state{action = session_in_use}) ->
    {ok, Req1} = cowboy_req:reply(404, [], <<>>, Req),
    {ok, Req1, HttpState};

handle(Req, HttpState = #http_state{action = ok, version = 1}) ->
    {ok, Req1} = cowboy_req:reply(200, text_headers(), <<"ok">>, Req),
    {ok, Req1, HttpState};
handle(Req, HttpState = #http_state{action = ok}) ->
    {ok, Req1} = cowboy_req:reply(200, text_headers(), <<>>, Req),
    {ok, Req1, HttpState};

handle(Req, HttpState) ->
    {ok, Req1} = cowboy_req:reply(404, [], <<>>, Req),
    {ok, Req1, HttpState}.

info({timeout, TRef, {?MODULE, Pid}}, Req, HttpState = #http_state{action = heartbeat, heartbeat_tref = TRef}) ->
    safe_poll(Req, HttpState#http_state{heartbeat_tref = undefined}, Pid, false);

info({message_arrived, Pid}, Req, HttpState = #http_state{action = heartbeat}) ->
    safe_poll(Req, HttpState, Pid, true);

info(_Info, Req, HttpState) ->
    {ok, Req, HttpState}.

terminate(_Reason, _Req, _HttpState = #http_state{action = create_session}) ->
    ok;

terminate(_Reason, _Req, _HttpState = #http_state{action = session_in_use}) ->
    ok;

terminate(_Reason, _Req, _HttpState = #http_state{heartbeat_tref = HeartbeatTRef, pid = Pid}) ->
    safe_unsub_caller(Pid, self()),
    case HeartbeatTRef of
        undefined ->
            ok;
        _ ->
            erlang:cancel_timer(HeartbeatTRef)
    end.

text_headers() ->
    [
        {<<"Content-Type">>, <<"text/plain; charset=utf-8">>}
    ].

stream_headers() ->
    [
        {<<"Content-Type">>, <<"application/octet-stream">>}
    ].

javascript_headers() ->
    [
        {<<"Content-Type">>, <<"text/javascript; charset=UTF-8">>},
        {<<"X-XSS-Protection">>, <<"0">>}
    ].

reply_messages(Req, Messages, _Config = #config{protocol = Protocol}, SendNop, 1, undefined) ->
    PacketList = case {SendNop, Messages} of
                 {true, []} ->
                     Protocol:encode_v1([nop]);
                 _ ->
                     Protocol:encode_v1(Messages)
             end,
    {PacketListBin, HttpHeaders} =
        case cowboy_req:header(<<"user-agent">>, Req) of
            {<<"node-XMLHttpRequest">>, _} ->
                %% nodejs client
                {encode_polling_packets_v1(PacketList), text_headers()};
            _ ->
                {encode_polling_xhr_packets_v1(PacketList), stream_headers()}
        end,

    cowboy_req:reply(200, HttpHeaders, PacketListBin, Req);
reply_messages(Req, Messages, _Config = #config{protocol = Protocol}, SendNop, 1, JsonP) ->
    PacketList = case {SendNop, Messages} of
                     {true, []} ->
                         Protocol:encode_v1([nop]);
                     _ ->
                         Protocol:encode_v1(Messages)
                 end,
    PacketListBin = encode_polling_json_packets_v1(PacketList, JsonP),

    cowboy_req:reply(200, javascript_headers(), PacketListBin, Req);
reply_messages(Req, Messages, _Config = #config{protocol = Protocol}, SendNop, 0, _JsonP) ->
    Packet = case {SendNop, Messages} of
                 {true, []} ->
                     Protocol:encode([nop]);
                 _ ->
                     Protocol:encode(Messages)
             end,
    cowboy_req:reply(200, text_headers(), Packet, Req).

safe_unsub_caller(undefined, _Caller) ->
    ok;

safe_unsub_caller(_Pid, undefined) ->
    ok;

safe_unsub_caller(Pid, Caller) ->
    try
        socketio_session:unsub_caller(Pid, Caller),
        ok
    catch
        exit:{noproc, _} ->
            error
    end.

safe_poll(Req, HttpState = #http_state{config = Config, version = Version, jsonp = JsonP}, Pid, WaitIfEmpty) ->
    try
        Messages = socketio_session:poll(Pid),
        case {WaitIfEmpty, Messages} of
            {true, []} when Version =:= 1 ->
                case socketio_session:transport(Pid) of
                    noproc ->
                        {ok, Req1} = cowboy_req:reply(404, [], <<>>, Req),
                        {ok, Req1, HttpState#http_state{action = disconnect}};
                    websocket ->
                        {ok, Req1} = reply_messages(Req, [], Config, true, Version, JsonP),
                        {ok, Req1, HttpState};
                    _ ->
                        {loop, Req, HttpState, hibernate}
                end;
            {true, []} ->
                {loop, Req, HttpState, hibernate};
            _ ->
                {ok, Req1} = reply_messages(Req, Messages, Config, true, Version, JsonP),
                {ok, Req1, HttpState}
        end
    catch
        exit:{noproc, _} ->
            {ok, RD} = cowboy_req:reply(404, [], <<>>, Req),
            {ok, RD, HttpState#http_state{action = disconnect}}
    end.

handle_polling(Req, Sid, Config, Version, JsonP) ->
    {Method, _} = cowboy_req:method(Req),
    case {socketio_session:find(Sid, Config#config.opts#config_opts.session_read_storage), Method} of
        {{ok, Pid}, <<"GET">>} ->
            case socketio_session:pull_no_wait(Pid, self()) of
                {error, noproc} ->
                    {shutdown, Req, #http_state{action = error, config = Config, sid = Sid, version = Version, jsonp = JsonP}};
                session_in_use ->
                    {shutdown, Req, #http_state{action = error, config = Config, sid = Sid, version = Version, jsonp = JsonP}};
                [] when Version =:= 1 ->
                    case socketio_session:transport(Pid) of
                        noproc ->
                            {shutdown, Req, #http_state{action = error, config = Config, sid = Sid, version = Version, jsonp = JsonP}};
                        websocket ->
                            {ok, Req, #http_state{action = data, messages = [nop], config = Config, sid = Sid, pid = Pid, version = Version, jsonp = JsonP}};
                        _ ->
                            {loop, Req, #http_state{action = heartbeat, config = Config, sid = Sid, pid = Pid, version = Version, jsonp = JsonP}, hibernate}
                    end;
                [] when Version =:= 0 ->
                    HeartBeatTimer = erlang:send_after(Config#config.heartbeat, self(), {?MODULE, Pid}),
                    {loop, Req, #http_state{action = heartbeat, heartbeat_tref = HeartBeatTimer, config = Config, sid = Sid, pid = Pid, version = Version, jsonp = JsonP}, hibernate};
                Messages ->
                    {ok, Req, #http_state{action = data, messages = Messages, config = Config, sid = Sid, pid = Pid, version = Version, jsonp = JsonP}}
            end;
        {{ok, Pid}, <<"POST">>} ->
            case get_request_data(Req, JsonP) of
                {ok, Data2, Req2} ->
                    Protocol = Config#config.protocol,
                    DecodeMethod = case Version of
                                0 -> decode;
                                1 -> decode_v1
                            end,

                    Messages = case catch(Protocol:DecodeMethod(Data2)) of
                                   {'EXIT', _Reason} ->
                                       [];
                                   {error, _Reason} ->
                                       [];
                                   Msgs ->
                                       Msgs
                               end,
                    case socketio_session:recv(Pid, Messages) of
                        noproc ->
                            {shutdown, Req2, #http_state{action = error, config = Config, sid = Sid, version = Version, jsonp = JsonP}};
                        _ ->
                            {ok, Req2, #http_state{action = ok, config = Config, sid = Sid, version = Version, jsonp = JsonP}}
                    end;
                error ->
                    {shutdown, Req, #http_state{action = error, config = Config, sid = Sid, version = Version}}
            end;
        {{error, not_found}, _} ->
            {ok, Req, #http_state{action = not_found, sid = Sid, config = Config, version = Version, jsonp = JsonP}};
        _ ->
            {ok, Req, #http_state{action = error, sid = Sid, config = Config, version = Version, jsonp = JsonP}}
    end.

%% Websocket handlers
websocket_init(_TransportName, Req, [Config]) ->
    {PathInfo, _} = cowboy_req:path_info(Req),
    case PathInfo of
        [<<"1">>, <<"websocket">>, Sid] ->
            case socketio_session:find(Sid, Config#config.opts#config_opts.session_read_storage) of
                {ok, Pid} ->
                    erlang:monitor(process, Pid),
                    self() ! go,
                    erlang:start_timer(Config#config.heartbeat, self(), {?MODULE, Pid}),
                    {ok, Req, #websocket_state{config = Config, pid = Pid, messages = [], version = 0}, hibernate};
                {error, not_found} ->
                    {shutdown, Req}
            end;
        _ ->
            case cowboy_req:qs_val(<<"sid">>, Req) of
                {Sid, _} when is_binary(Sid) ->
                    case socketio_session:find(Sid, Config#config.opts#config_opts.session_read_storage) of
                        {ok, Pid} ->
                            erlang:monitor(process, Pid),
                            socketio_session:upgrade_transport(Pid, websocket),
                            {ok, Req, #websocket_state{config = Config, pid = Pid, messages = [], version = 1}, hibernate};
                        {error, not_found} ->
                            {shutdown, Req}
                    end;
                _ ->
                    {shutdown, Req}
            end
    end.

websocket_handle({text, Data}, Req, State = #websocket_state{
    config = #config{protocol = Protocol}, pid = Pid, version = Version
}) ->
    DecodeMethod = case Version of
                       0 -> decode;
                       1 -> decode_v1_for_websocket
                   end,
    case catch (Protocol:DecodeMethod(Data)) of
        {'EXIT', _Reason} ->
            {ok, Req, State, hibernate};
        [{ping, Rest}] ->               %% only for socketio v1
            Packet = Protocol:encode_v1({pong, Rest}),
            socketio_session:refresh(Pid),
            {reply, {text, Packet}, Req, State, hibernate};
        [upgrade] ->                    %% only for socketio v1
            self() ! go,
            {ok, Req, State, hibernate};
        Msgs ->
            case socketio_session:recv(Pid, Msgs) of
                noproc ->
                    {shutdown, Req, State};
                _ ->
                    {ok, Req, State, hibernate}
            end
    end;
websocket_handle(_Data, Req, State) ->
    {ok, Req, State, hibernate}.

websocket_info(go, Req, State = #websocket_state{pid = Pid, messages = RestMessages}) ->
    case socketio_session:pull(Pid, self()) of
        {error, noproc} ->
            {shutdown, Req, State};
        session_in_use ->
            {ok, Req, State, hibernate};
        Messages ->
            RestMessages2 = lists:append([RestMessages, Messages]),
            self() ! go_rest,
            {ok, Req, State#websocket_state{messages = RestMessages2}, hibernate}
    end;
websocket_info(go_rest, Req, State = #websocket_state{
    config = #config{protocol = Protocol}, messages = RestMessages, version = Version
}) ->
    case RestMessages of
        [] ->
            {ok, Req, State, hibernate};
        [Message | Rest] ->
            self() ! go_rest,

            Packet = case Version of
                         0 ->
                             Protocol:encode(Message);
                         1 ->
                             [Pkg] = Protocol:encode_v1([Message]),
                             Pkg
                     end,
            {reply, {text, Packet}, Req, State#websocket_state{messages = Rest}, hibernate}
    end;
websocket_info({message_arrived, Pid}, Req, State = #websocket_state{
    pid = Pid, messages = RestMessages
}) ->
    Messages =  case socketio_session:safe_poll(Pid) of
                    {error, noproc} ->
                        [];
                    Result ->
                        Result
                end,
    RestMessages2 = lists:append([RestMessages, Messages]),
    self() ! go,
    {ok, Req, State#websocket_state{messages = RestMessages2}, hibernate};
websocket_info({timeout, _TRef, {?MODULE, Pid}}, Req, State = #websocket_state{
    config = #config{protocol = Protocol, heartbeat = HeartBeat}, pid = Pid, version = 0
}) ->
    erlang:start_timer(HeartBeat, self(), {?MODULE, Pid}),
    Packet = Protocol:encode(heartbeat),
    {reply, {text, Packet}, Req, State, hibernate};
websocket_info({'DOWN', _Ref, process, Pid, _Reason}, Req, State = #websocket_state{pid = Pid}) ->
    {shutdown, Req, State};
websocket_info(_Info, Req, State) ->
    {ok, Req, State, hibernate}.

websocket_terminate(_Reason, _Req, #websocket_state{pid = Pid}) ->
    socketio_session:disconnect(Pid),
    ok.

enable_cors(Req) ->
    case cowboy_req:header(<<"origin">>, Req) of
        {undefined, _} ->
            Req;
        {Origin, _} ->
            Req1 = cowboy_req:set_resp_header(<<"access-control-allow-origin">>, Origin, Req),
            cowboy_req:set_resp_header(<<"access-control-allow-credentials">>, <<"true">>, Req1)
    end.

get_request_data(Req, JsonP) ->
    case JsonP of
        undefined ->
            case cowboy_req:body(Req) of
                {ok, Body, Req1} ->
                    {ok, Body, Req1};
                {error, _} ->
                    error
            end;
        _Num ->
            case cowboy_req:body_qs(Req) of
                {ok, PostVals, Req1} ->
                    Data = proplists:get_value(<<"d">>, PostVals),
                    Data2 = binary:replace(Data, <<"\\\n">>, <<"\n">>, [global]),
                    Data3 = binary:replace(Data2, <<"\\\\n">>, <<"\\n">>, [global]),
                    {ok, Data3, Req1};
                {error, _} ->
                    error
            end
    end.

encode_polling_packets_v1(PacketList) ->
    lists:foldl(fun(Packet, AccIn) ->
        PacketLen = byte_size(Packet),
        ResultLenBin = integer_to_binary(PacketLen),
        <<AccIn/binary, ResultLenBin/binary, ":", Packet/binary>>
                end, <<>>, PacketList).

encode_polling_xhr_packets_v1(PacketList) ->
    lists:foldl(fun(Packet, AccIn) ->
        PacketLen = [list_to_integer([D]) || D <- integer_to_list(byte_size(Packet))],
        PacketLenBin = list_to_binary(PacketLen),
        <<AccIn/binary, 0, PacketLenBin/binary, 255, Packet/binary>>
    end, <<>>, PacketList).

encode_polling_json_packets_v1(PacketList, JsonP) ->
    Payload = lists:foldl(fun(Packet, AccIn) ->
        ResultLenBin = integer_to_binary(byte_size(Packet)),
        Packet2 = escape_character(Packet, <<"\\">>),
        Packet3 = escape_character(Packet2, <<"\"">>),
        Packet4 = escape_character(Packet3, <<"\\n">>),
        <<AccIn/binary, ResultLenBin/binary, ":", Packet4/binary>>
    end, <<>>, PacketList),
    <<"___eio[", JsonP/binary, "](\"", Payload/binary, "\");">>.

escape_character(Data, CharBin) ->
    binary:replace(Data, CharBin, <<"\\", CharBin/binary>>, [global]).
