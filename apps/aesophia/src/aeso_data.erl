-module(aeso_data).

-export([to_binary/1,to_binary/2,binary_to_words/1,from_binary/2,from_binary/3]).

-include("aeso_icode.hrl").

%% Encode the data as a heap fragment starting at address 32. The first word is
%% a pointer into the heap fragment. The reason we store it at address 32 is to
%% leave room for the state pointer at address 0.
to_binary(Data) ->
    to_binary(Data, 32).

to_binary(Data, BaseAddress) ->
    {Address, Memory} = to_binary1(Data, BaseAddress + 32),
    <<Address:256, Memory/binary>>.

%% Allocate the data in memory, from the given address.  Return a pair
%% of memory contents from that address and the value representing the
%% data.
to_binary1(Data,_Address) when is_integer(Data) ->
    {Data,<<>>};
to_binary1(Data, Address) when is_binary(Data) ->
    %% a string
    Words = binary_to_words(Data),
    {Address,<<(size(Data)):256, << <<W:256>> || W <- Words>>/binary>>};
to_binary1(none, Address) -> to_binary1([], Address);
to_binary1({some, Value}, Address) -> to_binary1({Value}, Address);
to_binary1(Data, Address) when is_tuple(Data) ->
    {Elems,Memory} = to_binaries(tuple_to_list(Data),Address+32*size(Data)),
    ElemsBin = << <<W:256>> || W <- Elems>>,
    {Address,<< ElemsBin/binary, Memory/binary >>};
to_binary1([],_Address) ->
    <<Nil:256>> = <<(-1):256>>,
    {Nil,<<>>};
to_binary1([H|T],Address) ->
    to_binary1({H,T},Address).


to_binaries([],_Address) ->
    {[],<<>>};
to_binaries([H|T],Address) ->
    {HRep,HMem} = to_binary1(H,Address),
    {TRep,TMem} = to_binaries(T,Address+size(HMem)),
    {[HRep|TRep],<<HMem/binary, TMem/binary>>}.

binary_to_words(<<>>) ->
    [];
binary_to_words(<<N:256,Bin/binary>>) ->
    [N|binary_to_words(Bin)];
binary_to_words(Bin) ->
    binary_to_words(<<Bin/binary,0>>).

%% Interpret a return value (a binary) using a type rep.

%% Base address is the address of the first word of the given heap.
from_binary(BaseAddr, T, Heap = <<V:256, _/binary>>) ->
    from_binary1(T, <<0:BaseAddr/unit:8, Heap/binary>>, V).

from_binary(T,Heap= <<V:256,_/binary>>) ->
    from_binary1(T,Heap,V).

from_binary1(word,_,V) ->
    V;
from_binary1(signed_word, _, V) ->
    <<N:256/signed>> = <<V:256>>,
    N;
from_binary1(string,Heap,V) ->
    StringSize = heap_word(Heap,V),
    BitAddr = 8*(V+32),
    <<_:BitAddr,Bytes:StringSize/binary,_/binary>> = Heap,
    Bytes;
from_binary1({tuple,Cpts},Heap,V) ->
    list_to_tuple([from_binary1(T,Heap,heap_word(Heap,V+32*I))
		   || {T,I} <- lists:zip(Cpts,lists:seq(0,length(Cpts)-1))]);
from_binary1({list,Elem},Heap,V) ->
    <<Nil:256>> = <<(-1):256>>,
    if V==Nil ->
	    [];
       true ->
	    {H,T} = from_binary1({tuple,[Elem,{list,Elem}]},Heap,V),
	    [H|T]
    end;
from_binary1({option, A}, Heap, V) ->
    <<None:256>> = <<(-1):256>>,
    if V == None -> none;
       true      ->
         {Elem} = from_binary1({tuple, [A]}, Heap, V),
         {some, Elem}
    end;
from_binary1(typerep, Heap, V) ->
    Tag = from_binary1(word, Heap, heap_word(Heap, V)),
    Arg = fun(T) -> from_binary1(T, Heap, heap_word(Heap, V + 32)) end,
    case Tag of
        ?TYPEREP_WORD_TAG   -> word;
        ?TYPEREP_STRING_TAG -> string;
        ?TYPEREP_LIST_TAG   -> {list,   Arg(typerep)};
        ?TYPEREP_OPTION_TAG -> {option, Arg(typerep)};
        ?TYPEREP_TUPLE_TAG  -> {tuple,  Arg({list, typerep})}
    end.

heap_word(Heap,Addr) ->
    BitSize = 8*Addr,
    <<_:BitSize,W:256,_/binary>> = Heap,
    W.
