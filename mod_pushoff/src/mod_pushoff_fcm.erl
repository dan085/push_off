%%%
%%% Copyright (C) 2015  Christian Ulrich
%%% Copyright (C) 2016  Vlad Ki
%%% Copyright (C) 2017  Dima Stolpakov =)
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%

-module(mod_pushoff_fcm).

-author('christian@rechenwerk.net').
-author('proger@wilab.org.ua').
-author('dimskii123@gmail.com').

-behaviour(gen_server).
-compile(export_all).
-export([init/1,
         handle_info/2,
         handle_call/3,
         handle_cast/2,
         terminate/2,
         code_change/3]).

-include("logger.hrl").
-include("xmpp.hrl").




-define(RETRY_INTERVAL, 30000).

-record(state,
        {send_queue :: queue:queue(any()),
         retry_list :: [any()],
         pending_timer :: reference(),
         retry_timer :: reference(),
         pending_timestamp :: erlang:timestamp(),
         retry_timestamp :: erlang:timestamp(),
         gateway :: string(),
         api_key :: string()}).

init([Gateway, ApiKey]) ->
    ?INFO_MSG("+++++++++ mod_pushoff_fcm:init, gateway <~p>, ApiKey <~p>", [Gateway, ApiKey]),
    inets:start(),
    crypto:start(),
    ssl:start(),
    {ok, #state{send_queue = queue:new(),
                retry_list = [],
                pending_timer = make_ref(),
                retry_timer = make_ref(),
                gateway = mod_pushoff_utils:force_string(Gateway),
                api_key = "key=" ++ mod_pushoff_utils:force_string(ApiKey)}}.

handle_info({retry, StoredTimestamp},
            #state{send_queue = SendQ,
                   retry_list = RetryList,
                   pending_timer = PendingTimer,
                   retry_timestamp = StoredTimestamp} = State) ->
    case erlang:read_timer(PendingTimer) of
        false -> self() ! send;
        _ -> meh
    end,
    {noreply,
     State#state{send_queue = lists:foldl(fun(E, Q) -> queue:snoc(Q, E) end, SendQ, RetryList),
                 retry_list = []}};

handle_info({retry, _T1}, #state{retry_timestamp = _T2} = State) ->
    {noreply, State};

handle_info(send, #state{send_queue = SendQ,
                         retry_list = RetryList,
                         retry_timer = RetryTimer,
                         gateway = Gateway,
                         api_key = ApiKey} = State) ->

    NewState = 
    case mod_pushoff_utils:enqueue_some(SendQ) of
        empty ->
            State#state{send_queue = SendQ};
        {Head, NewSendQ} ->
            HTTPOptions = [],
            Options = [],
        

            {Body, DisableArgs} = pending_element_to_json(Head),
 

            Request = {Gateway, [{"Authorization", ApiKey}], "application/json", Body},

         ?INFO_MSG("Body_send!", [Request]),

            Response = httpc:request(post, Request, HTTPOptions, Options), %https://firebase.google.com/docs/cloud-messaging/http-server-ref
            case Response of
                {ok, {{_, StatusCode5xx, _}, _, ErrorBody5xx}} when StatusCode5xx >= 500, StatusCode5xx < 600 ->
                      ?INFO_MSG("recoverable FCM error: ~p, retrying...", [ErrorBody5xx]),
                      NewRetryList = pending_to_retry(Head, RetryList),
                      {NewRetryTimer, Timestamp} = restart_retry_timer(RetryTimer),
                      State#state{retry_list = NewRetryList,
                                  send_queue = NewSendQ,
                                  retry_timer = NewRetryTimer,
                                  retry_timestamp = Timestamp};
                {ok, {{_, 200, _}, _, ResponseBody}} ->
                      case parse_response(ResponseBody) of
                          ok -> 
      
                        ?INFO_MSG("non-recoverable FCM error: ~p, delete ResponseBody 200", [ResponseBody]),
                            ok;
                          _ -> mod_pushoff_mnesia:unregister_client(DisableArgs)
                      end,
                      Timestamp = erlang:timestamp(),
                      State#state{send_queue = NewSendQ,
                                  pending_timestamp = Timestamp
                                  };
    
                {ok, {{_, _, _}, _, ResponseBody}} ->
                      
                      ?INFO_MSG("non-recoverable FCM error: ~p, delete registration", [ResponseBody]),
                      NewRetryList = pending_to_retry(Head, RetryList),
                      {NewRetryTimer, Timestamp} = restart_retry_timer(RetryTimer),
                      State#state{retry_list = NewRetryList,
                                  send_queue = NewSendQ,
                                  retry_timer = NewRetryTimer,
                                  retry_timestamp = Timestamp};
    
                {error, Reason} ->
                      ?INFO_MSG("FCM request failed: ~p, retrying...", [Reason]),
                      NewRetryList = pending_to_retry(Head, RetryList),
                      {NewRetryTimer, Timestamp} = restart_retry_timer(RetryTimer),
                      State#state{retry_list = NewRetryList,
                                  send_queue = NewSendQ,
                                  retry_timer = NewRetryTimer,
                                  retry_timestamp = Timestamp}
            end
    end,
    {noreply, NewState};

