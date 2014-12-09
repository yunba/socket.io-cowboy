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

-record(http_state, {action, config, sid, heartbeat_tref, messages, pid, version}).

init({_, http}, Req, [Config]) ->
    {PathInfo, _} = cowboy_req:path_info(Req),
    case PathInfo of
        [<<"1">>] ->
            {ok, Req, #http_state{action = create_session, config = Config, version = 0}};
        [<<"1">>, <<"xhr-polling">>, Sid] ->
            handle_polling(Req, Sid, Config, 0);
        [<<"1">>, <<"websocket">>, _Sid] ->
            {upgrade, protocol, cowboy_websocket};
        _ ->
            {Sid, _} = cowboy_req:qs_val(<<"sid">>, Req),
            {Transport, _} = cowboy_req:qs_val(<<"transport">>, Req),

            case {Transport, Sid} of
                {<<"polling">>, undefined} ->
                    {ok, Req, #http_state{action = create_session, config = Config, version = 1}};
                {<<"polling">>, _} when is_binary(Sid) ->
                    handle_polling(Req, Sid, Config, 1);
                {<<"websocket">>, _} ->
                    {upgrade, protocol, cowboy_websocket};
                _ ->
                    {ok, Req, #http_state{config = Config}}
            end
    end.

%% Http handlers
handle(Req, HttpState = #http_state{action = create_session, version = Version, config = #config{heartbeat_timeout = HeartbeatTimeout,
                                                                              session_timeout = SessionTimeout,
                                                                              opts = Opts,
                                                                              callback = Callback}}) ->
    Sid = uuids:new(),
    PeerAddress = cowboy_req:peer(Req),

    _Pid = socketio_session:create(Sid, SessionTimeout, Callback, Opts, PeerAddress),

    case Version of
        0 ->
            HeartbeatTimeoutBin = list_to_binary(integer_to_list(HeartbeatTimeout div 1000)),
            SessionTimeoutBin = list_to_binary(integer_to_list(SessionTimeout div 1000)),

            Result = <<":", HeartbeatTimeoutBin/binary, ":", SessionTimeoutBin/binary, ":websocket,xhr-polling">>,
            Result2 = <<Sid/binary, Result/binary>>,

            HttpHeaders = text_headers();
        1 ->
            HeartbeatTimeoutBin = list_to_binary(integer_to_list(HeartbeatTimeout)),
            SessionTimeoutBin = list_to_binary(integer_to_list(SessionTimeout)),

            Result = jsx:encode([{<<"sid">>, Sid}, {<<"pingInterval">>, HeartbeatTimeoutBin}, {<<"pingTimeout">>, SessionTimeoutBin}, {<<"upgrades">>, [<<"websocket">>]}]),
            ResultLen = [ list_to_integer([D]) || D <- integer_to_list(byte_size(Result) + 1) ],
            ResultLenBin = list_to_binary(ResultLen),
            Result2 = <<0, ResultLenBin/binary, 255, "0", Result/binary>>,

            HttpHeaders = stream_headers()
    end,

    {ok, Req1} = cowboy_req:reply(200, HttpHeaders, <<Result2/binary>>, Req),
    {ok, Req1, HttpState};

handle(Req, HttpState = #http_state{action = data, messages = Messages, config = Config}) ->
    {ok, Req1} = reply_messages(Req, Messages, Config, false),
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
    [{<<"content-Type">>, <<"text/plain; charset=utf-8">>},
     {<<"Cache-Control">>, <<"no-cache">>},
     {<<"Expires">>, <<"Sat, 25 Dec 1999 00:00:00 GMT">>},
     {<<"Pragma">>, <<"no-cache">>},
     {<<"Access-Control-Allow-Credentials">>, <<"true">>},
     {<<"Access-Control-Allow-Origin">>, <<"http://localhost">>}].

stream_headers() ->
    [
        {<<"content-Type">>, <<"application/octet-stream">>},
        {<<"Cache-Control">>, <<"no-cache">>},
        {<<"Expires">>, <<"Sat, 25 Dec 1999 00:00:00 GMT">>},
        {<<"Pragma">>, <<"no-cache">>},
        {<<"Access-Control-Allow-Credentials">>, <<"true">>},
        {<<"Access-Control-Allow-Origin">>, <<"http://localhost">>}
    ].

reply_messages(Req, Messages, _Config = #config{protocol = Protocol}, SendNop) ->
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

safe_poll(Req, HttpState = #http_state{config = Config = #config{protocol = Protocol}}, Pid, WaitIfEmpty) ->
    try
        Messages = socketio_session:poll(Pid),
        case {WaitIfEmpty, Messages} of
            {true, []} ->
                {loop, Req, HttpState};
            _ ->
                {ok, Req1} = reply_messages(Req, Messages, Config, true),
                {ok, Req1, HttpState}
        end
    catch
        exit:{noproc, _} ->
            {ok, RD} = cowboy_req:reply(200, text_headers(), Protocol:encode(disconnect), Req),
            {ok, RD, HttpState#http_state{action = disconnect}}
    end.

handle_polling(Req, Sid, Config, Version) ->
    {Method, _} = cowboy_req:method(Req),
    case {socketio_session:find(Sid), Method} of
        {{ok, Pid}, <<"GET">>} ->
            case socketio_session:pull_no_wait(Pid, self()) of
                session_in_use ->
                    {ok, Req, #http_state{action = session_in_use, config = Config, sid = Sid, version = Version}};
                [] ->
                    TRef = erlang:start_timer(Config#config.heartbeat, self(), {?MODULE, Pid}),
                    {loop, Req, #http_state{action = heartbeat, config = Config, sid = Sid, heartbeat_tref = TRef, pid = Pid, version = Version}, infinity};
                Messages ->
                    {ok, Req, #http_state{action = data, messages = Messages, config = Config, sid = Sid, pid = Pid, version = Version}}
            end;
        {{ok, Pid}, <<"POST">>} ->
            Protocol = Config#config.protocol,
            case cowboy_req:body(Req) of
                {ok, Body, Req1} ->
                    Messages = Protocol:decode(Body),
                    socketio_session:recv(Pid, Messages),
                    {ok, Req1, #http_state{action = ok, config = Config, sid = Sid, version = Version}};
                {error, _} ->
                    {shutdown, Req, #http_state{action = error, config = Config, sid = Sid, version = Version}}
            end;
        {{error, not_found}, _} ->
            {ok, Req, #http_state{action = not_found, sid = Sid, config = Config, version = Version}};
        _ ->
            {ok, Req, #http_state{action = error, sid = Sid, config = Config, version = Version}}
    end.

%% Websocket handlers
websocket_init(_TransportName, Req, [Config]) ->
    {PathInfo, _} = cowboy_req:path_info(Req),
    case PathInfo of
        [<<"1">>, <<"websocket">>, Sid] ->
            case socketio_session:find(Sid) of
                {ok, Pid} ->
                    erlang:monitor(process, Pid),
                    self() ! go,
                    erlang:start_timer(Config#config.heartbeat, self(), {?MODULE, Pid}),
                    {ok, Req, {Config, Pid}};
                {error, not_found} ->
                    {shutdown, {Config, undefined}}
            end;
        _ ->
            case cowboy_req:qs_val(<<"sid">>, Req) of
                {Sid, _} when is_binary(Sid) ->
                    case socketio_session:find(Sid) of
                        {ok, Pid} ->
                            erlang:monitor(process, Pid),
                            self() ! go,
                            {ok, Req, {Config, Pid}};
                        {error, not_found} ->
                            {shutdown, {Config, undefined}}
                    end;
                _ ->
                    {shutdown, {Config, undefined}}
            end
    end.

websocket_handle({text, Data}, Req, {Config = #config{protocol = Protocol}, Pid}) ->
    Messages = Protocol:decode(Data),
    socketio_session:recv(Pid, Messages),
    {ok, Req, {Config, Pid}};
websocket_handle(_Data, Req, State) ->
    {ok, Req, State}.

websocket_info(go, Req, {Config, Pid}) ->
    case socketio_session:pull(Pid, self()) of
        session_in_use ->
            {ok, Req, {Config, Pid}};
        Messages ->
            reply_ws_messages(Req, Messages, {Config, Pid})
    end;
websocket_info({message_arrived, Pid}, Req, {Config, Pid}) ->
    Messages =  socketio_session:poll(Pid),
    self() ! go,
    reply_ws_messages(Req, Messages, {Config, Pid});
websocket_info({timeout, _TRef, {?MODULE, Pid}}, Req, {Config = #config{protocol = Protocol}, Pid}) ->
    socketio_session:refresh(Pid),
    erlang:start_timer(Config#config.heartbeat, self(), {?MODULE, Pid}),
    Packet = Protocol:encode(heartbeat),
    {reply, {text, Packet}, Req, {Config, Pid}};
websocket_info({'DOWN', _Ref, process, Pid, _Reason}, Req, State = {_Config, Pid}) ->
    {shutdown, Req, State};
websocket_info(_Info, Req, State) ->
    {ok, Req, State}.

websocket_terminate(_Reason, _Req, _State = {_Config, Pid}) ->
    socketio_session:disconnect(Pid),
    ok.

reply_ws_messages(Req, Messages, State = {_Config = #config{protocol = Protocol}, _Pid}) ->
    case Protocol:encode(Messages) of
        <<>> ->
            {ok, Req, State};
        Packet ->
            {reply, {text, Packet}, Req, State}
    end.
