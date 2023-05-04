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
    txHash: [TxHash];
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
    #GeneralAvailability;
  };
  public type InitArgs = {
    ecdsa_key_name : Text;
    retrieve_eth_min_amount : Wei;
    ledger_id : Principal;
    min_confirmations: ?Nat;
    mode : Mode;
  };

}