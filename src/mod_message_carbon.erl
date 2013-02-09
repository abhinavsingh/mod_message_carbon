%%% -------------------------------------------------------------------
%%% Author      : Abhinav Singh <mailsforabhinav@gmail.com>
%%% Created     : Sep 26, 2012 by Abhinav Singh <mailsforabhinav@gmail.com>
%%% Description : XEP-0280 Message Carbon Ejabberd Module
%%% -------------------------------------------------------------------

-module(mod_message_carbon).
-author('mailsforabhinav@gmail.com').

-behaviour(gen_mod).

-include("ejabberd.hrl").
-include("jlib.hrl").

-type host()	:: string().
-type name()	:: string().
-type value()	:: string().
-type opts()	:: [{name(), value()}, ...].

-define(NS_CARBON, "urn:xmpp:carbons:2").
-define(NS_FORWARD, "urn:xmpp:forward:0").

-record(carbon, 
{
	jid,
	res
}).

%% ====================================================================
%% API functions
%% ====================================================================
-export([start/2, stop/1]).
-export([process_carbon_iq/3, filter_packet/1, on_unavailable/4]).

-spec start(host(), opts()) -> ok.
start(Host, Opts) ->
	IQDisc = gen_mod:get_opt(iqdisc, Opts, one_queue),
	mod_disco:register_feature(Host, ?NS_CARBON),
	mnesia:create_table(carbon, [{attributes, record_info(fields, carbon)}, {type, bag}, {disc_copies, [node()]}]),
	mnesia:clear_table(carbon),
	gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_CARBON, ?MODULE, process_carbon_iq, IQDisc),
	ejabberd_hooks:add(filter_packet, global, ?MODULE, filter_packet, 10),
	ejabberd_hooks:add(unset_presence_hook, Host, ?MODULE, on_unavailable, 10),
	ok.

-spec stop(host()) -> ok.
stop(Host) ->
	gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_CARBON),
	ejabberd_hooks:delete(filter_packet, global, ?MODULE, filter_packet, 10),
	ejabberd_hooks:delete(unset_presence_hook, Host, ?MODULE, on_unavailable, 10),
	ok.

%% ====================================================================
%% Internal functions
%% ====================================================================

on_unavailable(User, Server, Resource, _Priority) ->
	ok = mnesia:dirty_delete_object(#carbon{jid = {User, Server}, res = Resource}),
	none.

process_carbon_iq(From, _To, #iq{type = set, sub_el = {xmlelement, "enable", _, _}} = IQ) ->
	ok = mnesia:dirty_write(#carbon{jid = {From#jid.luser, From#jid.lserver}, res = From#jid.lresource}),
	IQ#iq{type = result, sub_el = []};
process_carbon_iq(From, _To, #iq{type = set, sub_el = {xmlelement, "disable", _, _}} = IQ) ->
	ok = mnesia:dirty_delete_object(#carbon{jid = {From#jid.luser, From#jid.lserver}, res = From#jid.lresource}),
	IQ#iq{type = result, sub_el = []}.

filter_packet({From, To, {xmlelement, "message", _, _} = Pkt}) ->
	case xml:get_tag_attr_s("type", Pkt) of
		"chat" ->
			%% Receiver case where all resources of To user must receive incoming chat message
			if
				%% Carbon only when To is a full jid and not bare jid
				To#jid.resource =/= [] ->
					carbon(To, Pkt, "received");
				true ->
					ok
			end,
			
			%% Sender case where all resources of From user must receive it's own chat message
			carbon(From, Pkt, "sent"),
			{From, To, Pkt};
		_ ->
			{From, To, Pkt}
	end;
filter_packet({From, To, Pkt}) ->
	{From, To, Pkt}.

carbon(Jid, Pkt, Tag) ->
	lists:foreach(
	  fun(#carbon{res=Res}) ->
		Bare = Jid#jid{resource=[], lresource=[]},
		Full = Jid#jid{resource=Res, lresource=Res},
		if
			Res =/= Jid#jid.lresource ->
				Pid = ejabberd_sm:get_session_pid(Jid#jid.luser, Jid#jid.lserver, Res),
				Fwd = {xmlelement, "forwarded", [{"xmlns", ?NS_FORWARD}], [Pkt]},
				Cbn = {xmlelement, Tag, [{"xmlns", ?NS_CARBON}], [Fwd]},
				Childs = [Cbn],
				Attrs = [{"from", jlib:jid_to_string(Bare)}, {"to", jlib:jid_to_string(Full)}, {"type", "chat"}],
				Pkt1 = {xmlelement, "message", Attrs, Childs},
				Pid ! {route, Bare, Full, Pkt1};
			true ->
				ok
		end
	  end,
	  mnesia:dirty_read({carbon, {Jid#jid.luser, Jid#jid.lserver}})
	).