handle_info(Info, State) ->
    ?DEBUG("+++++++ mod_pushoff_fcm received unexpected signal ~p", [Info]),
    {noreply, State}.

handle_call(_Req, _From, State) -> {reply, {error, badarg}, State}.

handle_cast({dispatch, UserBare, Payload, Token, DisableArgs},
            #state{send_queue = SendQ,
                   pending_timer = PendingTimer,
                   retry_timer = RetryTimer} = State) ->
    case {erlang:read_timer(PendingTimer), erlang:read_timer(RetryTimer)} of
        {false, false} -> self() ! send;
        _ -> ok
    end,
    {noreply,
     State#state{send_queue = queue:snoc(SendQ, {UserBare, Payload, Token, DisableArgs})}};

handle_cast(_Req, State) -> {reply, {error, badarg}, State}.

terminate(_Reason, #state{}) ->
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

restart_retry_timer(OldTimer) ->
    erlang:cancel_timer(OldTimer),
    Timestamp = erlang:timestamp(),
    NewTimer = erlang:send_after(?RETRY_INTERVAL, self(), {retry, Timestamp}),
    {NewTimer, Timestamp}.

-spec pending_to_retry(any(), [any()]) -> {[any()]}.

pending_to_retry(Head, RetryList) -> RetryList ++ Head.


to_string_jid(#jid{ user = User}) -> User.



get_vcard_jid([VCard]) -> VCard.


create_keyvalue([Head]) ->
  create_pair(Head);
create_keyvalue([Head|Tail]) ->
  lists:append([create_pair(Head), ",", create_keyvalue(Tail)]).
 
create_pair({Key, Value}) ->
  lists:append([add_quotes(atom_to_list(Key)), ":", add_quotes(Value)]).
add_quotes(String) ->
  lists:append(["\"", String, "\""]).

  




pending_element_to_json({_, Payload, Token, DisableArgs}) ->
   
   

      Type = proplists:get_value(type, Payload),
  
      case Type of
          normal -> ok;
          _ -> 

            Body = proplists:get_value(body, Payload),
            From = proplists:get_value(from, Payload),
            Subject = proplists:get_value(subject, Payload),
            Nicky_name = proplists:get_value(thread, Payload),

             BodyTxt = xmpp:get_text(Body),

             SubjectTxt = xmpp:get_text(Subject),
         
            JFrom = jid:encode(From),
            Username_user= to_string_jid(From), 
            User_Server_vcard = jid:nodeprep(<<"bimbask.com">>),

            IQ_Vcard = mod_vcard:get_vcard(Username_user,User_Server_vcard),
      
            IQ_Vcard_final = get_vcard_jid(IQ_Vcard),

            Nickname = fxml:get_path_s(IQ_Vcard_final, [{elem, <<"NICKNAME">>}, cdata]),

   
        ?INFO_MSG("Body_Token", [Token]),
         %%https://stackoverflow.com/questions/2397613/are-parameters-in-strings-xml-possible
            DATA = [  {title, Nickname},
                       {msg_from, JFrom}, 
                       {body, BodyTxt},
                       {subject, SubjectTxt}, 
                       {mobile_friend, JFrom}, 
                       {send_from_media_player, <<"NOTIFICATION">>}
                      ], 
    
              case SubjectTxt of
                            <<"0">> -> 
                                % Notify2= [ {body, BodyTxt}, {title, Nickname}, {click_action, <<"NOTIFICATION">>} ],
                
                                 % << <<"One">>/binary, (list_to_binary(" Two "))/binary, <<"Three">>/binary, (list_to_binary(" Four!"))/binary >>.  
                                 % <<"One Two Three Four!">> https://grantwinney.com/an-erlang-snippet-for-easily-concatenating-binaries-and-strings/
                              


                                   Notify2= [ 
                                                {body_loc_key, <<"new_message_notification_message_body">>},
                                                {body_loc_args, [Nickname , BodyTxt]}, 
                                                {title_loc_key , <<"new_message_notification">>},
                                                {click_action, <<"NOTIFICATION">>} ],
                              

                                  PushMessage = {[{to,Token},
                                    {priority,     <<"high">>},
                                    {notification,   {Notify2} },
                                    {data,         {DATA} }
                                %% If you need notification in android system tray, use:
                                %%, {notification, {BF}}
                               ]},

                   
                                 {jiffy:encode(PushMessage), DisableArgs};       

                            <<"7">> -> 
                                 

                    
                                Notify2_links= [ 
                                    {body_loc_key, <<"new_message_notification_url_body">>},
                                    {body_loc_args, [Nickname]}, 
                                    {title_loc_key , <<"new_message_notification">>},
                                    {click_action, <<"NOTIFICATION">>} ],

                                 PushMessage = {[{to,           Token},
                                {priority,     <<"high">>},
                                {notification,   {Notify2_links} },
                                %%{notification,         {[ {body_loc_key, <<"GROUPS_LINKS">>}, {title, Nickname} ]} },

                                {data,         {DATA} }
                                %% If you need notification in android system tray, use:
                                %%, {notification, {BF}}
                               ]},

                             {jiffy:encode(PushMessage), DisableArgs};    

                            <<"8">> -> 



                                    Notify2_group_links= [ 
                                {body_loc_key, <<"new_message_notification_group_body">>},
                                {body_loc_args, [Nickname]}, 
                                {title_loc_key , <<"new_message_notification">>},
                                {click_action, <<"NOTIFICATION">>} ],
                              
                               PushMessage = {[{to,           Token},
                                {priority,     <<"high">>},
                                {notification,   {Notify2_group_links} },
                                %%{notification,         {[ {body_loc_key, "GROUPS_LINKS"}, {title, Nickname} ]} },

                                {data,         {DATA} }
                                %% If you need notification in android system tray, use:
                                %%, {notification, {BF}}
                               ]},

                              {jiffy:encode(PushMessage), DisableArgs};

                            <<"9">> -> 

                                Notify2_picture= [ 
                                {body_loc_key, <<"new_message_notification_picture_body">>},
                                {body_loc_args, [Nickname]}, 
                                {title_loc_key , <<"new_message_notification">>},
                                {click_action, <<"NOTIFICATION">>} ],
                              
                               PushMessage = {[{to,           Token},
                                {priority,     <<"high">>},
                                {notification,   {Notify2_picture} },
                                %%{notification,         {[ {body, "\\ud83d\\udcf7"}, {title, Nickname} ]} },

                                {data,         {DATA} }
                                %% If you need notification in android system tray, use:
                                %%, {notification, {BF}}
                               ]},

                               {jiffy:encode({{PushMessage}}), DisableArgs};
                            
                            <<"10">> -> 
                               
                                Notify2_voice= [ 
                                {body_loc_key, <<"new_message_notification_voice_body">>},
                                {body_loc_args, [Nickname]}, 
                                {title_loc_key , <<"new_message_notification">>},
                                {click_action, <<"NOTIFICATION">>} ],


                                PushMessage = {[{to,           Token},
                                {priority,     <<"high">>},
                                %%{notification,         {[ {body_loc_key, "GROUPS_LINKS"}, {title, Nickname} ]} },
                                {notification,   {Notify2_voice} },
                                {data,         {DATA} }
                                %% If you need notification in android system tray, use:
                                %%, {notification, {BF}}
                               ]},

                              {jiffy:encode({{PushMessage}}), DisableArgs};

                            <<"11">> -> 

                                Notify2_video= [ 
                                {body_loc_key, <<"new_message_notification_video_body">>},
                                {body_loc_args, [Nickname]}, 
                                {title_loc_key , <<"new_message_notification">>},
                                {click_action, <<"NOTIFICATION">>} ],
                              
                               PushMessage = {[{to,           Token},
                                {priority,     <<"high">>},
                                %%{notification,         {[ {body_loc_key, "VIDEO_NOTIFY"}, {title, Nickname} ]} },
                                {notification,   {Notify2_video} },
                                {data,         {DATA} }
                                %% If you need notification in android system tray, use:
                                %%, {notification, {BF}}
                               ]},

                              {jiffy:encode({{PushMessage}}), DisableArgs};


                            <<"12">> -> 

                                Notify2_document= [ 
                                {body_loc_key, <<"new_message_notification_document_body">>},
                                {body_loc_args, [Nickname]}, 
                                {title_loc_key , <<"new_message_notification">>},
                                {click_action, <<"NOTIFICATION">>} ],

                                PushMessage = {[{to,           Token},
                                {priority,     <<"high">>},
                                %%{notification,         {[ {body_loc_key, "DOCUMENTS_NOTIFY"}, {title, Nickname} ]} },
                                {notification,   {Notify2_document} },
                                {data,         {DATA} }
                                %% If you need notification in android system tray, use:
                                %%, {notification, {BF}}
                               ]},

                               {jiffy:encode({{PushMessage}}), DisableArgs};  
                              
                                                     
                            _ ->
                              
                              {jiffy:encode({}), DisableArgs} 
                          end          
      end;




  


    

pending_element_to_json(_) ->
    unknown.

parse_response(ResponseBody) ->
    {JsonData} = jiffy:decode(ResponseBody),
    case proplists:get_value(<<"success">>, JsonData) of
        1 ->
            ok;
        0 ->
            [{Result}] = proplists:get_value(<<"results">>, JsonData),
            case proplists:get_value(<<"error">>, Result) of
                <<"NotRegistered">> ->
                    ?ERROR_MSG("FCM error: NotRegistered, unregistered user", []),
                    not_registered;
                <<"InvalidRegistration">> ->
                    ?ERROR_MSG("FCM error: InvalidRegistration, unregistered user", []),
                    invalid_registration;
                _ -> other
            end
    end.
