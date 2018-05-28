%%%-------------------------------------------------------------------
%%% @copyright (C) 2017, Aeternity Anstalt
%%% @doc Block state Merkle trees.
%%% @end
%%%-------------------------------------------------------------------
-module(aec_trees).

-include("common.hrl").
-include("blocks.hrl").

%% API

-export([accounts/1,
         commit_to_db/1,
         hash/1,
         new/0,
         channels/1,
         ns/1,
         oracles/1,
         calls/1,
         contracts/1,
         set_accounts/2,
         set_calls/2,
         set_channels/2,
         set_contracts/2,
         set_ns/2,
         set_oracles/2
        ]).

-export([apply_signed_txs/6,
         apply_signed_txs_strict/6,
         ensure_account/2]).

-record(trees, {
          accounts  :: aec_accounts_trees:tree(),
          calls     :: aect_call_state_tree:tree(),
          channels  :: aesc_state_tree:tree(),
          contracts :: aect_state_tree:tree(),
          ns        :: aens_state_tree:tree(),
          oracles   :: aeo_state_tree:tree()}).

-opaque trees() :: #trees{}.
-export_type([trees/0]).

%%%%=============================================================================
%% API
%%%=============================================================================

-spec new() -> trees().
new() ->
    #trees{accounts  = aec_accounts_trees:empty_with_backend(),
           calls     = aect_call_state_tree:empty_with_backend(),
           channels  = aesc_state_tree:empty_with_backend(),
           contracts = aect_state_tree:empty_with_backend(),
           ns        = aens_state_tree:empty_with_backend(),
           oracles   = aeo_state_tree:empty_with_backend()
          }.

-spec commit_to_db(trees()) -> trees().
commit_to_db(Trees) ->
    %% Make this in a transaction to get atomicity.
    aec_db:transaction(fun() -> internal_commit_to_db(Trees) end).

hash(Trees) ->
    internal_hash(Trees).

-spec accounts(trees()) -> aec_accounts_trees:tree().
accounts(Trees) ->
    Trees#trees.accounts.

-spec set_accounts(trees(), aec_accounts_trees:tree()) -> trees().
set_accounts(Trees, Accounts) ->
    Trees#trees{accounts = Accounts}.

-spec channels(trees()) -> aesc_state_tree:tree().
channels(Trees) ->
    Trees#trees.channels.

-spec set_channels(trees(), aesc_state_tree:tree()) -> trees().
set_channels(Trees, Channels) ->
    Trees#trees{channels = Channels}.

-spec ns(trees()) -> aens_state_tree:tree().
ns(Trees) ->
    Trees#trees.ns.

-spec set_ns(trees(), aens_state_tree:tree()) -> trees().
set_ns(Trees, Names) ->
    Trees#trees{ns = Names}.

-spec oracles(trees()) -> aeo_state_tree:tree().
oracles(Trees) ->
    Trees#trees.oracles.

-spec set_oracles(trees(), aeo_state_tree:tree()) -> trees().
set_oracles(Trees, Oracles) ->
    Trees#trees{oracles = Oracles}.

-spec perform_pre_transformations(trees(), height()) -> trees().
perform_pre_transformations(Trees, Height) ->
    Trees0 = aect_call_state_tree:prune(Height, Trees),
    Trees1 = aeo_state_tree:prune(Height, Trees0),
    set_ns(Trees1, aens_state_tree:prune(Height, ns(Trees1))).

-spec calls(trees()) -> aect_call_state_tree:tree().
calls(Trees) ->
    Trees#trees.calls.

-spec set_calls(trees(), aect_call_state_tree:tree()) -> trees().
set_calls(Trees, Calls) ->
    Trees#trees{calls = Calls}.

-spec contracts(trees()) -> aect_state_tree:tree().
contracts(Trees) ->
    Trees#trees.contracts.

