-module(ir).
-export([generate/1]).

-record(state,{lbcnt=0,rvcnt=0,lvcnt=0,fn=#{},sizeof=#{},scope=0,break=0,continue=0,
               enum_names=[],var=#{},typedef=#{},struct=#{},enum=#{},typecheck=#{}}).

-include("arch_type_consts.hrl").

%% @doc Takes a slightly convoluted & complex AST and compiles them into a more human-readable form.
%       This form is also a lot closer to the target language (MIPS ASM) than an AST.

%% Arity 1 function for default arguments
generate(Ast) ->
  generate(Ast, #state{}).

%% On a leaf node of the AST, return the current state
generate([], State) -> {ok, State, []};

%% For a node with branches, process the node, then the branch & return the merged IR code
generate([Hd|Tl], State) ->
  {ok, Hd_State, Hd_St} = generate(Hd,State),
  {ok, Tl_State, Tl_St} = generate(Tl,Hd_State),
  %% EDITED: was Tl_State, now: copy_lbcnt(Tl_State,State)
  Last = if length(Tl_St) > 0 -> lists:last(Tl_St);
            true -> nil end,
  St = if
    Tl_State#state.rvcnt > State#state.rvcnt andalso Last =/= return ->
      Hd_St++Tl_St++[{gc,State#state.rvcnt}];
    true -> Hd_St++Tl_St
  end,
  N_Types = maps:merge(Tl_State#state.typecheck,State#state.typecheck),
  N_Var = maps:merge(Tl_State#state.var,State#state.var),
  N_Sizeof = maps:merge(Tl_State#state.sizeof,State#state.sizeof),
  N_State = Tl_State#state{sizeof=N_Sizeof,var=N_Var,typecheck=N_Types},
  {ok,N_State,St};

%% Process a declaration of a function by adding specification about it to the state &
%  processing the branches of the function node (arguments & statement list)
%% TODO: make this support pointers
generate({function,{Raw_Type,{Raw_Ident,Raw_Args},Raw_St}}, State) when is_list(Raw_Args) ->
  {ok, Type} = get_type(Raw_Type, State),
  {ok, Ident, _Ptr_Ident, Arr} = get_ident_specs(Raw_Ident,State),
  % Is this ok?
  if Arr =/= [] -> error({return_type,array});
  true -> ok end,
  % Reverse because the stack be like that sometimes
  {ok, Arg_State, _Arg_St} = generate(lists:reverse(Raw_Args), State#state{scope=1}),
  Arg_Types = [Arg_T || {{y,_},{_Arr,Arg_T}} <- maps:to_list(Arg_State#state.typecheck)],
  Arity = case Raw_Args of
    [[{void,_}]] -> 0;
    _ -> length(Raw_Args)
  end,
  Alloc_St = lists:flatten([[{allocate,size_var({y,N},Arg_State)},
                             {move,{z,Arity-N-1},{y,N}}] || N <- lists:seq(0,Arity-1)]),
  New_Fn = maps:put(Ident,{{Arr,Type},length(Raw_Args)},Arg_State#state.fn),
  {ok, N_State, N_St} = generate(Raw_St,Arg_State#state{fn=New_Fn}),
  Rtn_St = if
    N_St =:= [] ->
      [{function,Type,Ident,Arg_Types,[return]}];
    true -> case lists:last(N_St) of
      return ->
        [{function,Type,Ident,Arg_Types,Alloc_St++N_St}];
      _ ->
        {ok, Dealloc} = deallocate_mem(#{},N_State#state.var),
        [{function,Type,Ident,Arg_Types,Alloc_St++N_St++[Dealloc,return]}]
    end
  end,
  {ok,copy_lbcnt(N_State,State#state{fn=New_Fn}),Rtn_St};

generate({function,{Raw_Type,Raw_Ident_Ptr,Raw_St}}, State) ->
  {ok,{Ident,Raw_Args},Ptr,Arr} = get_ident_specs(Raw_Ident_Ptr,State),
  {ok,{P,T,S}} = get_type(Raw_Type,State),
  Type = {P+Ptr,T,S},
  if Arr =/= [] -> error({return_type,array});
  true -> ok end,
  % Reverse because the stack be like that sometimes
  {ok, Arg_State, _Arg_St} = generate(lists:reverse(Raw_Args), State#state{scope=1}),
  Arg_Types = [Arg_T || {{y,_},{_Arr,Arg_T}} <- maps:to_list(Arg_State#state.typecheck)],
  Arity = case Raw_Args of
    [[{void,_}]] -> 0;
    _ -> length(Raw_Args)
  end,
  Alloc_St = lists:flatten([[{allocate,size_var({y,N},Arg_State)},
                             {move,{z,Arity-N-1},{y,N}}] || N <- lists:seq(0,Arity-1)]),
  New_Fn = maps:put(Ident,{{Arr,Type},length(Raw_Args)},Arg_State#state.fn),
  {ok, N_State, N_St} = generate(Raw_St,Arg_State#state{fn=New_Fn}),
  Rtn_St = case lists:last(N_St) of
    return ->
      [{function,Type,Ident,Arg_Types,Alloc_St++N_St}];
    _ ->
      {ok, Dealloc} = deallocate_mem(#{},N_State#state.var),
      [{function,Type,Ident,Arg_Types,Alloc_St++N_St++[Dealloc,return]}]
  end,
  {ok,copy_lbcnt(N_State,State#state{fn=New_Fn}),Rtn_St};

generate({declaration,[{typedef,_}|Raw_Type],[Raw_Ident]}, State) ->
  {ok,{P,T,S}} = get_type(Raw_Type, State),
  {ok,Ident,Ptr_Depth,Raw_Arr} = get_ident_specs(Raw_Ident, State),
  Arr = [get_constant(Elem,State) || Elem <- Raw_Arr],
  N_Td = maps:put(Ident,{Arr,{P+Ptr_Depth,T,S}},State#state.typedef),
  {ok, State#state{typedef=N_Td}, []};

generate({declaration,[{{enum,_},{identifier,_,Ident},Enums}],[]}, State) ->
  N_Enums = [Ident|State#state.enum_names],
  {ok,Enum_State} = put_enums(Enums,0,State#state{enum_names=N_Enums}),
  {ok,Enum_State,[]};

generate({declaration,[{{enum,_},{identifier,_,_Ident},_Enums}],Raw_St}, _State) ->
  error({enum_statement,Raw_St});

generate({declaration,[{{struct,_},{identifier,_,Ident},Struct}],[]}, State=#state{struct=Structs}) ->
  Type = lists:foldr(fun
    ({Raw_Type,[Raw_Ident]}, {struct,Members}) ->
      {ok,Mem_Ident,Ptr_Depth,Raw_Arr} = get_ident_specs(Raw_Ident,State),
      {ok,{P,T,S}} = get_type(Raw_Type,State),
      Arr = [get_constant(Elem,State) || Elem <- Raw_Arr],
      {struct,[{Mem_Ident,{Arr,{P+Ptr_Depth,T,S}}}|Members]}
  end,{struct,[]},Struct),
  N_Structs = Structs#{Ident=>Type},
  {ok,State#state{struct=N_Structs},[]};

generate({declaration,[{{struct,_},{identifier,_,Ident},Struct}],Decl}, State=#state{struct=Structs}) ->
  Type = lists:foldr(fun
    ({Raw_Type,[Raw_Ident]}, {struct,Members}) ->
      {ok,Mem_Ident,Ptr_Depth,Raw_Arr} = get_ident_specs(Raw_Ident,State),
      {ok,{P,T,S}} = get_type(Raw_Type,State),
      Arr = [get_constant(Elem,State) || Elem <- Raw_Arr],
      {struct,[{Mem_Ident,{Arr,{P+Ptr_Depth,T,S}}}|Members]}
  end,{struct,[]},Struct),
  N_Structs = Structs#{Ident=>Type},
  generate({declaration,[{{struct,0},{identifier,0,Ident}}],Decl},State#state{struct=N_Structs});

generate({break,_},State) ->
  Break = State#state.break,
  {ok,State,[{jump,{l,Break}}]};

generate({continue,_},State) ->
  Continue = State#state.continue,
  {ok,State,[{jump,{l,Continue}}]};

%% As there are multiple cases for declaration, it is delegated to a helper function.
generate({declaration,Raw_Type,Raw_St}, State) ->
  {ok, Type} = get_type(Raw_Type, State),
  get_decl_specs(Type,Raw_St,State);

%% Process an integer node by moving the literal value to the active register
generate({int_l,_Line,Val,[]}, State) ->
  Lv_Cnt = State#state.lvcnt,
  N_Types = maps:put({x,Lv_Cnt},{[],{0,i,?SIZEOF_INT}},State#state.typecheck),
  {ok,State#state{typecheck=N_Types},[{move,{i,Val},{x,Lv_Cnt}}]};
generate({int_l,_Line,Val,[u]}, State) ->
  Lv_Cnt = State#state.lvcnt,
  N_Types = maps:put({x,Lv_Cnt},{[],{0,u,?SIZEOF_INT}},State#state.typecheck),
  {ok,State#state{typecheck=N_Types},[{move,{i,Val},{x,Lv_Cnt}},{cast,{x,Lv_Cnt},{0,u,?SIZEOF_INT}}]};
generate({int_l,_Line,Val,[c]}, State) ->
  Lv_Cnt = State#state.lvcnt,
  N_Types = maps:put({x,Lv_Cnt},{[],{0,u,?SIZEOF_CHAR}},State#state.typecheck),
  {ok,State#state{typecheck=N_Types},[{move,{i,Val},{x,Lv_Cnt}},{cast,{x,Lv_Cnt},{0,u,?SIZEOF_CHAR}}]};
generate({int_l,_Line,Val,[l]}, State) ->
  Lv_Cnt = State#state.lvcnt,
  N_Types = maps:put({x,Lv_Cnt},{[],{0,i,?SIZEOF_LONG}},State#state.typecheck),
  {ok,State#state{typecheck=N_Types},[{move,{i,Val},{x,Lv_Cnt}},{cast,{x,Lv_Cnt},{0,i,?SIZEOF_LONG}}]};
generate({int_l,_Line,Val,[ul]}, State) ->
  Lv_Cnt = State#state.lvcnt,
  N_Types = maps:put({x,Lv_Cnt},{[],{0,u,?SIZEOF_LONG}},State#state.typecheck),
  {ok,State#state{typecheck=N_Types},[{move,{i,Val},{x,Lv_Cnt}},{cast,{x,Lv_Cnt},{0,u,?SIZEOF_LONG}}]};

%% Process a float node by moving the literal value to the active register
%  As doubles are out of spec we currently don't support these however it may be useful to later
generate({float_l,_Line,Val,[$f|_]}, State) ->
  Lv_Cnt = State#state.lvcnt,
  N_Types = maps:put({x,Lv_Cnt},{[],{0,f,?SIZEOF_FLOAT}},State#state.typecheck),
  {ok,State#state{typecheck=N_Types},[{move,{f,Val},{x,Lv_Cnt}}]};

generate({float_l,_Line,Val,Suf}, State) ->
  Lv_Cnt = State#state.lvcnt,
  N_Types = maps:put({x,Lv_Cnt},{[],{0,f,?SIZEOF_DOUBLE}},State#state.typecheck),
  {ok,State#state{typecheck=N_Types},[{move,{f,Val},{x,Lv_Cnt}},{cast,{x,Lv_Cnt},{0,f,?SIZEOF_DOUBLE}}]};

%% Process an identifier by finding the integer's location on the stack
%  and moving it to the active register
generate({identifier,Ln,Ident}, State) ->
  Lv_Cnt = State#state.lvcnt,
  case {maps:get(Ident,State#state.var,undefined),maps:get(Ident,State#state.enum,undefined)} of
    {{{[],Type}, X},_} ->
      N_Types = maps:put({x,Lv_Cnt},{[],Type},State#state.typecheck),
      {ok,State#state{typecheck=N_Types},[{move,X,{x,Lv_Cnt}}]};
    {{{Arr,{P,T,S}},X},_} ->
      % Not sure if P should be P+length(Arr) or P+1 or something??
      % So that we can reference it as a pointer?
      N_Types = maps:put({x,Lv_Cnt},{Arr,{P,T,S}},State#state.typecheck),
      {ok,State#state{typecheck=N_Types},[{address,X,{x,Lv_Cnt}}]};
    {{S={struct,Members},Reg},_} ->
      N_Types = maps:put({x,Lv_Cnt},S,State#state.typecheck),
      {ok,State#state{typecheck=N_Types},[{move,Reg,{x,Lv_Cnt}}]};
    {_,undefined} ->
      error({undef,Ident,{line,Ln}});
    {_,Value} ->
      N_Types = maps:put({x,Lv_Cnt},{[],{0,i,32}},State#state.typecheck),
      {ok,State#state{typecheck=N_Types},[{move,{i,Value},{x,Lv_Cnt}}]}
  end;

generate(Raw_Ident={_,{{'.',_},_}},State=#state{lvcnt=Lv_Cnt,var=Var,typecheck=Types}) ->
  {ok,Ident,_,_} = get_ident_specs(Raw_Ident,State),
  #{Ident := {Type,M_Loc}} = Var,
  N_Types = maps:put({x,Lv_Cnt},Type,Types),
  {ok,State#state{typecheck=N_Types},[{move,M_Loc,{x,Lv_Cnt}}]};


%% TODO: Fix this for new arrays
generate({Rest,{array, Offset}}, State) ->
  % TODO: Find out if this works?
  Lv_Cnt = State#state.lvcnt,
  {ok,Ptr_State,Ptr_St} = generate(Rest,State),
  case maps:get({x,Lv_Cnt},Ptr_State#state.typecheck,{[],{0,n,0}}) of
    {[],_} ->
      generate({{'*',0},{bif,'+',[Rest,Offset]}},State);
    _ ->
      {ok,Off_State,Off_St} = generate(Offset,Ptr_State#state{lvcnt=Lv_Cnt+1}),
      {Arr,Type} = maps:get({x,Lv_Cnt},Ptr_State#state.typecheck),
      Size = lists:foldl(fun ({_,A},B) -> A*B end,1,tl(Arr)),
      Arr_St = Ptr_St++Off_St++[{move,{i,Size},{x,Lv_Cnt+2}},
                                {'*',[{x,Lv_Cnt+1},{x,Lv_Cnt+2}],{x,Lv_Cnt+1}},
                                {'+',[{x,Lv_Cnt},{x,Lv_Cnt+1}],{x,Lv_Cnt}}],
      case Arr of
        [_] ->
          N_Types = maps:put({x,Lv_Cnt},{tl(Arr),Type},Ptr_State#state.typecheck),
          Rtn_St = Arr_St ++ [{load,{x,Lv_Cnt},{x,Lv_Cnt}}],
          {ok,copy_lvcnt(Off_State,Ptr_State#state{typecheck=N_Types}),Rtn_St};
        % TODO: Find effects of *not* making this a pointer?
        %       I'm not sure how we'd support pointer to array though - would we at all?
        _ ->
          {P,T,S} = Type,
          N_Types = maps:put({x,Lv_Cnt},{tl(Arr),{P,T,S}},Ptr_State#state.typecheck),
          {ok,copy_lvcnt(Off_State,Ptr_State#state{typecheck=N_Types}),Arr_St}
    end
  end;

%% Process a function call by storing the current register state on the stack,
% storing the arguments to the function on the stack,
% calling the function, then restoring the register state.
generate({{identifier,Ln,Ident},{apply,Args}}, State) ->
  {ok,Arg_State,Arg_St} = lists:foldl(fun
    (Arg,{ok,Acc_State,Acc_St}) ->
      {ok,Acc_Rtn_State,Acc_Rtn_St} = generate(Arg,Acc_State),
      Lv_Cnt = Acc_State#state.lvcnt,
      {ok,copy_lbcnt(Acc_Rtn_State,Acc_State#state{lvcnt=Lv_Cnt+1}),Acc_St++Acc_Rtn_St}
  end, {ok,State,[]}, Args),
  case maps:get(Ident,Arg_State#state.fn, undefined) of
    {Type, Arity} when Arity =:= length(Args) ->
      Lv_Cnt = State#state.lvcnt,
      Rv_Cnt = State#state.rvcnt,
      Alloc_St = [{allocate,?SIZEOF_INT} || _ <- lists:seq(0,Lv_Cnt-1)],
      Mv_To_St = [{move,{x,N},{y,Rv_Cnt+N}} || N <- lists:seq(0,Lv_Cnt-1)],
      To_A_St = [{move,{x,Lv_Cnt+N},{z,N}} || N <- lists:seq(0,Arity-1)],
      Call_St = {call,Ident,Arity},
      Mv_Bk_St = [{move,{y,Rv_Cnt+N},{x,N}} || N <- lists:seq(0,Lv_Cnt-1)],
      New_St = if
        Lv_Cnt =:= 0 -> Arg_St++Alloc_St++Mv_To_St++To_A_St++[Call_St|Mv_Bk_St];
        true ->
          Dealloc_St = {gc,Rv_Cnt},
          Mv_0_St = {move,{x,0},{x,Lv_Cnt}},
          Arg_St++Alloc_St++Mv_To_St++To_A_St++[Call_St,Mv_0_St|Mv_Bk_St]++[Dealloc_St]
      end,
      N_Types = maps:put({x,Lv_Cnt},Type,State#state.typecheck),
      {ok,copy_lbcnt(Arg_State,State#state{typecheck=N_Types}),New_St};
    Other ->
      error({Other, Ident, {args, Args}, {line, Ln}, {state, State}})
  end;

generate({sizeof,Expr},State) ->
  Lv_Cnt = State#state.lvcnt,
  case get_type(Expr,State) of
    {ok,{0,_,S}} ->
      Types = State#state.typecheck,
      N_Types = maps:put({x,Lv_Cnt},{[],{0,i,?SIZEOF_INT}},Types),
      {ok,State#state{typecheck=N_Types},[{move,{i,S div 8},{x,Lv_Cnt}}]};
    {ok,_} -> {ok,State,[{move,{i,?SIZEOF_POINTER div 8},{x,Lv_Cnt}}]};
    _ ->
      {ok,Expr_State,_Expr_St} = generate(Expr, State),
      Type = maps:get({x,Lv_Cnt},Expr_State#state.typecheck,{[],{0,n,0}}),
      Size = sizeof(Type,Expr_State),
      Types = State#state.typecheck,
      N_Types = maps:put({x,Lv_Cnt},{[],{0,i,?SIZEOF_INT}},Types),
      {ok,State#state{typecheck=N_Types},[{move,{i,Size div 8},{x,Lv_Cnt}}]}
  end;

%% As there are multiple cases for assignment, it is delegated to a helper function.
generate({assign,{Op,_Ln},Raw_Specs}, State) ->
  get_assign_specs(Op,Raw_Specs,State);

%% ++ and -- for both prefix and postfix operators
generate({Rest,{increment,Op,{_,Ln}}}, State) ->
  get_assign_specs('=',[Rest,{bif,Op,[Rest,{int_l,Ln,1,[]}]}], State);
generate({{increment,Op,{_,Ln}},Rest}, State) ->
  get_assign_specs('=',[Rest,{bif,Op,[Rest,{int_l,Ln,1,[]}]}], State);

%% Process a return value by deallocating any memory used (and args),
%  processing the expression which calculates the value to return
%  and storing it in the active register (which should always be 0)
generate({{return,_},Raw_St}, State) ->
  {ok, Rtn_State, Rtn_St} = generate(Raw_St, State),
  {ok, Dealloc} = deallocate_mem(#{},Rtn_State#state.var),
  {ok, Rtn_State#state{lvcnt=0,rvcnt=0}, Rtn_St++[Dealloc,return]};

%% Process an if statement by processing each of the predicate, the "if true" statement
%  and the "if false" statement, then controlling the PC flow with jumps.
%  For simple 'if's, only the "if true" statement is returned, and for 'if/else'
%  both are returned.
generate({{'if',_},Predicate,True,False}, State) ->
  Lb_Cnt = State#state.lbcnt,
  Lv_Cnt = State#state.lvcnt,
  {ok,If_State,If_St} = generate(Predicate,State#state{lbcnt=Lb_Cnt+2}),
  Test_State = If_State#state{lvcnt=Lv_Cnt},
  Test_Jump = {test,{x,Lv_Cnt},{l,Lb_Cnt+1}},
  {ok,True_State,True_St} = generate(True,Test_State),
  {ok,True_Dealloc} = deallocate_mem(Test_State#state.var,True_State#state.var),
  False_Label = {label,Lb_Cnt+1},
  {ok,False_State,False_St} = generate(False,copy_lbcnt(True_State,Test_State)),
  {ok,False_Dealloc} = deallocate_mem(Test_State#state.var,False_State#state.var),
  Rtn_State = copy_lbcnt(False_State,State),
  if
    False_St =:= [] ->
      Rtn_St = If_St++[Test_Jump|True_St]++[True_Dealloc,False_Label],
      {ok,Rtn_State,Rtn_St};
    true ->
      True_Jump = {jump,{l,Lb_Cnt+2}},
      True_Label = {label,Lb_Cnt+2},
      Rtn_St = If_St++[Test_Jump|True_St]++[True_Dealloc,True_Jump,False_Label|False_St]++[False_Dealloc,True_Label],
      {ok,Rtn_State,Rtn_St}
  end;

generate({{switch,_},Raw_St,Raw_Cases},State) ->
  {ok,Switch_State,Switch_St} = generate(Raw_St,State),
  {Lists,[]} = gen_cases(Raw_Cases,Switch_State),
  Lb_Cnt = Switch_State#state.lbcnt,
  Zipped = lists:zip(Lists,lists:seq(Lb_Cnt+1,Lb_Cnt+length(Lists))),
  Cases = gen_case_branches(Zipped,Switch_State),
  Gen_State = Switch_State#state{lbcnt=Lb_Cnt+length(Lists),break=Lb_Cnt+length(Lists)},
  {ok,Rtn_State,Rtn_St} = gen_case_st(Zipped,Gen_State),
  {ok,Rtn_State#state{lvcnt=State#state.lvcnt},lists:flatten(Switch_St++Cases++Rtn_St)};


%% Process a while loop by processing each of the predicate and the loop body,
%  having the PC jump to beyond the end of the loop if the predicate evaluates to zero
%  and having an unconditional jump to before the predicate at the end of the loop.
generate({{while,_},Predicate,Do}, State) ->
  Lb_Cnt = State#state.lbcnt + 1,
  Start_Label = {label,Lb_Cnt},
  {ok,Pred_State,Pred_St} = generate(Predicate,State#state{lbcnt=Lb_Cnt+1}),
  Test_Jump = {test,{x,State#state.lvcnt},{l,Lb_Cnt+1}},
  P_Lb_Cnt = Pred_State#state.lbcnt,
  Pre_Do_State = Pred_State#state{lbcnt=P_Lb_Cnt,break=Lb_Cnt+1,continue=Lb_Cnt},
  {ok,Do_State,Do_St} = generate(Do,copy_lvcnt(State,Pre_Do_State)),
  {ok,Do_Dealloc} = deallocate_mem(Pred_State#state.var,Do_State#state.var),
  Jump = {jump,{l,Lb_Cnt}},
  End_Label = {label,Lb_Cnt + 1},
  Rtn_State = copy_lbcnt(Do_State,State),
  Rtn_St = [Start_Label|Pred_St] ++ [Test_Jump|Do_St] ++ [Do_Dealloc,Jump,End_Label],
  {ok,Rtn_State,Rtn_St};

%% Process a do while loop by processing each of the loop body and the predicate
%  and having the PC jump back to the start of the loop if the predicate,
%  which is evaluated after the loop body, evaluates to non-zero.
generate({{do,_},Do,Predicate}, State) ->
  Lb_Cnt = State#state.lbcnt,
  Start_Label = {label,Lb_Cnt + 1},
  Pre_Do_State = State#state{lbcnt=Lb_Cnt+2,break=Lb_Cnt+2,continue=Lb_Cnt+1},
  {ok,Do_State,Do_St} = generate(Do,Pre_Do_State),
  {ok,Do_Dealloc} = deallocate_mem(State#state.var,Do_State#state.var),
  {ok,Pred_State,Pred_St} = generate(Predicate,copy_lbcnt(Do_State,State)),
  Test_Jump = {test,{x,State#state.lvcnt},{l,Lb_Cnt+2}},
  Jump = {jump,{l,Lb_Cnt+1}},
  End_Label = {label,Lb_Cnt + 2},
  Rtn_State = copy_lbcnt(Pred_State,State),
  Rtn_St = [Start_Label|Do_St] ++ [Do_Dealloc|Pred_St] ++ [Test_Jump,Jump,End_Label],
  {ok,Rtn_State,Rtn_St};

%% Process a for loop by processing the initialiser,
%  creating a snapshot of the state & then using this as a root state to process
%  each of the predicate, loop body and the 'update' statement.
%  If the predicate evaluates to zero, the PC jumps beyond the end of the loop.
generate({{for,_},{Init,Predicate,Update},Loop}, State) ->
  Lb_Cnt = State#state.lbcnt,
  Lv_Cnt = State#state.lvcnt,
  {ok,Init_State,Init_St} = generate(Init,State#state{lbcnt=Lb_Cnt+2}),
  Root_State = Init_State#state{lvcnt=Lv_Cnt},
  Pred_Label = {label,Lb_Cnt+1},
  {ok,Pred_State,Pred_St} = generate(Predicate,Root_State),
  Pred_Test = {test,{x,Lv_Cnt},{l,Lb_Cnt+2}},
  Pre_Loop_State = copy_lbcnt(Pred_State,Root_State#state{break=Lb_Cnt+2,continue=Lb_Cnt+1}),
  {ok,Loop_State,Loop_St} = generate(Loop,Pre_Loop_State),
  {ok,Dealloc} = deallocate_mem(Init_State#state.var,Loop_State#state.var),
  {ok,Update_State,Update_St} = generate(Update,copy_lbcnt(Loop_State,Root_State)),
  Jump = {jump,{l,Lb_Cnt+1}},
  End_Label = {label,Lb_Cnt+2},
  Next_State = copy_lbcnt(Update_State,State),
  Next_St = Init_St ++ [Pred_Label|Pred_St] ++ [Pred_Test|Loop_St] ++ [Dealloc|Update_St] ++ [Jump,End_Label],
  {ok,Next_State,Next_St};

generate({string_l,Ln,Str},State) ->
  St = [[{int_l,Ln,N,[c]}] || N <- Str]++[{int_l,Ln,0,[c]}],
  Rv_Cnt = State#state.rvcnt,
  Lv_Cnt = State#state.lvcnt,
  Heap_St = lists:flatten([{allocate,8*length(St)},
                           {cast,{y,Rv_Cnt},{0,u,8}},
                           {address,{y,Rv_Cnt},{x,Lv_Cnt}},
                           {move,{i,1},{x,Lv_Cnt+1}},
                           {'-',[{x,Lv_Cnt},{x,Lv_Cnt+1}],{x,Lv_Cnt}}|
                           gen_heap({[{i,length(St)}],{0,u,8}},State,St)]),
  N_Types = maps:put({y,Rv_Cnt},{1,u,8},State#state.typecheck),
  N_Var = maps:put(Str,{{[{i,length(St)}],{0,u,8}},{y,Rv_Cnt}},State#state.var),
  Lv_Cnt = State#state.lvcnt,
  {ok,State#state{rvcnt=Rv_Cnt+1,typecheck=N_Types,var=N_Var},
   Heap_St++[{address,{y,Rv_Cnt},{x,Lv_Cnt}}]};

%% Process an arity 2 built-in function (such as add or bitwise and)
%  by calculating whether processing the 1st or 2nd operand first would be less register
%  intensive, then returning the way which is less register intensive.
%% TODO: #N/A
%        Find a more efficient way to do this, as this is exponential complexity.
generate({bif,T,[A,B]}, State) ->
  Way_1 = process_bif(T,A,B,State,true),
  Way_2 = process_bif(T,A,B,State,false),
  case {(element(2,Way_1))#state.lvcnt,(element(2,Way_2))#state.lvcnt} of
    {_A,_B} when _A>_B -> Way_2;
    _ -> Way_1
  end;

% S-S-S-SHORTCUT....
% it's probably the same thing, right?
generate({'?',St,[A,B]}, State) ->
  generate({{'if',0},St,[A],[B]},State);

%% Process an address operator by adding an expression to take the address of
%  the value which was loaded to a register or put on the stack in the last instruction
%  and store it in the destination of the last instruction.
generate({{'&',Ln},Raw_St}, State) ->
  {ok, Ref_State, Ref_St} = generate(Raw_St, State),
  case lists:last(Ref_St) of
    {move,Src,Dest} ->
      Next_St = lists:droplast(Ref_St) ++ [{address,Src,Dest}],
      {ok,copy_lvcnt(State,Ref_State),Next_St};
    {load,_Src,Dest} ->
      Next_St = Ref_St ++ [{address,Dest,Dest}],
      {ok,copy_lvcnt(State,Ref_State),Next_St};
    {address,_Src,Dest} ->
      Next_St = Ref_St ++ [{address,Dest,Dest}],
      {ok,copy_lvcnt(State,Ref_State),Next_St};
    Other -> error({address_error,Other,{line,Ln}})
    end;

%% Process a dereference operator by finding the location of the variable we are
%  dereferencing and either replacing the `move` statement with a `load` statement
%  or adding a `load` statement to the end, depending on what we are dereferncing.
generate({{'*',Ln},Raw_St},State) ->
  {ok, Ptr_State, Ptr_St} = generate(Raw_St, State),
  Active_Reg = {x,State#state.lvcnt},
  case maps:get(Active_Reg,Ptr_State#state.typecheck,undefined) of
    {[],{N,T,S}} ->
      New_Types = maps:put(Active_Reg,{[],{N-1,T,S}},Ptr_State#state.typecheck),
      N_State = Ptr_State#state{typecheck=New_Types},
      case lists:last(Ptr_St) of
        {move,Src,Dest} ->
          Next_St = lists:droplast(Ptr_St) ++ [{load,Src,Dest}],
          {ok,copy_lvcnt(State,N_State),Next_St};
        {_,_,Dest} ->
          Next_St = Ptr_St ++ [{load,Dest,Dest}],
          {ok,copy_lvcnt(State,N_State),Next_St};
        Other -> error({Other,{line,Ln}})
      end;
    {[_Hd|Arr],Type} ->
      New_Types = maps:put(Active_Reg,{Arr,Type},Ptr_State#state.typecheck),
      N_State = Ptr_State#state{typecheck=New_Types},
      {ok,copy_lvcnt(State,N_State),Ptr_St}
  end;


generate({{'-',_Ln},Raw_St},State) ->
  {ok, St_State, St} = generate(Raw_St,State),
  Active_Reg = {x,State#state.lvcnt},
  Temp_Reg = {x,State#state.lvcnt+1},
  Rtn_St = St ++ [{move,{i,0},Temp_Reg},{'-',[Temp_Reg,Active_Reg],Active_Reg}],
  {ok,St_State,Rtn_St};

generate({{'+',_Ln},Raw_St},State) -> generate(Raw_St,State);

generate({{'~',_Ln},Raw_St},State) ->
  {ok, St_State, St} = generate(Raw_St,State),
  Active_Reg = {x,State#state.lvcnt},
  Temp_Reg = {x,State#state.lvcnt+1},
  Rtn_St = St ++ [{move,{i,16#FFFFFFFF},Temp_Reg},
                  {'*',[Active_Reg,Temp_Reg],Active_Reg},
                  {'+',[Active_Reg,Temp_Reg],Active_Reg}],
  {ok,St_State,Rtn_St};

generate({{'!',_Ln},Raw_St},State) ->
  {ok, St_State, St} = generate(Raw_St,State),
  Active_Reg = {x,State#state.lvcnt},
  Temp_Reg = {x,State#state.lvcnt+1},
  Rtn_St = St ++ [{move,{i,0},Temp_Reg},{'==',[Active_Reg,Temp_Reg],Active_Reg}],
  {ok,St_State,Rtn_St};

generate({void,_},State) ->
  {ok,State,[]};
%% Empty statement in for loop
generate({[]},State) ->
  {ok,State,[]};

%% Any other nodes of the AST are currently unsupported.
%  Currently we raise an error, dumping the unsupported node as well as the current state.
generate(Other, _State) -> error({no_ir,Other}).

get_decl_specs(Struct={struct,Members},[{Raw_Ident,{'=',_},Raw_St}],State=#state{rvcnt=Rv_Cnt,lvcnt=Lv_Cnt,var=Var,sizeof=Sz,typecheck=Types}) ->
  {ok, Ident, Ptr_Depth, []} = get_ident_specs(Raw_Ident, State),
  if
    Ptr_Depth =:= 0 ->
      Size = sizeof(Struct,State),
      {A_St,A_State=#state{var=Var_1}} = lists:foldl(fun
        (N,{Al_St,Al_State=#state{rvcnt=N_Reg,var=A_Var}}) ->
          {Name,Type} = lists:nth(N,Members),
          Init = try lists:nth(N,Raw_St) catch _:_ -> [] end,
          {ok,Mem_State,Mem_St} = allocate_mem(Type,Al_State,{y,N_Reg},Init),
          {Al_St++Mem_St++[{move,{x,Lv_Cnt},{y,N_Reg}}],Mem_State#state{var=A_Var#{{Ident,Name}=>{Type,{y,N_Reg}}},rvcnt=N_Reg+1}}
      end,{[{allocate,0},{cast,{y,Rv_Cnt},{0,n,Size}}],State#state{rvcnt=Rv_Cnt+1}},lists:seq(1,length(Members))),
      N_State = A_State#state{var=Var_1#{Ident => {Struct,{y,Rv_Cnt}}}},
      {ok,N_State,A_St};
    true ->
      Alloc = [{allocate,32}],
      N_State = State#state{rvcnt=Rv_Cnt+1,var=Var#{Ident => {{Ptr_Depth,Struct},{y,Rv_Cnt}}},
                            typecheck=Types#{{y,Rv_Cnt}=>{Ptr_Depth,Struct}},sizeof=Sz#{{y,Rv_Cnt}=>32}}
  end;

get_decl_specs(Struct={struct,Members},[Raw_Ident],State=#state{rvcnt=Rv_Cnt,var=Var,sizeof=Sz,typecheck=Types})->
  %% Concept: Allocate 0 & tie to struct var name then allocate for each member?
  {ok, Ident, Ptr_Depth, []} = get_ident_specs(Raw_Ident, State),
  if
    Ptr_Depth =:= 0 ->
      Size = sizeof(Struct,State),
      {A_St,A_State=#state{var=Var_1}} = lists:foldl(fun
        ({Name,Type},{Al_St,Al_State=#state{rvcnt=N_Reg,var=A_Var}}) ->
          {ok,Mem_State,Mem_St} = allocate_mem(Type,Al_State,{y,N_Reg},[]),
          {Al_St++Mem_St,Mem_State#state{var=A_Var#{{Ident,Name}=>{Type,{y,N_Reg}}},rvcnt=N_Reg+1}}
      end,{[{allocate,0},{cast,{y,Rv_Cnt},{0,n,Size}}],State#state{rvcnt=Rv_Cnt+1}},Members),
      N_State = A_State#state{var=Var_1#{Ident => {Struct,{y,Rv_Cnt}}}},
      {ok,N_State,A_St};
    true ->
      Alloc = [{allocate,32}],
      N_State = State#state{rvcnt=Rv_Cnt+1,var=Var#{Ident => {{Ptr_Depth,Struct},{y,Rv_Cnt}}},
                            typecheck=Types#{{y,Rv_Cnt}=>{Ptr_Depth,Struct}},sizeof=Sz#{{y,Rv_Cnt}=>32}}
  end;

%% Delegated function for declarations.
%% Function prototypes
get_decl_specs({N,Raw_T,Raw_S}, [{Raw_Ident,Args}], State) when is_list(Args) ->
  {ok, Ident, Ptr_Depth, Raw_Arr} = get_ident_specs(Raw_Ident, State),
  Arr = [get_constant(Elem,State) || Elem <- Raw_Arr],
  if Arr =/= [] -> error({return_type,array});
     true -> ok end,
  Type = {Arr,{N+Ptr_Depth,Raw_T,Raw_S}},
  Arity = case Args of
    [{void,_}] -> 0;
    _ -> length(Args)
  end,
  New_Fn = maps:put(Ident,{Type,Arity},State#state.fn),
  {ok,State#state{fn=New_Fn},[]};

%% Global Variables with an assignment
get_decl_specs({N,Raw_T,Raw_S},[{Raw_Ident,{'=',_},Raw_St}],State) when State#state.scope =:= 0 ->
  {ok, Ident, Ptr_Depth, Raw_Arr} = get_ident_specs(Raw_Ident,State),
  Arr = [get_constant(Elem,State) || Elem <- Raw_Arr],
  Type = {Arr,{N+Ptr_Depth,Raw_T,Raw_S}},
  {ok, Mem_State, Mem_St} = allocate_mem(Type, State, {g,Ident},Raw_St),
  New_Var = maps:put(Ident,{Type,{g,Ident}},Mem_State#state.var),
  New_Types = maps:put({g,Ident},{Arr,Type},Mem_State#state.typecheck),
  New_State = (copy_lvcnt(State,Mem_State))#state{typecheck=New_Types,var=New_Var},
  {ok,New_State,[{global,Type,Ident,Mem_St}]};

%% Declarations with an initialisation are processed by allocating memory
%  for them on the stack, processing the initialisation value and storing
%  the initialisation value in the newly allocated stack slot.
%% Apart from strings, for now I'm making them arrays lol
% Is this still needed?
get_decl_specs(Type, [{{{'*',_},{identifier,_,Ident}},{'=',_},{string_l,Ln,Str}}], State) ->
  St = [{int_l,Ln,N,[c]} || N <- Str]++[{int_l,Ln,0,[c]}],
  Raw_Ident = {{identifier,Ln,Ident},{array,{int_l,Ln,length(St),[]}}},
  get_decl_specs(Type, [{Raw_Ident,{'=',Ln},St}], State);

get_decl_specs({N,Raw_T,Raw_S}, [{Raw_Ident,{'=',_},Raw_St}], State) ->
  {ok, Ident, Ptr_Depth, Raw_Arr} = get_ident_specs(Raw_Ident, State),
  Arr = [get_constant(Elem,State) || Elem <- Raw_Arr],
  Var_Type = {N+Ptr_Depth,Raw_T,Raw_S},
  Type = {Arr,Var_Type},
  Rv_Cnt = State#state.rvcnt,
  {ok, Mem_State, Mem_St} = allocate_mem(Type,State,{y,Rv_Cnt},Raw_St),
  Active_Reg = {x,State#state.lvcnt},
  New_Var = maps:put(Ident,{Type,{y,Rv_Cnt}},Mem_State#state.var),
  New_Types = maps:put({y,Rv_Cnt},Type,Mem_State#state.typecheck),
  Next_State = (copy_lvcnt(State,Mem_State))#state{var=New_Var,rvcnt=Rv_Cnt+1,typecheck=New_Types},
  Next_St = case maps:get(Active_Reg,Next_State#state.typecheck,undefined) of
    {[],Var_Type} -> Mem_St ++ [{move,Active_Reg,{y,Rv_Cnt}}];
    {[],_} -> Mem_St ++ [{cast,Active_Reg,Var_Type},{move,Active_Reg,{y,Rv_Cnt}}];
    {_,Var_Type} -> Mem_St;
    {_,_Type_0} -> Mem_St ++ [{cast,{y,Rv_Cnt},Var_Type}]
  end,
  {ok, Next_State, Next_St};

%% Global variables which are not assigned
get_decl_specs({N,Raw_T,Raw_S}, [Raw_Ident], State) when State#state.scope =:= 0 ->
  {ok, Ident, Ptr_Depth, Raw_Arr} = get_ident_specs(Raw_Ident, State),
  Arr = [get_constant(Elem,State) || Elem <- Raw_Arr],
  Type = {Arr,{N+Ptr_Depth,Raw_T,Raw_S}},
  {ok, Mem_State, Mem_St} = allocate_mem(Type, State, {g,Ident},[]),
  New_Var = maps:put(Ident,{Type,{g,Ident}},Mem_State#state.var),
  New_Types = maps:put({g,Ident},Type,Mem_State#state.typecheck),
  New_State = (copy_lvcnt(State,Mem_State))#state{typecheck=New_Types,var=New_Var},
  {ok,New_State,[{global,Type,Ident,Mem_St}]};

%% Declarations without an initialisation are processed by allocating memory
%  for them on the stack and then updating the state to indicate the new stack size.
get_decl_specs({N,Raw_T,Raw_S}, [Raw_Ident], State) ->
  {ok, Ident, Ptr_Depth, Raw_Arr} = get_ident_specs(Raw_Ident, State),
  Arr = [get_constant(Elem,State) || Elem <- Raw_Arr],
  Type = {Arr,{N+Ptr_Depth,Raw_T,Raw_S}},
  Rv_Cnt = State#state.rvcnt,
  {ok, Mem_State, Mem_St} = allocate_mem(Type, State,{y,Rv_Cnt},[]),
  New_Var = maps:put(Ident,{Type,{y,Rv_Cnt}},Mem_State#state.var),
  New_Types = maps:put({y,Rv_Cnt},Type,Mem_State#state.typecheck),
  Next_State = (copy_lvcnt(State,Mem_State))#state{var=New_Var,rvcnt=Rv_Cnt+1,typecheck=New_Types},
  {ok,Next_State,Mem_St};

%% Any other declaration types are currently unsupported.
%% TODO: #5
%        We need to support array declarations and accesses,
%        which will be done using the `[]` operators and the `offset` token
get_decl_specs(Type, Other, State) -> error({Type,Other,State}).

%% Function for getting information about an identifier.
%% Strips superfluous information (line numbers etc) from the identifier
%  and returns the identifier and the a version with dereference etc. operators maintained.
%% TODO: Assignments to *(a+b) etc.
get_ident_specs({{'&',_},Rest}, State) ->
  {ok, Ident, Ptr_Depth, Arr} = get_ident_specs(Rest, State),
  {ok, Ident, Ptr_Depth-1, Arr};
get_ident_specs({{'*',_},{bif,'+',[A,B]}}, State) ->
  try get_ident_specs(A, State) of
    {ok, Ident, Ptr_Depth, Arr} -> {ok, Ident, Ptr_Depth,Arr++[B]}
  catch
    _:_ ->
      {ok, Ident, Ptr_Depth, Arr} = get_ident_specs(B, State),
      {ok, Ident, Ptr_Depth+1, Arr++[A]}
  end;
get_ident_specs({{'*',_},Rest}, State) ->
  {ok, Ident, Ptr_Depth, Arr} = get_ident_specs(Rest, State),
  {ok, Ident, Ptr_Depth+1, Arr};
get_ident_specs({{{'*',_},Ptr},Rest}, State) ->
  {ok, Ident, Ptr_Depth, Arr} = get_ident_specs({Ptr,Rest}, State),
  {ok, Ident, Ptr_Depth+1, Arr};
get_ident_specs({Rest,{array,N}}, State) ->
  {ok, Ident, Ptr_Depth, Arr} = get_ident_specs(Rest, State),
  {ok, Ident, Ptr_Depth,Arr++[N]};
get_ident_specs({bif,'-',[A,B]}, State) ->
  {ok, Ident, Ptr_Depth, Arr} = get_ident_specs(A, State),
  {ok, Ident, Ptr_Depth,Arr++[{{'-',0},B}]};
get_ident_specs({'*',_}, _State) ->
  {ok, '', 1, []};
get_ident_specs({{identifier,_,Ident},Fn_St}, _State) when is_list(Fn_St) ->
{ok, {Ident,Fn_St}, 0, []};
get_ident_specs({Rest,{{'.',_},{identifier,_,Ident}}}, State) ->
  {ok,I_Rest,Ptr_Depth,Arr} = get_ident_specs(Rest,State),
  {ok,{I_Rest,Ident},Ptr_Depth,Arr};
get_ident_specs({identifier,_,Ident}, _State) ->
  {ok, Ident, 0, []};
get_ident_specs(Ident, _State) ->
  error({ident_specs,Ident}).


%% To allocate stack memory for a variable, allocate the size of the variable type.
%% TODO: 11
%        Initialisation of arrays/global variables
allocate_mem({[],Type},State,{y,N},Init) ->
  N_Sizes = maps:put({y,N},sizeof(Type,State),State#state.sizeof),
  N_State = State#state{sizeof=N_Sizes},
  {ok, Decl_State, Decl_St} = generate(Init, N_State),
  {ok,Decl_State,[{allocate,sizeof(Type,State)}|Decl_St]};

allocate_mem({[],Type},State,Dest,Init) ->
  N_Sizes = maps:put(Dest,sizeof(Type,State),State#state.sizeof),
  N_State = State#state{sizeof=N_Sizes},
  {ok,N_State,{data,Type,get_constant(Init,State)}};

allocate_mem(Type,State,{y,N},Init) ->
  Heap_St = lists:flatten(gen_heap(Type,State,Init)),
  Size = sizeof(Type,State),
  Lv_Cnt = State#state.lvcnt,
  N_Types = maps:merge(#{{x,Lv_Cnt}=>Type,{y,N}=>Type},State#state.typecheck),
  N_Sizes = maps:put({y,N},Size,State#state.sizeof),
  N_State = State#state{sizeof=N_Sizes,typecheck=N_Types},
  case Heap_St of
    [] -> {ok,N_State,[{allocate,Size},{cast,{y,N},element(2,Type)}]};
    _ ->{ok,N_State,[{allocate,Size},{cast,{y,N},element(2,Type)},{address,{y,N},{x,Lv_Cnt}},
                     {move,{i,1},{x,Lv_Cnt+1}},{'-',[{x,Lv_Cnt},{x,Lv_Cnt+1}],{x,Lv_Cnt}}|Heap_St]}
  end;

allocate_mem(Type,State,{g,Ident},Init) ->
  Heap_St = gen_global_heap(Type,State,Init),
  Size = sizeof(Type,State),
  N_Sizes = maps:put({g,Ident},Size,State#state.sizeof),
  N_State = State#state{sizeof=N_Sizes},
  {ok,N_State,Heap_St}.

gen_heap({[],_Type},State,Init) ->
  {ok,_,St} = generate(Init,State),
  St;

gen_heap({[_Const],{P,T,S}},State,Inits) when length(Inits) > 0 ->
  Lv_Cnt = State#state.lvcnt,
  [[{move,{i,1},{x,Lv_Cnt+1}},
    {'+',[{x,Lv_Cnt},{x,Lv_Cnt+1}],{x,Lv_Cnt}} |
     % Changed from {P-1,T,S}
    gen_heap({[],{P,T,S}},State#state{lvcnt=Lv_Cnt+1},Init)] ++
   [{store,{x,Lv_Cnt+1},{x,Lv_Cnt}}] || Init <- Inits];

% Array doesn't need initialising or something idk
gen_heap(_,_State,[]) -> [];

gen_heap({[_|Arr],{P,T,S}},State,Inits) ->
  [gen_heap({Arr,{P-1,T,S}},State,Init) || Init <- Inits].


% TODO: Make sure this doesn't interfere with actual array generation (this is for empty arrays)
gen_global_heap({[],Type},_State,[]) ->
  {data,Type,{i,0}};

gen_global_heap({[],Type},State,Init) ->
  {data,Type,get_constant(Init,State)};

gen_global_heap({[Const|Arr],{P,T,S}},State,[]) ->
  {_,N} = Const,
  % Changed from {P-1,T,S}
  Data = [gen_global_heap({Arr,{P,T,S}},State,[]) || _ <- lists:seq(1,N)],
  {local,Data};

gen_global_heap({[Const|Arr],{P,T,S}},State,Inits) when is_list(Inits) ->
  {_,N} = Const,
  Indices = lists:zip(lists:seq(0,N-1),Inits),
  % Changed from {P-1,T,S}
  Data = [gen_global_heap({Arr,{P,T,S}},State,Init) || {_,Init} <- Indices],
  {local,Data}.

get_constant({int_l,_,N,_},_) ->
  {i,N};
get_constant({float_l,_,N,_},_) ->
  {f,N};
get_constant({bif,T,[A,B]},State) ->
  {At,Ac} = get_constant(A,State),
  {Bt,Bc} = get_constant(B,State),
  {resolve_type(At,Bt),do_op(T,[Ac,Bc])};
get_constant({sizeof,T},State) ->
  {ok,_,[{move,N,_}]} = generate({sizeof,T},State),
  N;
get_constant({i,N},_State) ->
  {i,N};
get_constant({f,N},_State) ->
  {i,N};
get_constant({identifier,_,Ident},State) ->
  case maps:get(Ident,State#state.enum,undefined) of
    undefined -> error({not_const,Ident});
    Value -> {i,Value}
  end;
get_constant(Type,_State) ->
  error({not_const,Type}).

resolve_type(i,i) -> i;
resolve_type(_,f) -> f;
resolve_type(f,_) -> f;
resolve_type(_,_) -> i.

%% To deallocate memory due to variables going out of scope,
%  such as at the end of a compound statement or for a return statement,
%  the number of variables to trim the stack to is found & returned
deallocate_mem(State_1,_State_2) ->
  Rv_Cnt = maps:size(State_1),
  {ok, {gc,Rv_Cnt}}.

%% Delegated function for assignment.
%% For a normal assignment, the value to be assigned is processed and stored in the
%  active register. The destination is evaluated as to whether it is a variable or
%  a memory location and then the appropriate move/store instructions are returned.
get_assign_specs('=',[Raw_Ident,Raw_St], State) ->
  {ok,Ident,Ptr_Depth,Raw_Arr} = get_ident_specs(Raw_Ident, State),
  % TODO: Make this non_constant
  %Arr = [generate(Elem,State) || Elem <- Raw_Arr],
  Lv_Cnt = State#state.lvcnt,
  {Arr_State,Arr} = lists:foldr(fun (St,{Arr_Gen_State,Arr_Gen_St}) ->
    {ok,N_State,N_St} = generate(St,Arr_Gen_State),
    {N_State,[N_St|Arr_Gen_St]}
  end,{State#state{lvcnt=Lv_Cnt+2},[]},Raw_Arr),
  {ok,{Arr_Depth,{Rp,Rt,Rs}},Ptr} = case maps:get(Ident,Arr_State#state.var,undefined) of
    {T,Ptr_Loc} ->
      {ok,T,Ptr_Loc};
    Other -> {error, {Other,{undeclared,Ident}}}
  end,
  Arr_St = if
    Arr =:= [] -> [];
    true ->
      {Arr_Depth,Type} = maps:get(Ptr,Arr_State#state.typecheck),
      Offset_St = lists:foldl(fun
        (Index,{St,[_|Rest]}) ->
          St++Index++[{move,{i,sizeof({Rest,{0,i,1}},Arr_State)},{x,Lv_Cnt+3}},
                      {'*',[{x,Lv_Cnt+2},{x,Lv_Cnt+3}],{x,Lv_Cnt+2}},
                      {'+',[{x,Lv_Cnt+1},{x,Lv_Cnt+2}],{x,Lv_Cnt+1}}];
        (Index,{[{address,_Ptr,A_Reg}],[]}) ->
          [{move,Ptr,A_Reg}] ++ Index ++ [{'+',[{x,Lv_Cnt+1},{x,Lv_Cnt+2}],{x,Lv_Cnt+1}}];
        (Index,{St,[]}) ->
          St ++ Index ++ [{'+',[{x,Lv_Cnt+1},{x,Lv_Cnt+2}],{x,Lv_Cnt+1}}]
      end,{[{address,Ptr,{x,Lv_Cnt+1}}],Arr_Depth},Arr),
      Offset_St
  end,
  {ok,Ptr_Type,Ptr_St} = get_ptr({Arr,{Rp,Rt,Rs}},Ptr_Depth,Ptr,State#state{lvcnt=Lv_Cnt+1}),
  {ok,Assign_State,Assign_St} = generate(Raw_St,Arr_State#state{lvcnt=Lv_Cnt}),
  St_Type = maps:get({x,Lv_Cnt},Assign_State#state.typecheck,undefined),
  case Arr_St++Ptr_St of
    [] ->
      End_St = if
        element(2,St_Type) =/= Ptr_Type -> [{cast,{x,Lv_Cnt},Ptr_Type},{move,{x,Lv_Cnt},Ptr}];
        true -> [{move,{x,Lv_Cnt},Ptr}]
      end,
      Next_St = Assign_St ++ End_St,
      {ok,copy_lbcnt(Assign_State,State),Next_St};
    Var_St ->
      {_,_,Dest} = lists:last(Assign_St),
      End_St = if
        element(2,St_Type) =/= Ptr_Type -> [{cast,{x,Lv_Cnt},Ptr_Type},{store,Dest,{x,Lv_Cnt+1}}];
        true -> [{store,Dest,{x,Lv_Cnt+1}}]
      end,
      Next_St = Assign_St ++ Var_St ++ End_St,
      {ok,copy_lbcnt(Assign_State,State),Next_St}
  end;

%% A non-normal assignment such as `+=` is confirmed into an assignment and
%  a built-in function to calulate the result of the operation.
get_assign_specs(Op,[Raw_Ident,Raw_St], State) ->
  get_assign_specs('=',[Raw_Ident,{bif,Op,[Raw_Ident,Raw_St]}], State);

%% Any other declaration types are currently unsupported.
%% I'm not certain that there are any, however if there are then it will cause an error.
get_assign_specs(Op, Other, State) ->
  error({Op,Other,State}).

%% When there is no dereference operator, an empty statement is returned.
% TODO: Do we need to do something about arrays here?
% Probably we should?
get_ptr({_,Type},0,_Ptr,_State) ->
  {ok,Type,[]};
get_ptr({_,{N,T,S}},Ptr_Depth,Ptr,State) ->
  Type = {N-Ptr_Depth,T,S},
  Active_Reg = {x,State#state.lvcnt},
  %% Should this be -1?
  Load_St = [{move,Ptr,Active_Reg}|get_ptr_load_st(Ptr_Depth,Active_Reg,Active_Reg)],
  {ok,Type,Load_St}.

get_ptr_load_st(1,_Reg,_Ptr) -> [];
get_ptr_load_st(N,Reg,Ptr) -> [{load,Ptr,Reg}|get_ptr_load_st(N-1,Reg,Reg)].

%% Delegated function for processing built-in functions.
%% A special case for operations which can be done on pointers
%% TODO: N/A
%        Check for other pointer operations
%% TODO: N/A
%        Tidy this up
process_bif('+',Fst,Sec,State,Swap) ->
  Lv_Cnt = State#state.lvcnt,
  {A,B} = if Swap -> {Sec,Fst};
             true -> {Fst,Sec} end,
  {R1,R2} = if Swap -> {{x,Lv_Cnt+1},{x,Lv_Cnt}};
               true -> {{x,Lv_Cnt},{x,Lv_Cnt+1}} end,
  {ok,A_State,A_St} = generate(A,State),
  A_Type = maps:get({x,Lv_Cnt},A_State#state.typecheck,undefined),
  N_A_State = A_State#state{lvcnt=Lv_Cnt+1},
  {ok,B_State,B_St} = generate(B,N_A_State),
  B_Type = maps:get({x,Lv_Cnt+1},B_State#state.typecheck,undefined),
  {Mul_St,R_Type} = case {A_Type,B_Type} of
    {{[],{0,T,S_A}},{[],{0,T,S_B}}} -> {[],{[],{0,T,max(S_A,S_B)}}};
    {{[],{N,T,S_A}},{[],{0,i,_S_B}}} -> {[],{[],{N,T,S_A}}}; %% TODO: Change size of A
    {{[],{0,i,_S_A}},{[],{N,T,S_B}}} -> {[],{[],{N,T,S_B}}}; %% TODO: Change size of B
    {{Arr,Raw_A_Type},{[],_Raw_B_Type}} when Arr /= [] ->
      Arr_Size = lists:foldl(fun
        ({_,X},Y) -> X*Y;
        (X,Y) -> X*Y
      end,1,tl(Arr)),
      {[{move,{i,Arr_Size},{x,Lv_Cnt+2}},
        {'*',[{x,Lv_Cnt+1},{x,Lv_Cnt+2}],{x,Lv_Cnt+1}}],{tl(Arr),Raw_A_Type}};
    {{[],Raw_A_Type},{Arr,_Raw_B_Type}} when Arr /= [] ->
      Arr_Size = lists:foldl(fun
        ({_,X},Y) -> X*Y;
        (X,Y) -> X*Y
      end,1,tl(Arr)),
      {[{move,{i,Arr_Size},{x,Lv_Cnt+2}},
        {'*',[{x,Lv_Cnt},{x,Lv_Cnt+2}],{x,Lv_Cnt}}],{tl(Arr),Raw_A_Type}};
    Types -> error({{undefined_op_cast,'+'},Types,State,A,B})
  end,
  Lv_Cnt = State#state.lvcnt,
  Statement = A_St ++ B_St ++ Mul_St ++ [{'+',[R1,R2],{x,Lv_Cnt}}],
  N_Types = maps:put({x,Lv_Cnt},R_Type,B_State#state.typecheck),
  Rtn_State = B_State#state{typecheck=N_Types},
  {ok,Rtn_State,Statement};


process_bif('-',Fst,Sec,State,Swap) ->
  Lv_Cnt = State#state.lvcnt,
  {A,B} = if Swap -> {Sec,Fst};
             true -> {Fst,Sec} end,
  {R1,R2} = if Swap -> {{x,Lv_Cnt+1},{x,Lv_Cnt}};
               true -> {{x,Lv_Cnt},{x,Lv_Cnt+1}} end,
  {ok,A_State,A_St} = generate(A,State),
  N_A_State = A_State#state{lvcnt=Lv_Cnt+1},
  {ok,B_State,B_St} = generate(B,N_A_State),
  A_Type = maps:get({x,Lv_Cnt},A_State#state.typecheck,undefined),
  B_Type = maps:get({x,Lv_Cnt+1},B_State#state.typecheck,undefined),
  %% TODO: THIS WILL CRASH
  R_Type = case {A_Type,B_Type} of
    {{[],{0,T,S_A}},{[],{0,T,S_B}}} -> {[],{0,T,max(S_A,S_B)}};
    {{[],{N,T,S_A}},{[],{0,i,_S_B}}} -> {[],{N,T,S_A}}; %% TODO: Change size of B
    Types -> error({{undefined_op_cast,'-'},Types})
  end,
  Lv_Cnt = State#state.lvcnt,
  Statement = A_St ++ B_St ++ [{'-',[R1,R2],{x,Lv_Cnt}}],
  N_Types = maps:put({x,Lv_Cnt},R_Type,B_State#state.typecheck),
  Rtn_State = B_State#state{typecheck=N_Types},
  {ok,Rtn_State,Statement};

%% Arity 2 BIFs are processed by processing each of their operands and
%  adding a statement which will take the active register and the register above it,
%  perform the built-in function in the values in those registers and store the result
%  in the active register.
process_bif(Type,Fst,Sec,State,Swap) ->
  Lv_Cnt = State#state.lvcnt,
  {A,B} = if Swap -> {Sec,Fst};
             true -> {Fst,Sec} end,
  {R1,R2} = if Swap -> {{x,Lv_Cnt+1},{x,Lv_Cnt}};
               true -> {{x,Lv_Cnt},{x,Lv_Cnt+1}} end,
  {ok,A_State,A_St} = generate(A,State),
  N_A_State = A_State#state{lvcnt=Lv_Cnt+1},
  {ok,B_State,B_St} = generate(B,N_A_State),
  A_Type = maps:get({x,Lv_Cnt},A_State#state.typecheck,undefined),
  B_Type = maps:get({x,Lv_Cnt+1},B_State#state.typecheck,undefined),
  %% TODO: Fix float stuff for mul etc?
  %        Shouldn't matter as there's no casting but jic?
  R_Type = case {A_Type,B_Type} of
    {{[],{0,T,S_A}},{[],{0,T,S_B}}} -> {[],{0,T,max(S_A,S_B)}};
    {{[],{0,_,S_A}},{[],{0,_,S_B}}} -> {[],{0,i,max(S_A,S_B)}};
    Types -> error({{undefined_op_cast,Type},Types})
  end,
  Lv_Cnt = State#state.lvcnt,
  Statement = A_St ++ B_St ++ [{Type,[R1,R2],{x,Lv_Cnt}}],
  N_Types = maps:put({x,Lv_Cnt},R_Type,B_State#state.typecheck),
  Rtn_State = B_State#state{typecheck=N_Types},
  {ok,Rtn_State,Statement}.


gen_cases([],_State) ->
  {[none],[]};
gen_cases([{{default,_},{':',_},St}|Rest],State) ->
  {Cases,C_Case} = gen_cases(Rest,State),
  {[{default,[St|C_Case]}|Cases],[]};
gen_cases([{{'case',_},Const,{':',_},St}|Rest],State) ->
  {Cases,C_Case} = gen_cases(Rest,State),
  {[{get_constant(Const,State),[St|C_Case]}|Cases],[]};
gen_cases([St|Rest],State) ->
  {Cases,C_Case} = gen_cases(Rest,State),
  {Cases,[St|C_Case]}.

gen_case_branches([{none,Lb}],_State) ->
  [{jump,{l,Lb}}];
gen_case_branches([{{default,_},Lb}|Rest],State) ->
  % If we need default we don't need to make one?
  lists:droplast(gen_case_branches(Rest,State))++[{jump,{l,Lb}}];
gen_case_branches([{{Const,_},Lb}|Rest],State) ->
  Active_Reg = {x,State#state.lvcnt},
  Temp_Reg = {x,State#state.lvcnt+1},
  [{move,Const,Temp_Reg},
   {'!=',[Active_Reg,Temp_Reg],Temp_Reg},
   {test,Temp_Reg,{l,Lb}}|gen_case_branches(Rest,State)].

 gen_case_st([{none,Lb}],State) ->
   {ok,State,[{label,Lb}]};
 gen_case_st([{{_,St},Lb}|Rest],State) ->
   {ok,O_State,O_St} = gen_case_st(Rest,State),
   {ok,St_State,St_St} = generate(St,O_State),
   {ok,St_State,[{label,Lb}|St_St++O_St]}.

%% Get a shortened name of a type
%% TODO: #18
%        We need to add a typedef, enum & struct resolver here
get_type([{{enum,_},_}],_) -> {ok,{0,i,?SIZEOF_INT}};
get_type([{long,_},{double,_}],_) -> {ok,{0,f,?SIZEOF_L_DOUBLE}};
get_type([{double,_}],_)          -> {ok,{0,f,?SIZEOF_DOUBLE}};
get_type([{float,_}],_)           -> {ok,{0,f,?SIZEOF_FLOAT}};
get_type([{long,_},{int,_}],_)    -> {ok,{0,i,?SIZEOF_LONG}};
get_type([{long,_}],_)            -> {ok,{0,i,?SIZEOF_LONG}};
get_type([{unsigned,_}],_)        -> {ok,{0,u,?SIZEOF_INT}};
get_type([{signed,_}],_)          -> {ok,{0,i,?SIZEOF_INT}};
get_type([{int,_}],_)             -> {ok,{0,i,?SIZEOF_INT}};
get_type([{short,_},{int,_}],_)   -> {ok,{0,i,?SIZEOF_SHORT}};
get_type([{short,_}],_)           -> {ok,{0,i,?SIZEOF_SHORT}};
get_type([{char,_}],_)            -> {ok,{0,i,?SIZEOF_CHAR}};
get_type([{void,_}],_)            -> {ok,{0,n,0}};
get_type([{unsigned,_}|Type],C) ->
  case get_type(Type,C) of
    {ok,{P,i,N}} -> {ok,{P,u,N}};
    {error,{unknown_type,T}} -> {error,{unknown_type,[unsigned|T]}};
    _ -> {error,{unknown_type,[unsigned|Type]}}
  end;
get_type([{signed,_}|Type],C) ->
  case get_type(Type,C) of
    {ok,{P,i,N}} -> {ok,{P,i,N}};
    {error,{unknown_type,T}} -> {error,{unknown_type,[signed|T]}};
    _ -> {error,{unknown_type,[signed|Type]}}
  end;

get_type([{extern,_}|Type],C) -> get_type(Type,C);

% Struct with declaration of struct type
get_type([{{struct,_},{identifier,_,Ident}}],#state{struct=Struct}) ->
  {ok,maps:get(Ident,Struct)};

get_type([{typedef_name,_,Ident}], Context) ->
  {ok, element(2,maps:get(Ident,Context#state.typedef))};

get_type(Type,_) -> {error,{unknown_type,Type}}.

%% Function to return the size of different types.
%% TODO: #5
%        Arrays will likely behave a bit weirdly under sizeof,
%        so we have to establish their behaviour and implement them accordingly.
%% TODO: #18
%        Add support for compile-time evaluation of custom types.
%% TODO: N/A
%        Add support for compile-time evaluation of the size of variables,
%        if this is possible (confirm that allocation is done at declaration time?).
sizeof({0,_,S},_) -> S;
sizeof({_,_,_},_State) -> ?SIZEOF_POINTER;
sizeof({struct,[{_Name,Type}|Members]},State) ->
  sizeof(Type,State)+sizeof({struct,Members},State);
sizeof({struct,[]},State) -> 0;
sizeof({Arr,T},State) -> lists:foldl(fun
  ({_,A},B) -> A*B;
  (A,B) -> A*B
end,sizeof(T,State),Arr);
sizeof(Type,_State) -> error({type,Type}).

%% TODO: Replace this with new array thing
size_var(Var,State) ->
  case maps:get(Var,State#state.sizeof,undefined) of
    undefined -> ?SIZEOF_POINTER;
    S -> S
  end.

put_enums([{identifier,_,Ident}|Rest],N,State=#state{enum=Enums}) ->
  put_enums(Rest,N+1,State#state{enum=maps:put(Ident,N,Enums)});
put_enums([{{identifier,_,Ident},{'=',_},Constant}|Rest],_,State=#state{enum=Enums}) ->
  {i,N} = get_constant(Constant,State),
  put_enums(Rest,N+1,State#state{enum=maps:put(Ident,N,Enums)});
put_enums([],_,State) ->
  {ok,State}.


do_op('+',[A,B]) -> A+B;
do_op('-',[A,B]) -> A-B;
do_op('*',[A,B]) -> A*B;
do_op('%',[A,B]) -> A rem B;
do_op('==',[A,B]) -> A==B;
do_op('!=',[A,B]) -> A/=B;
do_op('>=',[A,B]) -> A>=B;
do_op('<=',[A,B]) -> B>=A;
do_op('>',[A,B]) -> A>B;
do_op('<',[A,B]) -> B>A;
do_op(Op,_) -> error({bif_not_recognised,Op}).

%% 2x helper functions to copy the label/local variable count from 1 state to another.
copy_lbcnt(State_1,State_2) -> State_2#state{lbcnt=State_1#state.lbcnt}.
copy_lvcnt(State_1,State_2) -> State_2#state{lvcnt=State_1#state.lvcnt}.
