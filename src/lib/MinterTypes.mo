import ETHUtils "ETHUtils";

module {
  public type Account = { owner : Principal; subaccount : ?[Nat8] };
  public type AccountId = Blob;
  public type Address = Text;
  public type EthAddress = Text;
  public type EthAccount = [Nat8];
  public type EthTokenId = Blob;
  public type PubKey = [Nat8];
  public type DerivationPath = [Blob];
  public type TxHash = Text;
  public type Wei = Nat;
  public type Gwei = Nat;
  public type Ether = Nat;
  public type Hash = [Nat8];
  public type HexWith0x = Text;
  public type Nonce = Nat;
  public type Cycles = Nat;
  public type Timestamp = Nat; // seconds
  public type Sa = [Nat8];
  public type Txid = Blob;
  public type BlockHeight = Nat;
  public type TokenBlockHeight = Nat;
  public type TxIndex = Nat;
  public type RpcId = Nat;
  public type ListPage = Nat;
  public type ListSize = Nat;
  public type RpcLog = {time: Timestamp; input: Text; result: ?Text; err: ?Text };
  public type Transaction = ETHUtils.Transaction;
  public type Transaction1559 = ETHUtils.Transaction1559;
  public type RetrieveStatus = {
    account: Account;
    retrieveAccount: Account;
    burnedBlockIndex: TokenBlockHeight;
    ethAddress: EthAddress;
    amount: Wei; 
    txIndex: TxIndex;
  };
  public type TxStatus = {
    txType: {#Deposit; #Withdraw};
    tokenId: EthAddress;// ETH: 0x0000000000000000000000000000000000000000
    account: Account;
    from: EthAddress;
    to: EthAddress;
    amount: Wei;
    fee: { gasPrice: Wei; maxFee: Wei };
    nonce: ?Nonce;
    toids: [Nat];
    txHash: ?TxHash;
    tx: ?Transaction;
    rawTx: ?([Nat8], [Nat8]);
    signedTx: ?([Nat8], [Nat8]);
    receipt: ?Text;
    rpcId: ?RpcId;
    status: Status;
  };
  public type Status = {
    #Building;
    #Signing;
    #Sending;
    #Submitted;
    #Pending;
    #Failure;
    #Confirmed;
    #Unknown;
  };
  public type ResultError = {
    #GenericError : { message : Text; code : Nat64 };
  };
  public type DepositResult = { 
    blockIndex : Nat; 
    amount : Wei; // ETH
    txIndex: TxIndex;
    toid: Nat;
  };
  public type UpdateBalanceResult = { 
    blockIndex : Nat; 
    amount : Wei; // ckETH
    toid: Nat;
  };
  public type RetrieveResult = { 
    blockIndex : Nat; 
    amount : Wei; // ETH
    retrieveFee : Wei;
    txIndex: TxIndex;
    toid: Nat;
  };

  public type Event = {
    #init : InitArgs;
    // #received_utxos : { to_account : Account; utxos : [Utxo] };
    // #sent_transaction : {
    //   change_output : ?{ value : Nat64; vout : Nat32 };
    //   txid : [Nat8];
    //   utxos : [Utxo];
    //   requests : [Nat64]; // blockIndex
    //   submitted_at : Nat64; // txi
    // };
    // #upgrade : UpgradeArgs;
    // #accepted_retrieve_eth_request : {
    //   received_at : Nat64;
    //   block_index : Nat64;
    //   address : EthAddress;
    //   amount : Nat64;
    // };
    // #removed_retrieve_eth_request : { block_index : Nat64 };
    // #confirmed_transaction : { txid : [Nat8] };
  };
  public type Mode = {
    #ReadOnly;
    // #RestrictedTo : [Principal];
    #GeneralAvailability;
  };
  public type InitArgs = {
    ecdsa_key_name : Text;
    retrieve_eth_min_amount : Wei;
    ledger_id : Principal;
    min_confirmations: ?Nat;
    mode : Mode;
  };

  
  // public type RetrieveBtcArgs = { address : Text; amount : Nat64 };
  // public type RetrieveBtcError = {
  //   #MalformedAddress : Text;
  //   #GenericError : { error_message : Text; error_code : Nat64 };
  //   #TemporarilyUnavailable : Text;
  //   #AlreadyProcessing;
  //   #AmountTooLow : Nat64;
  //   #InsufficientFunds : { balance : Nat64 };
  // };
  // public type RetrieveBtcOk = { block_index : Nat64 };
  // // public type RetrieveBtcStatus = {
  // //   #Signing;
  // //   #Confirmed : { txid : [Nat8] };
  // //   #Sending : { txid : [Nat8] };
  // //   #AmountTooLow;
  // //   #Unknown;
  // //   #Submitted : { txid : [Nat8] };
  // //   #Pending;
  // // };
  // public type UpdateBalanceError = {
  //   #GenericError : { error_message : Text; error_code : Nat64 };
  //   #TemporarilyUnavailable : Text;
  //   #AlreadyProcessing;
  //   #NoNewUtxos;
  // };
  // public type UpdateBalanceResult = { block_index : Nat64; amount : Nat64 };
  // public type ICUtxo = ICBTC.Utxo; // Minter.Utxo?
  // public type Utxo = {
  //   height : Nat32;
  //   value : Nat64; // Satoshi
  //   outpoint : { txid : [Nat8]; vout : Nat32 }; // txid: Blob
  // };
  // // public type PubKey = [Nat8];
  // // public type DerivationPath = [Blob];
  // public type VaultUtxo = (Address, PubKey, DerivationPath, ICUtxo);
  // public type RetrieveStatus = {
  //   account: Account;
  //   retrieveAccount: Account;
  //   burnedBlockIndex: Nat;
  //   btcAddress: Address;
  //   amount: Nat64; // Satoshi
  //   txIndex: Nat;
  // };
  // public type SendingBtcStatus = {
  //   destinations: [(Nat64, Address, Nat64)];
  //   totalAmount: Nat64;
  //   utxos: [VaultUtxo];
  //   scriptSigs: [Script.Script];
  //   fee: Nat64;
  //   toids: [Nat];
  //   signedTx: ?[Nat8];
  //   status: RetrieveBtcStatus;
  // };
  // public type Self = actor {
  //   get_btc_address : shared { subaccount : ?[Nat8] } -> async Text;
  //   get_events : shared query { start : Nat64; length : Nat64 } -> async [
  //       Event
  //     ];
  //   get_withdrawal_account : shared () -> async Account;
  //   retrieve_btc : shared RetrieveBtcArgs -> async {
  //       #Ok : RetrieveBtcOk;
  //       #Err : RetrieveBtcError;
  //     };
  //   retrieve_btc_status : shared query {
  //       block_index : Nat64;
  //     } -> async RetrieveBtcStatus;
  //   update_balance : shared { subaccount : ?[Nat8] } -> async {
  //       #Ok : UpdateBalanceResult;
  //       #Err : UpdateBalanceError;
  //     };
  // }
}