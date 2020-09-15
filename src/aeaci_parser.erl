%%%-------------------------------------------------------------------
%%% @author gorbak25
%%% @copyright (C) 2020, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 15. Sep 2020 13:57
%%%-------------------------------------------------------------------
-module(aeaci_parser).

%% API
-export([parse_call/1, parse_id_or_con/1]).

-include("aeaci_ast.hrl").

-spec parse_call([aeaci_lexer:lex_token()]) -> #ast_call{} | {error, term()}.
parse_call(Tokens1) ->
    {#ast_id{namespace = []} = Name, [paren_start | Tokens2]} = parse_id_or_con(Tokens1),
    case parse_tuple(Tokens2) of
        {#ast_tuple{} = Args, []} -> %% Arity 0 and greater than 1
            #ast_call{what = Name, args = Args};
        {Literal, []} -> %% Arity 1
            #ast_call{what = Name, args = #ast_tuple{args = [Literal]}};
        _ ->
            {error, "Leftover tokens in entrypoint call"}
    end.

-spec parse_id_or_con([aeaci_lexer:lex_token()]) -> {#ast_id{} | #ast_con{}, [aeaci_lexer:lex_token()]}.
parse_id_or_con(Tokens1) ->
    {[_|_] = Names, Tokens2} =
    lists:splitwith(fun({con, _}) -> true; ({id, _}) -> true; (dot) -> true; (_) -> false end, Tokens1),
    {Qualifiers, Last} = {
        lists:filtermap(fun({con, S}) -> {true, S}; (dot) -> false end, lists:droplast(Names)),
        lists:last(Names)},
    case Last of
        {con, Name} ->
            {#ast_con{namespace = Qualifiers, con = Name}, Tokens2};
        {id, Name} ->
            {#ast_id{namespace = Qualifiers, id = Name}, Tokens2}
    end.

-spec parse_literal([aeaci_lexer:lex_token()]) -> {ast_literal(), [aeaci_lexer:lex_token()]}.
parse_literal([{int, Number} | Tokens]) ->
    {#ast_number{val = Number}, Tokens};
parse_literal([{hex, Number} | Tokens]) ->
    {#ast_number{val = Number}, Tokens};
parse_literal([{string, String} | Tokens]) ->
    {#ast_string{val = String}, Tokens};
parse_literal([{char, Char} | Tokens]) ->
    {#ast_char{val = Char}, Tokens};
parse_literal([{bytes, Bytes} | Tokens]) ->
    {#ast_bytes{val = Bytes}, Tokens};
parse_literal([record_start, record_end | Tokens]) ->
    {#ast_map{data = #{}}, Tokens};
parse_literal([paren_start | Tokens]) ->
    parse_tuple(Tokens);
parse_literal([list_start | Tokens]) ->
    parse_list(Tokens);
parse_literal([record_start, list_start | Tokens]) ->
    parse_map(Tokens);
parse_literal([record_start | Tokens]) ->
    parse_record(Tokens);
parse_literal([{Type, _} | _] = Tokens1) when Type =:= con; Type =:= id ->
    {Ast1, Tokens2} = parse_id_or_con(Tokens1),
    case {Ast1, Tokens2} of
        {#ast_id{namespace = [], id = [$a, $k, $_ | _] = SerializedPubkey}, _} ->
            {ok, Pubkey} = aeser_api_encoder:safe_decode(account_pubkey, list_to_binary(SerializedPubkey)),
            {#ast_account{pubkey = Pubkey}, Tokens2};
        {#ast_id{namespace = [], id = [$c, $t, $_ | _] = SerializedPubkey}, _} ->
            {ok, Pubkey} = aeser_api_encoder:safe_decode(contract_pubkey, list_to_binary(SerializedPubkey)),
            {#ast_contract{pubkey = Pubkey}, Tokens2};
        {#ast_id{namespace = [], id = [$o, $k, $_ | _] = SerializedPubkey}, _} ->
            {ok, Pubkey} = aeser_api_encoder:safe_decode(oracle_pubkey, list_to_binary(SerializedPubkey)),
            {#ast_oracle{pubkey = Pubkey}, Tokens2};
        {#ast_id{namespace = [], id = [$o, $q, $_ | _] = SerializedId}, _} ->
            {ok, Id} = aeser_api_encoder:safe_decode(oracle_query_id, list_to_binary(SerializedId)),
            {#ast_oracle_query{id = Id}, Tokens2};
        {#ast_id{namespace = [], id = "true"}, _} ->
            {#ast_bool{val = true}, Tokens2};
        {#ast_id{namespace = [], id = "false"}, _} ->
            {#ast_bool{val = false}, Tokens2};
        {#ast_id{} = Id, [equal | Tokens3]} ->
            %% For future proofing as user defined custom named args might get introduced to Sophia
            {LiteralAst, Tokens4} = parse_literal(Tokens3),
            {#ast_named_arg{name = Id, value = LiteralAst}, Tokens4};
        {#ast_con{} = Constructor, [paren_start | Tokens3]} ->
            %% Algebraic data type constructor
            case parse_tuple(Tokens3) of
                {#ast_tuple{} = Args, Tokens4} -> %% Arity 0 and greater than 1
                    {#ast_adt{con = Constructor, args = Args}, Tokens4};
                {Literal, Tokens4} -> %% Arity 1
                    {#ast_adt{con = Constructor, args = #ast_tuple{args = [Literal]}}, Tokens4}
            end;
        {#ast_con{} = Constructor, _} ->
            %% By default standalone Constructors have arity 0
            {#ast_adt{con = Constructor, args = #ast_tuple{args = []}}, Tokens2}
    end.

-spec parse_tuple([aeaci_lexer:lex_token()]) -> {ast_literal(), [aeaci_lexer:lex_token()]}.
%% One tuples automatically reduce to literals
parse_tuple([paren_end | Tokens]) ->
    {#ast_tuple{args = []}, Tokens};
parse_tuple([comma | Tokens]) ->
    parse_tuple(Tokens);
parse_tuple(Tokens1) ->
    {LiteralAst, Tokens2} = parse_literal(Tokens1),
    {Tuple, Tokens3} = parse_tuple(Tokens2),
    case {Tuple, LiteralAst} of
        {#ast_tuple{args = []}, _} ->
            {LiteralAst, Tokens3};
        {#ast_tuple{args = Args}, _} ->
            {#ast_tuple{args = [LiteralAst | Args]}, Tokens3};
        {_, _} ->
            {#ast_tuple{args = [LiteralAst, Tuple]}, Tokens3}
    end.

-spec parse_list([aeaci_lexer:lex_token()]) -> {#ast_list{}, [aeaci_lexer:lex_token()]}.
parse_list([list_end | Tokens]) ->
    {#ast_list{args = []}, Tokens};
parse_list([comma | Tokens]) ->
    parse_list(Tokens);
parse_list(Tokens1) ->
    {LiteralAst, Tokens2} = parse_literal(Tokens1),
    {#ast_list{args = List}, Tokens3} = parse_list(Tokens2),
    {#ast_list{args = [LiteralAst | List]}, Tokens3}.

-spec parse_map([aeaci_lexer:lex_token()]) -> {#ast_map{}, [aeaci_lexer:lex_token()]}.
parse_map([record_end | Tokens]) ->
    {#ast_map{data = #{}}, Tokens};
parse_map([comma, list_start | Tokens]) ->
    parse_map(Tokens);
parse_map(Tokens1) ->
    {KeyAst, [list_end, equal | Tokens2]} = parse_literal(Tokens1),
    {ValueAst, Tokens3} = parse_literal(Tokens2),
    {#ast_map{data = Map}, Tokens4} = parse_map(Tokens3),
    {#ast_map{data = maps:put(KeyAst, ValueAst, Map)}, Tokens4}.

-spec parse_record([aeaci_lexer:lex_token()]) -> {#ast_record{}, [aeaci_lexer:lex_token()]}.
parse_record([record_end | Tokens]) ->
    {#ast_record{data = []}, Tokens};
parse_record([comma | Tokens]) ->
    parse_record(Tokens);
parse_record(Tokens1) ->
    {NamedArgAst, Tokens2} = parse_named_arg(Tokens1),
    {#ast_record{data = Data}, Tokens3} = parse_record(Tokens2),
    {#ast_record{data = [NamedArgAst | Data]}, Tokens3}.

-spec parse_named_arg([aeaci_lexer:lex_token()]) -> {#ast_named_arg{}, [aeaci_lexer:lex_token()]}.
parse_named_arg(Tokens1) ->
    {#ast_id{namespace = []} = Name, [equal | Tokens2]} = parse_id_or_con(Tokens1),
    {LiteralAst, Tokens3} = parse_literal(Tokens2),
    {#ast_named_arg{name = Name, value = LiteralAst}, Tokens3}.
