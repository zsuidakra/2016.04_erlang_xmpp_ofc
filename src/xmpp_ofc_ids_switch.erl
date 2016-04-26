%%%-------------------------------------------------------------------
%%% @author  <Arkadiusz Gil>
%%% @copyright (C) 2016, 
%%% @doc
%%%
%%% @end
%%% Created : 25 Apr 2016 by  <Arkadiusz Gil>
%%%-------------------------------------------------------------------
-module(xmpp_ofc_ids_switch).

-behaviour(gen_server).

%% API exports

-export([start_link/1,
	 stop/1,
	 handle_message/3, ip_to_list/1]).

%% gen_server callbacks exports

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

%% Includes, type definitions and macros

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v4.hrl").
-include("xmpp_ofc_v4.hrl").

-record(state, {datapath_id :: binary()}).

-define(SERVER, ?MODULE).
-define(OF_VER, 4).
-define(ENTRY_TIMEOUT, 30 * 1000).
-define(FM_TIMEOUT_S(Type), case Type of
                                idle ->
                                    10;
                                hard ->
                                    30
                            end).
-define(FM_INIT_COOKIE, <<0,0,0,0,0,0,0,150>>).

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link(binary()) -> {ok, pid()} | ignore | {error, term()}.
start_link(DatapathId) ->
    {ok, Pid} = gen_server:start_link(?MODULE, [DatapathId], []),
    {ok, Pid, subscriptions(), [init_flow_mod()]}.

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:stop(Pid).

-spec handle_message(pid(),
                     {MsgType :: term(),
                      Xid :: term(),
                      MsgBody :: [tuple()]},
                     [ofp_message()]) -> [ofp_message()].
handle_message(Pid, Msg, OFMessages) ->
    gen_server:call(Pid, {handle_message, Msg, OFMessages}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([DatapathId]) ->
    {ok, #state{datapath_id = DatapathId}}.

handle_call({handle_message, {packet_in, _, MsgBody} = Msg, CurrOFMessages},
	    _From, #state{datapath_id = Dpid} = State) ->
    case packet_in_extract([reason, cookie], MsgBody) of
	[action, ?FM_INIT_COOKIE] ->
	    {OFMessages} = handle_packet_in(Msg, Dpid),
	    {reply, OFMessages ++ CurrOFMessages, State};
	_  ->
	    {reply, CurrOFMessages, State}
    end.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Request, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

subscriptions() ->
    [packet_in].

init_flow_mod() ->
    Matches = [{eth_type, 16#0800}, {ip_proto, <<6>>}, {tcp_dst, <<5222:16>>}],
    Instructions = [{apply_actions, [{output, controller, no_buffer}]}],
    FlowOpts = [{table_id, 0}, {priority, 150},
	        {idle_timeout, 0},
	        {hard_timeout, 0},
	        {cookie, ?FM_INIT_COOKIE},
	        {cookie_mask, <<0,0,0,0,0,0,0,0>>}],
    of_msg_lib:flow_add(?OF_VER, Matches, Instructions, FlowOpts).

handle_packet_in({_, Xid, PacketIn}, _Dpid) ->
    [IpSrc, TcpSrc] = packet_in_extract([ip_src, tcp_src], PacketIn),
    Matches = [{eth_type, 16#0800},
	       {ipv4_src, IpSrc},
	       {ip_proto, <<6>>},
	       {tcp_src, TcpSrc},
	       {tcp_dst, <<5222:16>>}],
    lager:info("Installing flow mod for: ~p", [pretty_ip_tcp(IpSrc, TcpSrc)]),
    Instructions = [{apply_actions, [{output, 1, no_buffer}]}],
    FlowOpts = [{table_id, 0}, {priority, 200},
	        {idle_timeout, ?FM_TIMEOUT_S(idle)},
	        {hard_timeout, ?FM_TIMEOUT_S(hard)},
	        {cookie, <<0,0,0,0,0,0,0,200>>},
	        {cookie_mask, <<0,0,0,0,0,0,0,0>>}],
    FM = of_msg_lib:flow_add(?OF_VER, Matches, Instructions, FlowOpts),
    PO = packet_out(Xid, PacketIn, 1),
    {[FM, PO]}.

packet_out(Xid, PacketIn, OutPort) ->
    Actions = [{output, OutPort, no_buffer}],
    {InPort, BIdOrPacketPortion} = 
	case packet_in_extract(buffer_id, PacketIn) of
	    no_buffer ->
		list_to_tuple(packet_in_extract([in_port, data], PacketIn));
	    BufferId when is_integer(BufferId) ->
		{packet_in_extract(in_port, PacketIn), BufferId}
	end, 
    PacketOut = of_msg_lib:send_packet(?OF_VER, BIdOrPacketPortion, InPort, Actions),
    PacketOut#ofp_message{xid = Xid}.

packet_in_extract(Elements, PacketIn) when is_list(Elements) ->
    [packet_in_extract(H, PacketIn) || H <- Elements];
packet_in_extract(src_mac, PacketIn) ->
    <<_:6/bytes, SrcMac:6/bytes, _/binary>> = proplists:get_value(data, PacketIn),
    SrcMac;
packet_in_extract(dst_mac, PacketIn) ->
    <<DstMac:6/bytes, _/binary>> = proplists:get_value(data, PacketIn),
    DstMac;
packet_in_extract(in_port, PacketIn) ->
    <<InPort:32>> = proplists:get_value(in_port, proplists:get_value(match, PacketIn)),
    InPort;
packet_in_extract(buffer_id, PacketIn) ->
    proplists:get_value(buffer_id, PacketIn);
packet_in_extract(data, PacketIn) ->
    proplists:get_value(data, PacketIn);
packet_in_extract(reason, PacketIn) ->
    proplists:get_value(reason, PacketIn);
packet_in_extract(cookie, PacketIn) ->
    proplists:get_value(cookie, PacketIn);
packet_in_extract(match, PacketIn) ->
    proplists:get_value(match, PacketIn);
packet_in_extract(ip_src, PacketIn) ->
    Data = packet_in_extract(data, PacketIn),
    <<_:26/bytes, IpSrc:4/bytes, _/binary>> = Data, % 14 bytes for Ethernet header 
    IpSrc;                                          % + 12 bytes for everything in IP header before src address
packet_in_extract(tcp_src, PacketIn) ->
    Data = packet_in_extract(data, PacketIn),
    <<_:14/bytes, _:4, HLen:4, _:19/bytes, RestDgram/binary>> = Data, % 14 bytes of ethernet header + 4 bits for ip version
    OptsLen = 4*(HLen - 5),
    <<_:OptsLen/bytes, TcpSrc:2/bytes, _/binary>> = RestDgram,
    TcpSrc.


ip_to_list(Ip) when is_binary(Ip) ->
    Result = ["." ++ integer_to_list(X, 10) || <<X:8>> <= Ip],
    tl(lists:flatten(Result)).

tcp_to_list(Tcp) when is_binary(Tcp) ->
    <<Result:16>> = Tcp,
    integer_to_list(Result).

pretty_ip_tcp(Ip, Tcp) ->
    ip_to_list(Ip) ++ ":" ++ tcp_to_list(Tcp).