-spec set_contracts(trees(), aect_state_tree:tree()) -> trees().
set_contracts(Trees, Contracts) ->
    Trees#trees{contracts = Contracts}.

-spec apply_signed_txs_strict(pubkey(), list(aetx_sign:signed_tx()), list(aetx_sign:signed_tx()),
                              trees(), height(), non_neg_integer()) ->
                                 {ok, list(aetx_sign:signed_tx()), trees()}
                               | {'error', atom()}.
apply_signed_txs_strict(Miner, SignedTxs, PrevBlockSignedTxs, Trees, Height, ConsensusVersion) ->
    apply_signed_txs_common(Miner, SignedTxs, PrevBlockSignedTxs, Trees, Height, ConsensusVersion, true).

-spec apply_signed_txs(pubkey(), list(aetx_sign:signed_tx()), list(aetx_sign:signed_tx()),
                       trees(), height(), non_neg_integer()) ->
                          {ok, list(aetx_sign:signed_tx()), trees()}.
apply_signed_txs(Miner, SignedTxs, PrevBlockSignedTxs, Trees, Height, ConsensusVersion) ->
    {ok, _, _} = apply_signed_txs_common(Miner, PrevBlockSignedTxs, SignedTxs, Trees, Height, ConsensusVersion, false).

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

internal_hash(Trees) ->
    AccountsHash = aeu_mtrees:pad_empty(aec_accounts_trees:root_hash(accounts(Trees))),
    CallsHash = aeu_mtrees:pad_empty(aect_call_state_tree:root_hash(calls(Trees))),
    ChannelsHash = aeu_mtrees:pad_empty(aesc_state_tree:root_hash(channels(Trees))),
    ContractsHash = aeu_mtrees:pad_empty(aect_state_tree:root_hash(contracts(Trees))),
    OraclesHash = aeu_mtrees:pad_empty(aeo_state_tree:root_hash(oracles(Trees))),
    NamingSystemHash = aeu_mtrees:pad_empty(aens_state_tree:root_hash(ns(Trees))),
    List = lists:sort([ {<<"accounts"/utf8>> , AccountsHash}
                      , {<<"calls"/utf8>>    , CallsHash}
                      , {<<"channels"/utf8>> , ChannelsHash}
                      , {<<"contracts"/utf8>>, ContractsHash}
                      , {<<"oracles"/utf8>>  , OraclesHash}
                      , {<<"ns"/utf8>>       , NamingSystemHash}
                      ]),
    TopTree = lists:foldl(fun({Key, Val}, Acc) ->
                                  aeu_mtrees:enter(Key, Val, Acc)
                          end,
                         aeu_mtrees:empty(), List),
    {ok, Hash} = aeu_mtrees:root_hash(TopTree),
    Hash.

internal_commit_to_db(Trees) ->
    Trees#trees{ contracts = aect_state_tree:commit_to_db(contracts(Trees))
               , calls     = aect_call_state_tree:commit_to_db(calls(Trees))
               , channels  = aesc_state_tree:commit_to_db(channels(Trees))
               , ns        = aens_state_tree:commit_to_db(ns(Trees))
               , oracles   = aeo_state_tree:commit_to_db(oracles(Trees))
               , accounts  = aec_accounts_trees:commit_to_db(accounts(Trees))
               }.

apply_signed_txs_common(Miner, SignedTxs, PrevBlockSignedTxs, Trees0, Height, ConsensusVersion, Strict) ->
    Trees1 = perform_pre_transformations(Trees0, Height),
    %% TODO: NG BUG1: we apply award for every block (only key blocks!)
    %% TODO: NG BUG2: Where do we give award to the second miner?
    case apply_txs_on_state_trees(SignedTxs, Trees1, Height, ConsensusVersion, Strict) of
        {ok, SignedTxs1, Trees2} ->
            TotalReward = calculate_total_reward(SignedTxs1, PrevBlockSignedTxs),
            Trees3 = grant_fee_to_miner(Miner, Trees2, TotalReward),
            {ok, SignedTxs1, Trees3};
        {error, _} = E -> E
    end.

apply_txs_on_state_trees(SignedTxs, Trees, Height, ConsensusVersion, Strict) ->
    apply_txs_on_state_trees(SignedTxs, [], Trees, Height, ConsensusVersion, Strict).

apply_txs_on_state_trees([], FilteredSignedTxs, Trees, _Height,_ConsensusVersion,_Strict) ->
    {ok, lists:reverse(FilteredSignedTxs), Trees};
apply_txs_on_state_trees([SignedTx | Rest], FilteredSignedTxs, Trees0, Height, ConsensusVersion, Strict) ->
    case aetx_sign:verify(SignedTx, Trees0) of
        ok ->
            Tx = aetx_sign:tx(SignedTx),
            case aetx:check(Tx, Trees0, Height, ConsensusVersion) of
                {ok, Trees1} ->
                    {ok, Trees2} = aetx:process(Tx, Trees1, Height, ConsensusVersion),
                    apply_txs_on_state_trees(Rest, [SignedTx | FilteredSignedTxs], Trees2, Height, ConsensusVersion, Strict);
                {error, Reason} when Strict ->
                    lager:debug("Tx ~p cannot be applied due to an error ~p", [Tx, Reason]),
                    {error, Reason};
                {error, Reason} when not Strict ->
                    lager:debug("Tx ~p cannot be applied due to an error ~p", [Tx, Reason]),
                    apply_txs_on_state_trees(Rest, FilteredSignedTxs, Trees0, Height, ConsensusVersion, Strict)
            end;
        {error, signature_check_failed} = E when Strict ->
            lager:debug("Signed tx ~p is not correctly signed.", [SignedTx]),
            E;
        {error, signature_check_failed} when not Strict ->
            lager:debug("Signed tx ~p is not correctly signed.", [SignedTx]),
            apply_txs_on_state_trees(Rest, FilteredSignedTxs, Trees0, Height, ConsensusVersion, Strict)
    end.


calculate_total_reward(SignedTxs, PrevBlockSignedTxs) ->
    CurrentBlockReward = total_fee(SignedTxs),
    PrevBlockReward    = total_fee(PrevBlockSignedTxs),
    aec_governance:block_mine_reward() + floor(0.4 * CurrentBlockReward) + ceil(0.6 * PrevBlockReward).

total_fee(SignedTxs) ->
    lists:foldl(
      fun(SignedTx, TotalFee) ->
              Fee = aetx:fee(aetx_sign:tx(SignedTx)),
              TotalFee + Fee
      end, 0, SignedTxs).

-spec grant_fee_to_miner(list(aetx_sign:signed_tx()), trees(), non_neg_integer()) ->
                                trees().
grant_fee_to_miner(MinerPubkey, Trees0, TotalFee) ->
    Trees1 = ensure_account(MinerPubkey, Trees0),
    AccountsTrees1 = accounts(Trees1),

    {value, Account1} = aec_accounts_trees:lookup(MinerPubkey, AccountsTrees1),
    {ok, Account} = aec_accounts:earn(Account1, TotalFee),

    AccountsTrees = aec_accounts_trees:enter(Account, AccountsTrees1),
    set_accounts(Trees1, AccountsTrees).

-spec ensure_account(pubkey(), trees()) -> trees().
ensure_account(AccountPubkey, Trees0) ->
    AccountsTrees0 = aec_trees:accounts(Trees0),
    case aec_accounts_trees:lookup(AccountPubkey, AccountsTrees0) of
        {value, _Account} ->
            Trees0;
        none ->
            %% Add newly referenced account (w/0 amount) to the state
            Account = aec_accounts:new(AccountPubkey, 0),
            AccountsTrees = aec_accounts_trees:enter(Account, AccountsTrees0),
            aec_trees:set_accounts(Trees0, AccountsTrees)
    end.
