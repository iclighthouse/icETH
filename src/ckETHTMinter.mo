/**
 * Module     : ckETH Minter
 * Author     : ICLighthouse Team
 * Stability  : Experimental
 * Github     : https://github.com/iclighthouse/
 */

import Trie "./lib/icl/Elastic-Trie";
import Principal "mo:base/Principal";
import Array "mo:base/Array";
import Option "mo:base/Option";
import Blob "mo:base/Blob";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Nat32 "mo:base/Nat32";
import Nat64 "mo:base/Nat64";
import Int "mo:base/Int";
import Int32 "mo:base/Int32";
import Int64 "mo:base/Int64";
import Float "mo:base/Float";
import Iter "mo:base/Iter";
import List "mo:base/List";
import Time "mo:base/Time";
import Text "mo:base/Text";
import Deque "mo:base/Deque";
import Order "mo:base/Order";
import Cycles "mo:base/ExperimentalCycles";
import ICRC1 "./lib/icl/ICRC1";
import Binary "./lib/icl/Binary";
import Hex "./lib/icl/Hex";
import Tools "./lib/icl/Tools";
import SagaTM "./ICTC/SagaTM";
import DRC207 "./lib/icl/DRC207";
import Error "mo:base/Error";
import Debug "mo:base/Debug";
import Result "mo:base/Result";
import ICECDSA "lib/ICECDSA";
import Minter "lib/MinterTypes";
import ETHUtils "lib/ETHUtils";
import ETHRPC "lib/ETHRPC";
import ABI "lib/ABI";
import JSON "lib/JSON";
import Timer "mo:base/Timer";

// Rules:
//      When depositing ETH, each account is processed in its own single thread.
// InitArgs = {
//     ecdsa_key_name : Text; // key_1
//     retrieve_eth_min_amount : Wei; // 0.01 eth = 10000000000000000 Wei
//     ledger_id : Principal; // pf6mc-7yaaa-aaaak-aejiq-cai (test)
//     min_confirmations : ?Nat
//     mode: Mode;
//   };
// record{ecdsa_key_name="key_1";retrieve_eth_min_amount=10000000000000000;ledger_id=principal "pf6mc-7yaaa-aaaak-aejiq-cai"; min_confirmations=opt 15; mode=variant{GeneralAvailability}}
shared(installMsg) actor class icETHMinter(initArgs: Minter.InitArgs) = this {
    assert(initArgs.ecdsa_key_name == "key_1"); /*config*/
    assert(Option.get(initArgs.min_confirmations, 0) >= 5); /*config*/

    type Cycles = Minter.Cycles;
    type Timestamp = Minter.Timestamp; // Nat, seconds
    type Sa = Minter.Sa; // [Nat8]
    type Txid = Minter.Txid; // blob
    type BlockHeight = Minter.BlockHeight; //Nat
    type TokenBlockHeight = Minter.TokenBlockHeight; //Nat
    type TxIndex = Minter.TxIndex; //Nat
    type TxHash = Minter.TxHash;
    type RpcId = Minter.RpcId; //Nat
    type ListPage = Minter.ListPage;
    type ListSize = Minter.ListSize;
    type Wei = Minter.Wei;
    type Gwei = Minter.Gwei; // 10**9
    type Ether = Minter.Ether; // 10**18

    type Account = Minter.Account;
    type AccountId = Minter.AccountId;
    type Address = Minter.Address;
    type EthAddress = Minter.EthAddress;
    type EthAccount = Minter.EthAccount;
    type EthTokenId = Minter.EthTokenId;
    type PubKey = Minter.PubKey;
    type DerivationPath = Minter.DerivationPath;
    type Hash = Minter.Hash;
    type Nonce = Minter.Nonce;
    type HexWith0x = Minter.HexWith0x;
    type Transaction = Minter.Transaction;
    type Transaction1559 = Minter.Transaction1559;
    type Status = Minter.Status;
    type Event = Minter.Event;
    type RpcLog = Minter.RpcLog;
    type TrieList<K, V> = {data: [(K, V)]; total: Nat; totalPage: Nat; };

    let KEY_NAME : Text = initArgs.ecdsa_key_name;
    let MIN_CONFIRMATIONS : Nat = Option.get(initArgs.min_confirmations, 15);
    let ETH_MIN_AMOUNT: Nat = initArgs.retrieve_eth_min_amount;
    let ECDSA_RPC_CYCLES : Cycles =  50_000_000_000;
    let ECDSA_SIGN_CYCLES : Cycles = 22_000_000_000;
    let RPC_AGENT_CYCLES : Cycles = 0;
    let ICTC_RUN_INTERVAL : Nat = 10;
    let MIN_VISIT_INTERVAL : Nat = 6; //seconds
    let PRIORITY_FEE_PER_GAS : Nat = 3000000000; // 3Gwei
    let GAS_PER_BYTE : Nat = 68; // gas
    let BLOCK_SLOTS: Nat = 15; // seconds
    
    private var app_debug : Bool = true; /*config*/
    private let version_: Text = "0.1"; /*config*/
    private let ns_: Nat = 1000000000;
    private let gwei_: Nat = 1000000000;
    private let ckethFee_: Nat = 100;
    private var pause: Bool = initArgs.mode == #ReadOnly;
    private stable var owner: Principal = installMsg.caller;
    private stable var ic_: Principal = Principal.fromText("aaaaa-aa"); 
    private let ethToken: Text = "0x0000000000000000000000000000000000000000";
    private let rpc_: Principal = Principal.fromText("szniw-ryaaa-aaaak-aelmq-cai"); //3ondx-siaaa-aaaam-abf3q-cai
    private let utils_: Principal = Principal.fromText("s6moc-4aaaa-aaaak-aelma-cai"); 
    private stable var ckETH_: Principal = initArgs.ledger_id; 
    if (app_debug){
        ckETH_ := Principal.fromText("pf6mc-7yaaa-aaaak-aejiq-cai");
    };
    private let ic : ICECDSA.Self = actor(Principal.toText(ic_));
    private let ckETH : ICRC1.Self = actor(Principal.toText(ckETH_));
    private let rpc : ETHRPC.Self = actor(Principal.toText(rpc_));
    private let utils : ETHUtils.Self = actor(Principal.toText(utils_));
    private stable var ethBlockNumber: (blockheight: BlockHeight, time: Timestamp) = (0, 0); 
    private stable var gasPrice: Wei = 5000000000; // Wei
    private stable var lastGetGasPriceTime: Timestamp = 0;
    private var getGasPriceIntervalSeconds: Timestamp = 20 * 60;
    private stable var ethGasLimit: Nat = 21000;  
    private stable var erc20GasLimit: Nat = 66000;
    private stable var lastUpdateFeeTime : Time.Time = 0;
    private stable var countRejections: Nat = 0;
    private stable var lastExecutionDuration: Int = 0;
    private stable var maxExecutionDuration: Int = 0;
    private stable var lastSagaRunningTime : Time.Time = 0;
    private stable var countAsyncMessage : Nat = 0;

    private stable var blockIndex : BlockHeight = 0;
    private stable var totalFee = Trie.empty<EthTokenId, Wei>();
    // private stable var totalReceived: Wei = 0;
    // private stable var totalSent: Wei = 0;
    private stable var latestVisitTime = Trie.empty<Principal, Timestamp>(); 
    private stable var accounts = Trie.empty<AccountId, (EthAddress, Nonce)>(); 
    private stable var deposits = Trie.empty<AccountId, TxIndex>();
    private stable var balances: Trie.Trie2D<AccountId, EthTokenId, Wei> = Trie.empty();  //Wei
    private stable var retrievals = Trie.empty<TxIndex, Minter.RetrieveStatus>();  //Wei
    private stable var withdrawals = Trie.empty<AccountId, List.List<TxIndex>>(); // 
    private stable var retrievalPendings = List.nil<TxIndex>();
    private stable var transactions = Trie.empty<TxIndex, (tx: Minter.TxStatus, updatedTime: Timestamp)>();   //Wei
    private stable var rpcId: RpcId = 0;
    private stable var rpcLogs = Trie.empty<RpcId, RpcLog>();  
    private stable var txIndex : TxIndex = 0;
    private stable var lastTxTime : Time.Time = 0;
    private stable var blockEvents = Trie.empty<BlockHeight, Event>(); 
    private stable var chainId : Nat = 1; 
    private stable var rpcUrl: Text = "";
    private stable var lastUpdateTxsTime: Timestamp = 0;

    private func keyb(t: Blob) : Trie.Key<Blob> { return { key = t; hash = Blob.hash(t) }; };
    private func keyt(t: Text) : Trie.Key<Text> { return { key = t; hash = Text.hash(t) }; };
    private func keyp(t: Principal) : Trie.Key<Principal> { return { key = t; hash = Principal.hash(t) }; };
    private func keyn(t: Nat) : Trie.Key<Nat> { return { key = t; hash = Tools.natHash(t) }; };
    private func trieItems<K, V>(_trie: Trie.Trie<K,V>, _page: ListPage, _size: ListSize) : TrieList<K, V> {
        let length = Trie.size(_trie);
        if (_page < 1 or _size < 1){
            return {data = []; totalPage = 0; total = length; };
        };
        let offset = Nat.sub(_page, 1) * _size;
        var totalPage: Nat = length / _size;
        if (totalPage * _size < length) { totalPage += 1; };
        if (offset >= length){
            return {data = []; totalPage = totalPage; total = length; };
        };
        let end: Nat = offset + Nat.sub(_size, 1);
        var i: Nat = 0;
        var res: [(K, V)] = [];
        for ((k,v) in Trie.iter<K, V>(_trie)){
            if (i >= offset and i <= end){
                res := Tools.arrayAppend(res, [(k,v)]);
            };
            i += 1;
        };
        return {data = res; totalPage = totalPage; total = length; };
    };

    private func _getEvent(_blockIndex: BlockHeight) : ?Event{
        switch(Trie.get(blockEvents, keyn(_blockIndex), Nat.equal)){
            case(?(event)){ return ?event };
            case(_){ return null };
        };
    };
    private func _getEvents(_start : BlockHeight, _length : Nat) : [Event]{
        assert(_length > 0);
        var events : [Event] = [];
        for (index in Iter.range(_start, _start + _length - 1)){
            switch(Trie.get(blockEvents, keyn(index), Nat.equal)){
                case(?(event)){ events := Tools.arrayAppend([event], events)};
                case(_){};
            };
        };
        return events;
    };
    private func _getLatestVisitTime(_owner: Principal) : Timestamp{
        switch(Trie.get(latestVisitTime, keyp(_owner), Principal.equal)){
            case(?(v)){ return v };
            case(_){ return 0 };
        };
    };
    private func _setLatestVisitTime(_owner: Principal) : (){
        latestVisitTime := Trie.put(latestVisitTime, keyp(_owner), Principal.equal, _now()).0;
        latestVisitTime := Trie.filter(latestVisitTime, func (k: Principal, v: Timestamp): Bool{ 
            _now() < v + 24*3600
        });
    };

    private func _now() : Timestamp{
        return Int.abs(Time.now() / ns_);
    };
    private func _asyncMessageSize() : Nat{
        return countAsyncMessage + _getSaga().asyncMessageSize();
    };
    private func _checkAsyncMessageLimit() : Bool{
        return _asyncMessageSize() < 400; /*config*/
    };
    
    private func _toSaBlob(_sa: ?Sa) : ?Blob{
        switch(_sa){
            case(?(sa)){ return ?Blob.fromArray(sa); };
            case(_){ return null; };
        }
    };
    private func _toSaNat8(_sa: ?Blob) : ?[Nat8]{
        switch(_sa){
            case(?(sa)){ return ?Blob.toArray(sa); };
            case(_){ return null; };
        }
    };
    private func _toOptSub(_sub: Blob) : ?Blob{
        if (Blob.toArray(_sub).size() == 0){
            return null;
        }else{
            return ?_sub;
        };
    };
    private func _natToFloat(_n: Nat) : Float{
        let n: Int = _n;
        return Float.fromInt(n);
    };
    private func _onlyOwner(_caller: Principal) : Bool { //ict
        return _caller == owner;
    }; 
    private func _notPaused() : Bool { 
        return not(pause);
    };
    private func _accountId(_owner: Principal, _subaccount: ?[Nat8]) : Blob{
        return Blob.fromArray(Tools.principalToAccount(_owner, _subaccount));
    };
    private func _getAccountId(_address: Address): AccountId{
        switch (Tools.accountHexToAccountBlob(_address)){
            case(?(a)){
                return a;
            };
            case(_){
                var p = Principal.fromText(_address);
                var a = Tools.principalToAccountBlob(p, null);
                return a;
                // switch(Tools.accountDecode(Principal.toBlob(p))){
                //     case(#ICRC1Account(account)){
                //         switch(account.subaccount){
                //             case(?(sa)){ return Tools.principalToAccountBlob(account.owner, ?Blob.toArray(sa)); };
                //             case(_){ return Tools.principalToAccountBlob(account.owner, null); };
                //         };
                //     };
                //     case(#AccountId(account)){ return account; };
                //     case(#Other(account)){ return account; };
                // };
            };
        };
    }; 

    // Local tasks
    private func _local_getNonce(_txi: TxIndex, _toids: ?[Nat]) : async* {txi: Nat; address: EthAddress; nonce: Nonce}{
        //let txiBlob = Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(_txi))); 
        switch(Trie.get(transactions, keyn(_txi), Nat.equal)){
            case(?(tx, ts)){
                if (tx.status == #Building){
                    var accountId = _accountId(tx.account.owner, tx.account.subaccount);
                    var nonce : Nat = 0;
                    if (tx.txType == #Withdraw){ 
                        accountId := _accountId(Principal.fromActor(this), null);
                        let (mainAddress, mainNonce) = _getEthAddressQuery(accountId);
                        nonce := mainNonce;
                    }else{
                        nonce := await* _fetchAccountNonce(tx.from, false);
                    };
                    _setEthAccount(accountId, tx.from, nonce + 1);
                    _updateTx(_txi, {
                        fee = null;
                        amount = null;
                        nonce = ?nonce;
                        toids = _toids;
                        txHash = null;
                        tx = null;
                        rawTx = null;
                        signedTx = null;
                        receipt = null;
                        rpcId = null;
                        status = null;
                        ts = null;
                    });
                    return {txi = _txi; address = tx.from; nonce = nonce};
                }else{
                    throw Error.reject("402: The status of transaction is not #Building!");
                };
            };
            case(_){ throw Error.reject("402: The transaction record does not exist!"); };
        };
    };
    private func _local_createTx(_txi: TxIndex) : async* {txi: Nat; rawTx: [Nat8]; txHash: TxHash}{
        //let txiBlob = Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(_txi))); 
        switch(Trie.get(transactions, keyn(_txi), Nat.equal)){
            case(?(tx, ts)){
                if (tx.status == #Building){
                    var chainId_ = chainId;
                    if (testMainnet){
                        chainId_ := 1;
                    };
                    let accountId = _accountId(tx.account.owner, tx.account.subaccount);
                    let isERC20 = tx.tokenId != ethToken;
                    let txObj: Transaction = #EIP1559({
                        to = Option.get(ABI.fromHex(tx.to), []);
                        value = ABI.fromNat(tx.amount);
                        max_priority_fee_per_gas = ABI.fromNat(PRIORITY_FEE_PER_GAS); 
                        data = [];
                        sign = null;
                        max_fee_per_gas = ABI.fromNat(tx.fee.gasPrice);
                        chain_id = Nat64.fromNat(chainId_);
                        nonce = ABI.fromNat(Option.get(tx.nonce, 0));
                        gas_limit = ABI.fromNat(_getGasLimit(isERC20));
                        access_list = [];
                    });
                    try{
                        countAsyncMessage += 1;
                        switch(await utils.create_transaction(txObj)){
                            case(#Ok(rawTx, txHash)){
                                countAsyncMessage -= Nat.min(1, countAsyncMessage);
                                _updateTx(_txi, {
                                    fee = null;
                                    amount = null;
                                    nonce = null;
                                    toids = null;
                                    txHash = null; // ?ABI.toHex(txHash);
                                    tx = ?txObj;
                                    rawTx = ?(rawTx, txHash);
                                    signedTx = null;
                                    receipt = null;
                                    rpcId = null;
                                    status = ?#Signing;
                                    ts = null;
                                });
                                return {txi = _txi; rawTx = rawTx; txHash = ABI.toHex(txHash)};
                            };
                            case(#Err(e)){
                                throw Error.reject("401: Error: "#e);
                            };
                        };
                    }catch(e){
                        countAsyncMessage -= Nat.min(1, countAsyncMessage);
                        throw Error.reject("Calling error: "# Error.message(e)); 
                    };
                }else{
                    throw Error.reject("402: The status of transaction is not #Building!");
                };
            };
            case(_){ throw Error.reject("402: The transaction record does not exist!"); };
        };
    };
    private func _local_createTx_comp(_txi: TxIndex) : async* (){
        //let txiBlob = Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(_txi))); 
        switch(Trie.get(transactions, keyn(_txi), Nat.equal)){
            case(?(tx, ts)){
                if (tx.status == #Signing){
                    _updateTx(_txi, {
                        fee = null;
                        amount = null;
                        nonce = null;
                        toids = null;
                        txHash = null;
                        tx = null;
                        rawTx = null;
                        signedTx = null;
                        receipt = null;
                        rpcId = null;
                        status = ?#Building;
                        ts = null;
                    });
                }else{
                    throw Error.reject("402: The status of transaction is not #Signing!");
                };
            };
            case(_){ throw Error.reject("402: The transaction record does not exist!"); };
        };
    };
    private func _local_signTx(_txi: TxIndex) : async* {txi: Nat; signature: Blob; rawTx: [Nat8]; txHash: TxHash}{
        //let txiBlob = Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(_txi))); 
        //_sign(_dpath: DerivationPath, message_hash : Blob)
        switch(Trie.get(transactions, keyn(_txi), Nat.equal)){
            case(?(tx, ts)){
                if (tx.status == #Signing or tx.status == #Sending or tx.status == #Pending){
                    let accountId = _accountId(tx.account.owner, tx.account.subaccount);
                    var dpath = [accountId];
                    if (tx.txType == #Withdraw){ dpath := [_accountId(Principal.fromActor(this), null)] };
                    switch(tx.tx, tx.rawTx){
                        case(?#EIP1559(txObj), ?(raw, hash)){
                            let signature = await* _sign(dpath, Blob.fromArray(hash));
                            let signValues = await* _convertSignature(Blob.toArray(signature), raw, tx.from);
                            let txObjNew: Transaction = #EIP1559({
                                to = txObj.to;
                                value = txObj.value;
                                max_priority_fee_per_gas = txObj.max_priority_fee_per_gas; 
                                data = txObj.data;
                                sign = ?{r = signValues.r; s = signValues.s; v = signValues.v; from = ABI.fromHex(tx.from); hash = hash };
                                max_fee_per_gas = txObj.max_fee_per_gas;
                                chain_id = txObj.chain_id;
                                nonce = txObj.nonce;
                                gas_limit = txObj.gas_limit;
                                access_list = txObj.access_list;
                            });
                            // 0x2 || RLP([chainId, nonce, maxPriorityFeePerGas, maxFeePerGas, gasLimit, to, value, data, accessList, signatureYParity, signatureR, signatureS])
                            // switch(await utils.create_transaction(txObjNew)){
                            //     case(#Ok(rawTx, txHash)){
                                    let signedTx = await* _rlpEncode(txObjNew);
                                    var signedHash : [Nat8] = []; 
                                    try{
                                        countAsyncMessage += 1;
                                        signedHash := await utils.keccak256(signedTx);
                                        countAsyncMessage -= Nat.min(1, countAsyncMessage);
                                    }catch(e){
                                        countAsyncMessage -= Nat.min(1, countAsyncMessage);
                                        throw Error.reject("Calling error: "# Error.message(e)); 
                                    };
                                    _updateTx(_txi, {
                                        fee = null;
                                        amount = null;
                                        nonce = null;
                                        toids = null;
                                        txHash = ?ABI.toHex(signedHash);
                                        tx = ?txObjNew;
                                        rawTx = null;
                                        signedTx = ?(signedTx, signedHash);
                                        receipt = null;
                                        rpcId = null;
                                        status = ?#Sending;
                                        ts = null;
                                    });
                                    return {txi = _txi; signature = signature; rawTx = signedTx; txHash = ABI.toHex(signedHash)};
                                // };
                                // case(#Err(e)){
                                //     throw Error.reject("401: Error: "#e);
                                // };
                            // };
                        };
                        case(_, _){
                            throw Error.reject("402: There is no tx or tx hash!");
                        };
                    };
                }else{
                    throw Error.reject("402: The status of transaction is not #Signing!");
                };
            };
            case(_){ throw Error.reject("402: The transaction record does not exist!"); };
        };
    };
    private func _local_sendTx(_txi: TxIndex) : async* {txi: Nat; result: Result.Result<TxHash, Text>; rpcId: RpcId}{
        //let txiBlob = Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(_txi))); 
        switch(Trie.get(transactions, keyn(_txi), Nat.equal)){
            case(?(tx, ts)){
                if (tx.status == #Sending){
                    let accountId = _accountId(tx.account.owner, tx.account.subaccount);
                    switch(tx.signedTx){
                        case(?(raw, hash)){
                            switch(await* _sendRawTx(raw)){
                                case((rpcId, #ok(txid))){
                                    _updateTx(_txi, {
                                        fee = null;
                                        amount = null;
                                        nonce = null;
                                        toids = null;
                                        txHash = null;
                                        tx = null;
                                        rawTx = null;
                                        signedTx = null;
                                        receipt = null;
                                        rpcId = ?rpcId;
                                        status = ?#Submitted;
                                        ts = null;
                                    });
                                    return {txi = _txi; result = #ok(txid); rpcId = rpcId};
                                };
                                case((rpcId, #err(e))){
                                    // _updateTx(_txi, {
                                    //     fee = null;
                                    //     amount = null;
                                    //     nonce = null;
                                    //     toids = null;
                                    //     txHash = null;
                                    //     tx = null;
                                    //     rawTx = null;
                                    //     signedTx = null;
                                    //     receipt = null;
                                    //     rpcId = ?rpcId;
                                    //     status = null;
                                    //     ts = null;
                                    // });
                                    // throw Error.reject("402: (rpcId="# Nat.toText(rpcId) #")" # e);
                                    _updateTx(_txi, {
                                        fee = null;
                                        amount = null;
                                        nonce = null;
                                        toids = null;
                                        txHash = null;
                                        tx = null;
                                        rawTx = null;
                                        signedTx = null;
                                        receipt = null;
                                        rpcId = ?rpcId;
                                        status = ?#Submitted;
                                        ts = null;
                                    });
                                    return {txi = _txi; result = #err(e); rpcId = rpcId};
                                };
                            };
                        };
                        case(_){
                            throw Error.reject("402: The transaction raw does not exist!");
                        };
                    };
                }else{
                    throw Error.reject("402: The status of transaction is not #Building!");
                };
            };
            case(_){ throw Error.reject("402: The transaction record does not exist!"); };
        };
    };
    
    // Local task entrance
    private func _local(_args: SagaTM.CallType, _receipt: ?SagaTM.Receipt) : async (SagaTM.TaskResult){
        switch(_args){
            case(#This(method)){
                switch(method){
                    case(#getNonce(_txi, _toids)){
                        let result = await* _local_getNonce(_txi, _toids);
                        return (#Done, ?#This(#getNonce(result)), null);
                    };
                    case(#createTx(_txi)){
                        let result = await* _local_createTx(_txi);
                        return (#Done, ?#This(#createTx(result)), null);
                    };case(#createTx_comp(_txi)){
                        let result = await* _local_createTx_comp(_txi);
                        return (#Done, ?#This(#createTx_comp(result)), null);
                    };
                    case(#signTx(_txi)){
                        let result = await* _local_signTx(_txi);
                        return (#Done, ?#This(#signTx(result)), null);
                    };
                    case(#sendTx(_txi)){
                        let result = await* _local_sendTx(_txi);
                        return (#Done, ?#This(#sendTx(result)), null);
                    };
                    //case(_){return (#Error, null, ?{code=#future(9901); message="Non-local function."; });};
                };
            };
            case(_){ return (#Error, null, ?{code=#future(9901); message="Non-local function."; });};
        };
    };
    // Task callback
    // private func _taskCallback(_toName: Text, _ttid: SagaTM.Ttid, _task: SagaTM.Task, _result: SagaTM.TaskResult) : (){
    //     //taskLogs := Tools.arrayAppend(taskLogs, [(_ttid, _task, _result)]);
    // };
    // // Order callback
    // private func _orderCallback(_toName: Text, _toid: SagaTM.Toid, _status: SagaTM.OrderStatus, _data: ?Blob) : (){
    //     //orderLogs := Tools.arrayAppend(orderLogs, [(_toid, _status)]);
    // };
    // Create saga object
    private var saga: ?SagaTM.SagaTM = null;
    private func _getSaga() : SagaTM.SagaTM {
        switch(saga){
            case(?(_saga)){ return _saga };
            case(_){
                let _saga = SagaTM.SagaTM(Principal.fromActor(this), ?_local, null, null); //?_taskCallback, ?_orderCallback
                saga := ?_saga;
                return _saga;
            };
        };
    };
    private func _ictcSagaRun(_toid: Nat, _forced: Bool): async* (){
        if (_forced or _checkAsyncMessageLimit() ){ 
            lastSagaRunningTime := Time.now();
            let saga = _getSaga();
            if (_toid == 0){
                try{
                    countAsyncMessage += 1;
                    let sagaRes = await* saga.getActuator().run();
                    countAsyncMessage -= Nat.min(1, countAsyncMessage);
                }catch(e){
                    countAsyncMessage -= Nat.min(1, countAsyncMessage);
                    throw Error.reject("430: ICTC error: "# Error.message(e)); 
                };
            }else{
                try{
                    countAsyncMessage += 2;
                    let sagaRes = await saga.run(_toid);
                    countAsyncMessage -= Nat.min(2, countAsyncMessage);
                }catch(e){
                    countAsyncMessage -= Nat.min(2, countAsyncMessage);
                    throw Error.reject("430: ICTC error: "# Error.message(e)); 
                };
            };
        };
    };
    private func _buildTask(_data: ?Blob, _callee: Principal, _callType: SagaTM.CallType, _preTtid: [SagaTM.Ttid], _cycles: Nat) : SagaTM.PushTaskRequest{
        return {
            callee = _callee;
            callType = _callType;
            preTtid = _preTtid;
            attemptsMax = ?3;
            recallInterval = ?200000000; // nanoseconds
            cycles = _cycles;
            data = _data;
        };
    };

    private func _convertSignature(_sign: [Nat8], msg: [Nat8], signer: EthAddress) : async* {r: [Nat8]; s: [Nat8]; v: Nat64}{
        let r = Tools.slice(_sign, 0, ?31);
        let s = Tools.slice(_sign, 32, ?63);
        var v : Nat64 = 0;
        if (_sign.size() == 65){
            v := Nat64.fromNat(ABI.toNat(ABI.toBytes32(Tools.slice(_sign, 64, null))));
        }else{
            v := await* _v(_sign, 0, msg, signer);
        };
        //if (n <= 1){ v += 27; };
        return {r = r; s = s; v = v; };
    };
    private func _sign(_dpath: DerivationPath, message_hash : Blob) : async* Blob {
        Cycles.add(ECDSA_SIGN_CYCLES);
        let res = await ic.sign_with_ecdsa({
            message_hash = message_hash;
            derivation_path = _dpath;
            key_id = { curve = #secp256k1; name = KEY_NAME; };
        });
        res.signature
    };
    private func _v(signature: [Nat8], v: Nat8, msg: [Nat8], signer: EthAddress) : async* Nat64{
        switch(await utils.is_valid_signature(Tools.arrayAppend(signature, [v]))){
            case(#Ok){
                switch(await utils.recover_public_key(Tools.arrayAppend(signature, [v]), msg)){
                    case(#Ok(pubKey)){ 
                        switch(await utils.pub_to_address(pubKey)){
                            case(#Ok(address)){
                                if (ABI.toHex(address) == signer){
                                    return Nat64.fromNat(Nat8.toNat(v)); 
                                }else if (v < 1){
                                    return await* _v(signature, v+1, msg, signer);
                                }else{
                                    throw Error.reject("Mismatched signature or wrong v-value"); 
                                };
                            };
                            case(#Err(e)){
                                throw Error.reject(e); 
                            };
                        };
                    };
                    case(#Err(e)){ throw Error.reject(e); };
                };
            };
            case(#Err(e)){
                throw Error.reject(e); 
            };
        };  
    };
    private func _rlpEncode(_tx: Transaction) : async* [Nat8]{
        switch(_tx){
            case(#EIP1559(_tx1559)){
                if (_tx1559.access_list.size() > 0){
                    throw Error.reject("Only supports transactions with an empty access_list!");
                };
                var values: [ETHUtils.Item] = [
                    #Num(_tx1559.chain_id),
                    #Raw(ABI.shrink(_tx1559.nonce)),
                    #Raw(ABI.shrink(_tx1559.max_priority_fee_per_gas)),
                    #Raw(ABI.shrink(_tx1559.max_fee_per_gas)),
                    #Raw(ABI.shrink(_tx1559.gas_limit)),
                    #Raw(_tx1559.to),
                    #Raw(ABI.shrink(_tx1559.value)),
                    #Raw(_tx1559.data),
                    #List({ values = [] })
                ];
                switch(_tx1559.sign){
                    case(?signature){
                        values := Tools.arrayAppend(values, [
                            #Num(signature.v),
                            #Raw(signature.r),
                            #Raw(signature.s),
                        ]);
                    };
                    case(_){};
                };
                switch(await utils.rlp_encode({values = values})){
                    case(#Ok(data)){
                        return Tools.arrayAppend([2:Nat8], data);
                    };
                    case(#Err(e)){
                        throw Error.reject(e);
                    };
                };
            };
            case(_){
                throw Error.reject("Only supports EIP1559 transactions!");
            };
        };
    };
    private func _getStringFromJson(json: Text, key: Text) : ?Text{ // key: "aaa/bbb"
        let keys = Iter.toArray(Text.split(key, #char('/')));
        switch(JSON.parse(json)){
            case(?(#Object(obj))){
                if (keys.size() > 0){
                    for ((k, v) in obj.vals()){
                        if ( k == keys[0]){
                            var keys2: [Text] = [];
                            for (x in keys.keys()){
                                if (x > 0){
                                    keys2 := Tools.arrayAppend(keys2, [keys[x]]);
                                };
                            };
                            let res = _getStringFromJson(JSON.show(v), Text.join("/", keys2.vals()));
                            return res;
                        };
                    };
                };
            };
            case(?(#String(str))){
                return ?str;
            };
            case(?(#Null)){
                return ?"";
            };
            case(_){};
        };
        return null;
    };
    private func _getBytesFromJson(json: Text, key: Text) : ?[Nat8]{ // key: "aaa/bbb"
        let keys = Iter.toArray(Text.split(key, #char('/')));
        switch(JSON.parse(json)){
            case(?(#Object(obj))){
                if (keys.size() > 0){
                    for ((k, v) in obj.vals()){
                        if ( k == keys[0]){
                            var keys2: [Text] = [];
                            for (x in keys.keys()){
                                if (x > 0){
                                    keys2 := Tools.arrayAppend(keys2, [keys[x]]);
                                };
                            };
                            let res = _getBytesFromJson(JSON.show(v), Text.join("/", keys2.vals()));
                            return res;
                        };
                    };
                };
            };
            case(?(#String(str))){
                return ABI.fromHex(str);
            };
            case(?(#Null)){
                return ?[];
            };
            case(_){};
        };
        return null;
    };
    private func _getValueFromJson(json: Text, key: Text) : ?Nat{
        switch(_getBytesFromJson(json, key)){
            case(?(bytes)){
                return ?ABI.toNat(ABI.toBytes32(bytes));
            };
            case(_){};
        };
        return null;
    };

    private func _setEthAccount(_a: AccountId, _ethaccount: EthAddress, _nonce: Nonce) : (){
        accounts := Trie.put(accounts, keyb(_a), Blob.equal, (_ethaccount, _nonce)).0;
    };
    private func _addEthNonce(_a: AccountId): (){
        switch(Trie.get(accounts, keyb(_a), Blob.equal)){
            case(?(account, nonce)){ 
                accounts := Trie.put(accounts, keyb(_a), Blob.equal, (account, nonce + 1)).0; 
            };
            case(_){};
        };
    };
    private func _setEthNonce(_a: AccountId, _nonce: Nonce): (){
        switch(Trie.get(accounts, keyb(_a), Blob.equal)){
            case(?(account, nonce)){ 
                accounts := Trie.put(accounts, keyb(_a), Blob.equal, (account, _nonce)).0; 
            };
            case(_){};
        };
    };
    private func _getEthNonce(_a: AccountId): Nonce{
        switch(Trie.get(accounts, keyb(_a), Blob.equal)){
            case(?(account, nonce)){ return nonce; };
            case(_){ return 0; };
        };
    };
    private func _getRpcUrl() : Text{
        if (testMainnet){
            return "https://eth-mainnet.g.alchemy.com/v2/3rh5DTcZ97IcSwS-BthnbCWwjLactENf";
        }else{
            return rpcUrl;
        };
    };
    private func _getBlockNumber() : Nat{
        return ethBlockNumber.0 + (_now() - ethBlockNumber.1) / BLOCK_SLOTS;
    };
    private func _getEthAddressQuery(_a: AccountId) : (EthAddress, Nonce){
        var address: EthAddress = "";
        var nonce: Nonce = 0;
        switch(Trie.get(accounts, keyb(_a), Blob.equal)){
            case(?(account_, nonce_)){
                address := account_;
                nonce := nonce_;
            };
            case(_){};
        };
        return (address, nonce);
    };
    private func _getEthAddress(_a: AccountId, _updateNonce: Bool) : async* (EthAddress, Nonce){
        var address: EthAddress = "";
        var nonce: Nonce = 0;
        switch(Trie.get(accounts, keyb(_a), Blob.equal)){
            case(?(account_, nonce_)){
                address := account_;
                nonce := nonce_;
                if (_updateNonce){
                    let nonceNew = await* _fetchAccountNonce(address, false);
                    _setEthAccount(_a, address, nonceNew);
                    nonce := nonceNew;
                };
            };
            case(_){
                let account = await* _fetchAccountAddress([_a]);
                if (account.1.size() > 0){
                    let nonceNew = await* _fetchAccountNonce(account.2, false);
                    _setEthAccount(_a, account.2, nonceNew);
                    address := account.2;
                    nonce := nonceNew;
                };
            };
        };
        assert(Text.size(address) == 42);
        return (address, nonce);
    };
    private func _getEthAccount(_address: EthAddress): EthAccount{
        switch(ABI.fromHex(_address)){
            case(?(a)){ a };
            case(_){ assert(false); [] };
        };
    };

    private func _getTotalFee(_tokenId: EthAddress) : (balance: Wei){
        let tokenId = Blob.fromArray(_getEthAccount(_tokenId));
        switch(Trie.get(totalFee, keyb(tokenId), Blob.equal)){
            case(?(v)){
                return v;
            };
            case(_){
                return 0;
            };
        };
    };
    private func _addTotalFee(_tokenId: EthAddress, _amount: Wei): (balance: Wei){
        var balance = _getTotalFee(_tokenId);
        balance += _amount;
        let tokenId = Blob.fromArray(_getEthAccount(_tokenId));
        if (_amount > 0){
            totalFee := Trie.put(totalFee, keyb(tokenId), Blob.equal, balance).0;
        };
        return balance;
    };
    private func _subTotalFee(_tokenId: EthAddress, _amount: Wei): (balance: Wei){
        var balance = _getTotalFee(_tokenId);
        balance -= _amount;
        let tokenId = Blob.fromArray(_getEthAccount(_tokenId));
        if (_amount > 0){
            totalFee := Trie.put(totalFee, keyb(tokenId), Blob.equal, balance).0;
        }else{
            totalFee := Trie.remove(totalFee, keyb(tokenId), Blob.equal).0;
        };
        return balance;
    };
    private func _getBalance(_a: AccountId, _tokenId: EthAddress) : (balance: Wei){
        let tokenId = Blob.fromArray(_getEthAccount(_tokenId));
        switch(Trie.get(balances, keyb(_a), Blob.equal)){
            case(?(trie)){
                switch(Trie.get(trie, keyb(tokenId), Blob.equal)){
                    case(?(v)){
                        return v;
                    };
                    case(_){
                        return 0;
                    };
                };
            };
            case(_){
                return 0;
            };
        };
    };
    private func _addBalance(_a: AccountId, _tokenId: EthAddress, _amount: Wei): (balance: Wei){
        let mainAccountId = _accountId(Principal.fromActor(this), null);
        //assert(_a != mainAccountId);
        var balance = _getBalance(_a, _tokenId);
        var balanceTotal = _getBalance(mainAccountId, _tokenId);
        balance += _amount;
        balanceTotal += _amount;
        let tokenId = Blob.fromArray(_getEthAccount(_tokenId));
        if (_amount > 0){
            balances := Trie.put2D(balances, keyb(_a), Blob.equal, keyb(tokenId), Blob.equal, balance);
            balances := Trie.put2D(balances, keyb(mainAccountId), Blob.equal, keyb(tokenId), Blob.equal, balanceTotal);
        };
        return balance;
    };
    private func _subBalance(_a: AccountId, _tokenId: EthAddress, _amount: Wei): (balance: Wei){
        let mainAccountId = _accountId(Principal.fromActor(this), null);
        //assert(_a != mainAccountId);
        var balance = _getBalance(_a, _tokenId);
        var balanceTotal = _getBalance(mainAccountId, _tokenId);
        balance -= _amount;
        balanceTotal -= _amount;
        let tokenId = Blob.fromArray(_getEthAccount(_tokenId));
        if (_amount > 0){
            balances := Trie.put2D(balances, keyb(_a), Blob.equal, keyb(tokenId), Blob.equal, balance);
            balances := Trie.put2D(balances, keyb(mainAccountId), Blob.equal, keyb(tokenId), Blob.equal, balanceTotal);
        }else{
            balances := Trie.remove2D(balances, keyb(_a), Blob.equal, keyb(tokenId), Blob.equal).0;
            balances := Trie.put2D(balances, keyb(mainAccountId), Blob.equal, keyb(tokenId), Blob.equal, balanceTotal);
        };
        return balance;
    };
    private func _getDepositingTxIndex(_a: AccountId) : ?TxIndex{
        switch(Trie.get(deposits, keyb(_a), Blob.equal)){
            case(?(ti)){ ?ti };
            case(_){ null };
        };
    };
    private func _putDepositingTxIndex(_a: AccountId, _txi: TxIndex) : (){
        deposits := Trie.put(deposits, keyb(_a), Blob.equal, _txi).0;
    };
    private func _removeDepositingTxIndex(_a: AccountId, _txIndex: TxIndex) : ?TxIndex{
        switch(Trie.get(deposits, keyb(_a), Blob.equal)){
            case(?(ti)){
                if (ti == _txIndex){
                    deposits := Trie.remove(deposits, keyb(_a), Blob.equal).0;
                    return ?ti;
                };
            };
            case(_){};
        };
        return null;
    };
    private func _putRetrievingTxIndex(_txi: TxIndex) : (){
        retrievalPendings := List.push(_txi, retrievalPendings);
    }; 
    private func _removeRetrievingTxIndex(_txi: TxIndex) : (){
        retrievalPendings := List.filter(retrievalPendings, func (t: TxIndex): Bool{ t != _txi });
    };
    private func _getEthFee(_isERC20: Bool) : { gasPrice: Wei; maxFee: Wei }{
        var maxFee: Wei = erc20GasLimit * (gasPrice + PRIORITY_FEE_PER_GAS);
        if (not _isERC20){
            maxFee := ethGasLimit * (gasPrice + PRIORITY_FEE_PER_GAS);
            if (testMainnet){
                maxFee := ethGasLimit * (55000000000 + PRIORITY_FEE_PER_GAS);
                return { gasPrice = 55000000000 + PRIORITY_FEE_PER_GAS; maxFee = maxFee };
            };
        };
        return { gasPrice = gasPrice + PRIORITY_FEE_PER_GAS; maxFee = maxFee };
    };
    private func _getGasLimit(_isERC20: Bool) : Nat{
        if (_isERC20){
            erc20GasLimit;
        }else{
            ethGasLimit;
        };
    };
    private func _getTx(_txi: TxIndex) : ?Minter.TxStatus{
        switch(Trie.get(transactions, keyn(_txi), Nat.equal)){
            case(?(tx, ts)){ return ?tx; };
            case(_){ return null; };
        };
    };
    private func _newTx(_type: {#Deposit; #Withdraw}, _account: Account, _tokenId: EthAddress, _from: EthAddress, _to: EthAddress, _amount: Wei) : TxIndex{
        let accountId = _accountId(_account.owner, _account.subaccount);
        let isERC20 = _tokenId != ethToken;
        let fee = _getEthFee(isERC20);
        let txStatus: Minter.TxStatus = {
            txType = _type;
            tokenId = _tokenId;
            account = _account;
            from = _from;
            to = _to;
            amount = _amount;
            fee = fee;
            nonce = null;
            toids = [];
            txHash = [];
            tx = null;
            rawTx = null;
            signedTx = null;
            receipt = null;
            rpcId = null;
            status = #Building;
        };
        transactions := Trie.put(transactions, keyn(txIndex), Nat.equal, (txStatus, _now())).0;
        txIndex += 1;
        return Nat.sub(txIndex, 1);
    };
    private func _updateTx(_txIndex: TxIndex, _update: {
        fee: ?{ gasPrice: Wei; maxFee: Wei };
        amount: ?Wei;
        nonce: ?Nonce;
        toids: ?[Nat];
        txHash: ?TxHash;
        tx: ?Minter.Transaction;
        rawTx: ?([Nat8], [Nat8]);
        signedTx: ?([Nat8], [Nat8]);
        receipt: ?Text;
        rpcId: ?RpcId;
        status: ?Minter.Status;
        ts: ?Timestamp;
    }) : (){
        switch(Trie.get(transactions, keyn(_txIndex), Nat.equal)){
            case(?(tx, ts)){
                let txStatus: Minter.TxStatus = {
                    txType = tx.txType;
                    tokenId = tx.tokenId;
                    account = tx.account;
                    from = tx.from;
                    to = tx.to;
                    amount = Option.get(_update.amount, tx.amount);
                    fee = Option.get(_update.fee, tx.fee);
                    nonce = switch(_update.nonce){case(?(nonce)){ ?nonce }; case(_){ tx.nonce } };
                    toids = Tools.arrayAppend(tx.toids, Option.get(_update.toids, []));
                    txHash = switch(_update.txHash){case(?(txHash)){ Tools.arrayAppend(tx.txHash, [txHash]) }; case(_){ tx.txHash } };
                    tx = switch(_update.tx){case(?(tx)){ ?tx }; case(_){ tx.tx } };
                    rawTx = switch(_update.rawTx){case(?(rawTx)){ ?rawTx }; case(_){ tx.rawTx } };
                    signedTx = switch(_update.signedTx){case(?(signedTx)){ ?signedTx }; case(_){ tx.signedTx } };
                    receipt = switch(_update.receipt){case(?(receipt)){ ?receipt }; case(_){ tx.receipt } };
                    rpcId = switch(_update.rpcId){case(?(rpcId)){ ?rpcId }; case(_){ tx.rpcId } };
                    status = Option.get(_update.status, tx.status);
                };
                transactions := Trie.put(transactions, keyn(_txIndex), Nat.equal, (txStatus, Option.get(_update.ts, ts))).0;
            };
            case(_){};
        };
    };
    private func _coverTx(_txi: TxIndex, _resetNonce: Bool, _refetchGasPrice: ?Bool, _amountSub: Wei) : async* ?BlockHeight{
        if (Option.get(_refetchGasPrice, false)){
            let gasPrice = await* _fetchGasPrice();
        };
        switch(Trie.get(transactions, keyn(_txi), Nat.equal)){
            case(?(tx, ts)){
                if (tx.status != #Failure and tx.status != #Confirmed){
                    let accountId = _accountId(tx.account.owner, tx.account.subaccount);
                    let isERC20 = tx.tokenId != ethToken;
                    if (_now() > lastGetGasPriceTime + getGasPriceIntervalSeconds){
                        let _gasPrice = await* _fetchGasPrice();
                    };
                    let feeNew = _getEthFee(isERC20); 
                    var amountNew = Nat.sub(tx.amount, _amountSub);
                    if (feeNew.maxFee > tx.fee.maxFee){
                        amountNew -= (feeNew.maxFee - tx.fee.maxFee);
                    };
                    _updateTx(_txi, {
                        fee = ?feeNew;
                        amount = ?amountNew;
                        nonce = null;
                        toids = null;
                        txHash = null;
                        tx = null;
                        rawTx = null;
                        signedTx = null;
                        receipt = null;
                        rpcId = null;
                        status = ?#Building;
                        ts = ?_now();
                    });
                    // ICTC
                    let txiBlob = Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(_txi))); 
                    let saga = _getSaga();
                    let toid : Nat = saga.create("cover_tx", #Forward, ?accountId, null);
                    if (_resetNonce){
                        let task0 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#getNonce(_txi, ?[toid])), [], 0);
                        let ttid0 = saga.push(toid, task0, null, null);
                    };
                    let task1 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#createTx(_txi)), [], 0);
                    let ttid1 = saga.push(toid, task1, null, null);
                    let task2 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#signTx(_txi)), [], 0);
                    let ttid2 = saga.push(toid, task2, null, null);
                    saga.close(toid);
                    await* _ictcSagaRun(toid, false);
                    // record event
                    //
                    blockIndex += 1;
                    return ?Nat.sub(blockIndex, 1);
                }else{
                    throw Error.reject("402: The status of transaction is completed!");
                };
            };
            case(_){ throw Error.reject("402: The transaction record does not exist!"); };
        };
    };
    private func _pushWithdrawal(_a: AccountId, _txi: TxIndex) : (){
        switch(Trie.get(withdrawals, keyb(_a), Blob.equal)){
            case(?(list)){
                withdrawals := Trie.put(withdrawals, keyb(_a), Blob.equal, List.push(_txi, list)).0;
            };
            case(_){
                withdrawals := Trie.put(withdrawals, keyb(_a), Blob.equal, List.push(_txi, null)).0;
            };
        };
    };

    private func _preRpcLog(_id: RpcId, _input: Text) : (){
        switch(Trie.get(rpcLogs, keyn(_id), Nat.equal)){
            case(?(log)){ assert(false) };
            case(_){ 
                rpcLogs := Trie.put(rpcLogs, keyn(_id), Nat.equal, {
                    time = _now(); 
                    input = _input; 
                    result = null; 
                    err = null
                }).0; 
            };
        };
    };
    private func _postRpcLog(_id: RpcId, _result: ?Text, _err: ?Text) : (){
        switch(Trie.get(rpcLogs, keyn(_id), Nat.equal)){
            case(?(log)){
                rpcLogs := Trie.put(rpcLogs, keyn(_id), Nat.equal, {
                    time = log.time; 
                    input = log.input; 
                    result = _result; 
                    err = _err
                }).0; 
            };
            case(_){};
        };
    };

    private func _fetchChainId() : async* Nat {
        let id = rpcId;
        let input = "{\"jsonrpc\":\"2.0\",\"method\":\"eth_chainId\",\"params\": [],\"id\":"# Nat.toText(rpcId) #"}";
        rpcId += 1;
        _preRpcLog(id, input);
        Cycles.add(ECDSA_RPC_CYCLES);
        try{    
            countAsyncMessage += 1;
            let res = await rpc.json_rpc(input, 1000, #url_with_api_key(_getRpcUrl()));
            countAsyncMessage -= Nat.min(1, countAsyncMessage);
            switch(res){
                case(#Ok(r)){
                    switch(_getValueFromJson(r, "result")){
                        case(?(value)){ // wei
                            _postRpcLog(id, ?r, null);
                            chainId := value;
                            return value;
                        }; 
                        case(_){
                            _postRpcLog(id, null, ?"Error in parsing json");
                            throw Error.reject("402: Error in parsing json!");
                        };
                    };
                };
                case(#Err(e)){
                    _postRpcLog(id, null, ?e);
                    throw Error.reject("401: Error while getting chain id!");
                };
            };
        }catch(e){
            countAsyncMessage -= Nat.min(1, countAsyncMessage);
            throw Error.reject("Calling error: "# Error.message(e)); 
        };
    };
    private func _fetchGasPrice() : async* Nat {
        let id = rpcId;
        let input = "{\"jsonrpc\":\"2.0\",\"method\":\"eth_gasPrice\",\"params\": [],\"id\":"# Nat.toText(rpcId) #"}";
        rpcId += 1;
        _preRpcLog(id, input);
        Cycles.add(ECDSA_RPC_CYCLES);
        try{
            countAsyncMessage += 1;
            let res = await rpc.json_rpc(input, 1000, #url_with_api_key(_getRpcUrl()));
            countAsyncMessage -= Nat.min(1, countAsyncMessage);
            switch(res){
                case(#Ok(r)){
                    switch(_getValueFromJson(r, "result")){
                        case(?(value)){ // wei
                            _postRpcLog(id, ?r, null);
                            gasPrice := value * 11 / 10; // * debug
                            lastGetGasPriceTime := _now();
                            return gasPrice;
                        }; 
                        case(_){
                            _postRpcLog(id, null, ?"Error in parsing json");
                            throw Error.reject("402: Error in parsing json!");
                        };
                    };
                };
                case(#Err(e)){
                    _postRpcLog(id, null, ?e);
                    throw Error.reject("401: Error while getting gas price!");
                };
            };
        }catch(e){
            countAsyncMessage -= Nat.min(1, countAsyncMessage);
            throw Error.reject("Calling error: "# Error.message(e)); 
        };
    };
    private func _fetchBlockNumber() : async* Nat{
        let id = rpcId;
        let input = "{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\",\"params\": [],\"id\":"# Nat.toText(rpcId) #"}";
        rpcId += 1;
        _preRpcLog(id, input);
        Cycles.add(ECDSA_RPC_CYCLES);
        try{
            countAsyncMessage += 1;
            let res = await rpc.json_rpc(input, 1000, #url_with_api_key(_getRpcUrl()));
            countAsyncMessage -= Nat.min(1, countAsyncMessage);
            switch(res){
                case(#Ok(r)){
                    switch(_getValueFromJson(r, "result")){
                        case(?(value)){ 
                            _postRpcLog(id, ?r, null);
                            ethBlockNumber := (value, _now());
                            return value;
                        }; 
                        case(_){
                            _postRpcLog(id, null, ?"Error in parsing json");
                            throw Error.reject("402: Error in parsing json!");
                        };
                    };
                };
                case(#Err(e)){
                    _postRpcLog(id, null, ?e);
                    throw Error.reject("401: Error while getting block number!");
                };
            };
        }catch(e){
            countAsyncMessage -= Nat.min(1, countAsyncMessage);
            throw Error.reject("Calling error: "# Error.message(e)); 
        };
    };
    private func _fetchAccountAddress(_dpath: DerivationPath) : async* (pubkey:PubKey, ethAccount:EthAccount, address: EthAddress){
        var own_public_key : [Nat8] = [];
        var own_account : [Nat8] = [];
        var own_address : Text = "";
        let ecdsa_public_key = await ic.ecdsa_public_key({
            canister_id = null;
            derivation_path = _dpath;
            key_id = { curve = #secp256k1; name = KEY_NAME }; //dfx_test_key
        });
        own_public_key := Blob.toArray(ecdsa_public_key.public_key);
        switch(await utils.pub_to_address(own_public_key)){
            case(#Ok(account)){
                own_account := account;
                own_address := ABI.toHex(account);
            };
            case(#Err(e)){
                throw Error.reject("401: Error while getting address!");
            };
        };
        return (own_public_key, own_account, own_address);
    };
    private func _fetchAccountNonce(_address: EthAddress, _isLatest: Bool) : async* Nonce{
        let id = rpcId;
        var block = "pending";
        if (_isLatest){
            block := "latest";
        };
        let input = "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getTransactionCount\",\"params\": [\""# _address #"\", \""# block #"\"],\"id\":"# Nat.toText(rpcId) #"}";
        rpcId += 1;
        _preRpcLog(id, input);
        Cycles.add(ECDSA_RPC_CYCLES);
        let res = await rpc.json_rpc(input, 1000, #url_with_api_key(_getRpcUrl()));
        switch(res){
            case(#Ok(r)){
                switch(_getValueFromJson(r, "result")){
                    case(?(value)){ 
                        _postRpcLog(id, ?r, null);
                        return value;
                    }; 
                    case(_){
                        _postRpcLog(id, null, ?"Error in parsing json");
                        throw Error.reject("402: Error in parsing json");
                    };
                };
            };
            case(#Err(e)){
                _postRpcLog(id, null, ?e);
                throw Error.reject("401: Error while getting nonce!");
            };
        };
    };
    private func _fetchEthBalance(_address : EthAddress, _latest: Bool): async* Wei{
        let id = rpcId;
        let blockNumber: Text = if (_latest) { "latest" } else { ABI.natToHex(Nat.sub(_getBlockNumber(), MIN_CONFIRMATIONS)) };
        let input = "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\": [\""# _address #"\", \""# blockNumber #"\"],\"id\":"# Nat.toText(rpcId) #"}";
        rpcId += 1;
        _preRpcLog(id, input);
        Cycles.add(ECDSA_RPC_CYCLES);
        let res = await rpc.json_rpc(input, 1000, #url_with_api_key(_getRpcUrl()));
        switch(res){
            case(#Ok(r)){
                switch(_getValueFromJson(r, "result")){
                    case(?(value)){ 
                        _postRpcLog(id, ?r, null);
                        return value;
                    }; 
                    case(_){
                        _postRpcLog(id, null, ?"Error in parsing json");
                        throw Error.reject("Error in parsing json");
                    };
                };
            };
            case(#Err(e)){
                _postRpcLog(id, null, ?e);
                throw Error.reject(e);
            };
        };
    };
    private func _sendRawTx(_raw: [Nat8]) : async* (rpcId: RpcId, Result.Result<TxHash, Text>){
        let id = rpcId;
        let input = "{\"jsonrpc\":\"2.0\",\"method\":\"eth_sendRawTransaction\",\"params\": [\""# ABI.toHex(_raw) #"\"],\"id\":"# Nat.toText(rpcId) #"}";
        rpcId += 1;
        _preRpcLog(id, input);
        Cycles.add(ECDSA_RPC_CYCLES);
        let res = await rpc.json_rpc(input, 1000, #url_with_api_key(_getRpcUrl()));
        switch(res){
            case(#Ok(r)){
                switch(_getBytesFromJson(r, "result")){
                    case(?(value)){ 
                        _postRpcLog(id, ?r, null);
                        return (rpcId - 1, #ok(ABI.toHex(value)));
                    }; 
                    case(_){
                        switch(_getStringFromJson(r, "error")){
                            case(?(value)){ 
                                _postRpcLog(id, ?r, null);
                                return (rpcId - 1, #err(value));
                            }; 
                            case(_){
                                _postRpcLog(id, null, ?"Error in parsing json");
                                throw Error.reject("402: Error in parsing json");
                            };
                        };
                    };
                };
            };
            case(#Err(e)){
                _postRpcLog(id, null, ?e);
                throw Error.reject("401: "# e);
            };
        };
    };
    private func _fetchTxReceipt(_txHash: TxHash): async* (Bool, BlockHeight, Status, ?Text){
        let id = rpcId;
        let input = "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getTransactionReceipt\",\"params\": [\""# _txHash #"\"],\"id\":"# Nat.toText(rpcId) #"}";
        rpcId += 1;
        _preRpcLog(id, input);
        Cycles.add(ECDSA_RPC_CYCLES);
        let res = await rpc.json_rpc(input, 5000, #url_with_api_key(_getRpcUrl()));
        switch(res){
            case(#Ok(r)){
                switch(_getValueFromJson(r, "status")){ // result/status
                    case(?(status)){ 
                        if (status == 1){
                            switch(_getValueFromJson(r, "blockNumber")){ // result/blockNumber
                                case(?(blockNumber)){
                                    _postRpcLog(id, ?r, null);
                                    if (blockNumber > 0){
                                        return (true, blockNumber, #Confirmed, ?r);
                                    }else{
                                        return (true, blockNumber, #Pending, ?r);
                                    };
                                };
                                case(_){
                                    _postRpcLog(id, ?r, ?"The status is pending or an error occurred");
                                    return (true, 0, #Unknown, ?r);
                                };
                            };
                        }else{
                            switch(_getValueFromJson(r, "blockNumber")){ // result/blockNumber
                                case(?(blockNumber)){
                                    _postRpcLog(id, ?r, ?"Failed transaction");
                                    return (false, blockNumber, #Failure, ?r);
                                };
                                case(_){
                                    _postRpcLog(id, ?r, ?"The status is pending or an error occurred");
                                    return (false, 0, #Unknown, ?r);
                                };
                            };
                        };
                    }; 
                    case(_){
                        _postRpcLog(id, null, ?"Error in parsing json");
                        return (false, 0, #Unknown, ?r);
                    };
                };
            };
            case(#Err(e)){
                _postRpcLog(id, null, ?e);
                return (false, 0, #Unknown, null);
            };
        };
    };

    private func _syncTxStatus(_txIndex: TxIndex, _immediately: Bool) : async* (){
        switch(Trie.get(transactions, keyn(_txIndex), Nat.equal)){
            case(?(tx, ts)){
                if ((tx.status == #Sending or tx.status == #Submitted or tx.status == #Pending) and (_immediately or _now() > ts + 120)){
                    let txHashs = tx.txHash;
                    var status = tx.status;
                    var countFailure : Nat = 0;
                    var receiptTemp: ?Text = null;
                    label TxReceipt for (txHash in txHashs.vals()){
                        let (succeeded, blockHeight, txStatus, res) = await* _fetchTxReceipt(txHash);
                        if (succeeded and blockHeight > 0 and _getBlockNumber() >= blockHeight + MIN_CONFIRMATIONS){
                            status := #Confirmed;
                            receiptTemp := res;
                            if (tx.txType == #Deposit){
                                ignore _addBalance(_accountId(tx.account.owner, tx.account.subaccount), tx.tokenId, tx.amount);
                                ignore _removeDepositingTxIndex(_accountId(tx.account.owner, tx.account.subaccount), _txIndex);
                            }else if(tx.txType == #Withdraw){
                                _removeRetrievingTxIndex(_txIndex);
                            };
                            break TxReceipt;
                        }else if (succeeded and (blockHeight == 0 or _getBlockNumber() < blockHeight + MIN_CONFIRMATIONS)){
                            status := #Pending;
                            receiptTemp := res;
                        }else if (not(succeeded) and blockHeight > 0 and _getBlockNumber() >= blockHeight + MIN_CONFIRMATIONS){
                            countFailure += 1;
                        };
                    };
                    if (countFailure == txHashs.size()){
                        status := #Failure;
                        if (tx.txType == #Deposit){
                            ignore _removeDepositingTxIndex(_accountId(tx.account.owner, tx.account.subaccount), _txIndex);
                        }else if(tx.txType == #Withdraw){
                            _removeRetrievingTxIndex(_txIndex);
                        };
                    };
                    let tsNew = if (_immediately) { ts } else{ _now() };
                    if (status != tx.status){
                        _updateTx(_txIndex, {
                            fee = null;
                            amount = null;
                            nonce = null;
                            toids = null;
                            txHash = null;
                            tx = null;
                            rawTx = null;
                            signedTx = null;
                            receipt = receiptTemp;
                            rpcId = null;
                            status = ?status;
                            ts = ?tsNew;
                        });
                    }else{
                        transactions := Trie.put(transactions, keyn(_txIndex), Nat.equal, (tx, tsNew)).0;
                    };
                };
            };
            case(_){};
        };
    };

    /** Public functions **/

    public shared(msg) func get_eth_address(_account : { owner: Principal; subaccount : ?[Nat8] }): async Text{
        assert(_notPaused() or _onlyOwner(msg.caller));
        let accountId = _accountId(_account.owner, _account.subaccount);
        if (Option.isSome(_getDepositingTxIndex(accountId))){
            throw Error.reject("405: You have a deposit waiting for network confirmation.");
        };
        let account = await* _getEthAddress(accountId, false);
        return account.0;
    };
    public shared(msg) func deposit_notify(_token: ?EthAddress, _account : { owner: Principal; subaccount : ?[Nat8] }) : async {
        #Ok : Minter.DepositResult; 
        #Err : Minter.ResultError;
    }{
        let __start = Time.now();
        assert(_notPaused() or _onlyOwner(msg.caller));
        if (not(_checkAsyncMessageLimit())){
            countRejections += 1; 
            return #Err(#GenericError({code = 405; message="405: IC network is busy, please try again later."}));
        };
        if (_now() < _getLatestVisitTime(msg.caller) + MIN_VISIT_INTERVAL){
            return #Err(#GenericError({code = 400; message = "400: Access is allowed only once every " # Nat.toText(MIN_VISIT_INTERVAL) # " seconds!"}))
        };
        let accountId = _accountId(_account.owner, _account.subaccount);
        let account = _account;
        let (myAddress, myNonce) = _getEthAddressQuery(accountId);
        let (mainAddress, mainNonce) = _getEthAddressQuery(_accountId(Principal.fromActor(this), null));
        if (Text.size(myAddress) != 42){
            return #Err(#GenericError({code = 402; message="402: Address is not available."}));
        };
        if (Option.isSome(_token)){
            return #Err(#GenericError({code = 403; message="403: ERC20 is not yet supported."}));
        };
        let isERC20 = Option.isSome(_token);
        let tokenId = Option.get(_token, ethToken);
        if (_now() > lastGetGasPriceTime + getGasPriceIntervalSeconds){
            let _gasPrice = await* _fetchGasPrice();
        };
        let ethFee = _getEthFee(isERC20); // eth Wei
        let tokenFee = ethFee.maxFee; // token Wei  * debug 
        var depositAmount: Wei = 0;
        if (Option.isSome(_getDepositingTxIndex(accountId))){
            await* _syncTxStatus(Option.get(_getDepositingTxIndex(accountId),0), false);
            return #Err(#GenericError({code = 402; message="402: You have a deposit waiting for network confirmation."}));
        }else{ // New deposit
            depositAmount := await* _fetchEthBalance(myAddress, true); // Wei  // * debug
        };
        if (depositAmount > tokenFee and depositAmount > ETH_MIN_AMOUNT){ 
            ignore _addTotalFee(tokenId, tokenFee);
            if (_getTotalFee(ethToken) >= ethFee.maxFee){
                ignore _subTotalFee(ethToken, ethFee.maxFee);
            }else{
                ignore _subTotalFee(tokenId, tokenFee);
                return #Err(#GenericError({code = 402; message="402: Insufficient fee balance."}));
            };
            let amount = if (isERC20) { depositAmount } else { Nat.sub(depositAmount, tokenFee) };
            let txi = _newTx(#Deposit, account, tokenId, myAddress, mainAddress, amount);
            _putDepositingTxIndex(accountId, txi);
            //ICTC:
            let saga = _getSaga();
            let txiBlob = Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(txi))); 
            let toid : Nat = saga.create("deposit", #Backward, ?accountId, null);
            let task1 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#getNonce(txi, ?[toid])), [], 0);
            let comp1 = _buildTask(?txiBlob, Principal.fromActor(this), #__skip, [], 0);
            let ttid1 = saga.push(toid, task1, ?comp1, null);
            let task2 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#createTx(txi)), [], 0);
            let comp2 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#createTx_comp(txi)), [], 0);
            let ttid2 = saga.push(toid, task2, ?comp2, null);
            let task3 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#signTx(txi)), [], 0);
            let comp3 = _buildTask(?txiBlob, Principal.fromActor(this), #__skip, [], 0);
            let ttid3 = saga.push(toid, task3, ?comp3, null);
            let task4 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#sendTx(txi)), [], 0);
            let comp4 = _buildTask(?txiBlob, Principal.fromActor(this), #__skip, [], 0);
            let ttid4 = saga.push(toid, task4, ?comp4, null);
            saga.close(toid);
            await* _ictcSagaRun(toid, false);
            lastExecutionDuration := Time.now() - __start;
            if (lastExecutionDuration > maxExecutionDuration) { maxExecutionDuration := lastExecutionDuration };
            // record event
            //
            // swap fee
            // 
            blockIndex += 1;
            return #Ok({ 
                blockIndex = Nat.sub(blockIndex, 1); 
                amount = amount;
                txIndex = txi;
                toid = toid;
            });
        }else{
            return #Err(#GenericError({code = 402; message="402: The amount is less than the gas or the minimum value."}));
        };
    };
    public shared(msg) func update_balance(_token: ?EthAddress, _account : { owner: Principal; subaccount : ?[Nat8] }): async {
        #Ok : Minter.UpdateBalanceResult; 
        #Err : Minter.ResultError;
    }{
        let __start = Time.now();
        assert(_notPaused() or _onlyOwner(msg.caller));
        if (not(_checkAsyncMessageLimit())){
            countRejections += 1; 
            return #Err(#GenericError({code = 405; message="405: IC network is busy, please try again later."}));
        };
        if (_now() < _getLatestVisitTime(msg.caller) + MIN_VISIT_INTERVAL){
            return #Err(#GenericError({code = 400; message = "400: Access is allowed only once every " # Nat.toText(MIN_VISIT_INTERVAL) # " seconds!"}))
        };
        let isERC20 = Option.isSome(_token);
        let tokenId = Option.get(_token, ethToken);
        let accountId = _accountId(_account.owner, _account.subaccount);
        let icrc1Account : ICRC1.Account = { owner = _account.owner; subaccount = _toSaBlob(_account.subaccount); };
        let account : Minter.Account = _account;
        let (myAddress, myNonce) = _getEthAddressQuery(accountId);
        let (mainAddress, mainNonce) = _getEthAddressQuery(_accountId(Principal.fromActor(this), null));
        let txi = Option.get(_getDepositingTxIndex(accountId),0);
        await* _syncTxStatus(txi, false);
        let balance = _getBalance(accountId, tokenId);
        let amount = balance;
        if (amount > 0){
            ignore _subBalance(accountId, tokenId, amount);
            ignore _addBalance(_accountId(Principal.fromActor(this), null), tokenId, amount);
            // mint ckETH
            let txiBlob = Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(txi))); 
            let saga = _getSaga();
            let toid : Nat = saga.create("mint", #Forward, ?accountId, null);
            let args : ICRC1.TransferArgs = {
                from_subaccount = null;
                to = icrc1Account;
                amount = amount;
                fee = null;
                memo = ?Text.encodeUtf8(myAddress);
                created_at_time = null; // nanos
            };
            let task = _buildTask(?txiBlob, ckETH_, #ICRC1(#icrc1_transfer(args)), [], 0);
            let ttid = saga.push(toid, task, null, null);
            saga.close(toid);
            blockIndex += 1;
            // let sagaRes = await saga.run(toid);
            await* _ictcSagaRun(toid, false);
            lastExecutionDuration := Time.now() - __start;
            if (lastExecutionDuration > maxExecutionDuration) { maxExecutionDuration := lastExecutionDuration };
            return #Ok({ blockIndex = Nat.sub(blockIndex, 1);  amount = amount; toid= toid });
        }else{
            return #Err(#GenericError({code = 403; message="403: Insufficient deposit or deposit transaction not yet confirmed."}));
        };
    };
    public shared(msg) func get_withdrawal_account(_account : { owner: Principal; subaccount : ?[Nat8] }) : async Minter.Account{
        assert(_notPaused() or _onlyOwner(msg.caller));
        let accountId = _accountId(_account.owner, _account.subaccount);
        return {owner=Principal.fromActor(this); subaccount=?Blob.toArray(accountId)};
    };
    public shared(msg) func retrieve(_token: ?EthAddress, _address: EthAddress, _amount: Wei, _sa: ?[Nat8]) : async { 
        #Ok : Minter.RetrieveResult; //{ block_index : Nat64 };
        #Err : Minter.ResultError;
    }{
        let __start = Time.now();
        assert(_notPaused() or _onlyOwner(msg.caller));
        if (not(_checkAsyncMessageLimit())){
            countRejections += 1; 
            return #Err(#GenericError({code = 405; message="405: IC network is busy, please try again later."}));
        };
        if (_now() < _getLatestVisitTime(msg.caller) + MIN_VISIT_INTERVAL){
            return #Err(#GenericError({code = 400; message = "400: Access is allowed only once every " # Nat.toText(MIN_VISIT_INTERVAL) # " seconds!"}))
        };
        _setLatestVisitTime(msg.caller);
        let accountId = _accountId(msg.caller, _sa);
        let account: Minter.Account = {owner=msg.caller; subaccount=_sa};
        let withdrawalIcrc1Account: ICRC1.Account = {owner=Principal.fromActor(this); subaccount=?accountId};
        let withdrawalAccount : Minter.Account = { owner = msg.caller; subaccount = ?Blob.toArray(accountId); };
        let mainAccoundId = _accountId(Principal.fromActor(this), null);
        let mainIcrc1Account : ICRC1.Account = {owner=Principal.fromActor(this); subaccount=null };
        let (mainAddress, mainNonce) = _getEthAddressQuery(mainAccoundId);
        if (Text.size(_address) != 42){
            return #Err(#GenericError({code = 402; message="402: Address is not available."}));
        };
        if (Option.isSome(_token)){
            return #Err(#GenericError({code = 403; message="403: ERC20 is not yet supported."}));
        };
        let isERC20 = Option.isSome(_token);
        let tokenId = Option.get(_token, ethToken);
        // let icrc1Fee = ckethFee_; // * debug // Wei
        if (_now() > lastGetGasPriceTime + getGasPriceIntervalSeconds){
            let _gasPrice = await* _fetchGasPrice();
        };
        let ethFee = _getEthFee(isERC20); // eth Wei
        let tokenFee = ethFee.maxFee; // token Wei  * debug 
        //AmountTooLow
        if (_amount < ETH_MIN_AMOUNT){
            return #Err(#GenericError({code = 402; message="402: Amount is too low."}));
        };
        let balance = await ckETH.icrc1_balance_of(withdrawalIcrc1Account);
        //InsufficientFunds
        if (balance < _amount){
            return #Err(#GenericError({code = 402; message="402: Insufficient funds."}));
        };
        ignore _addTotalFee(tokenId, tokenFee);
        if (_getTotalFee(ethToken) >= ethFee.maxFee){
            ignore _subTotalFee(ethToken, ethFee.maxFee);
        }else{
            ignore _subTotalFee(tokenId, tokenFee);
            return #Err(#GenericError({code = 402; message="402: Insufficient fee balance."}));
        };
        //burn
        let burnArgs : ICRC1.TransferArgs = {
            from_subaccount = ?accountId;
            to = mainIcrc1Account;
            amount = _amount; // Nat.sub(_amount, icrc1Fee);
            fee = null;
            memo = ?accountId;
            created_at_time = null; // nanos
        };
        switch(await ckETH.icrc1_transfer(burnArgs)){
            case(#Ok(height)){
                // ignore _subBalance(_accountId(Principal.fromActor(this), null), tokenId, _amount); // * debug
                let eAmount = if (isERC20) { _amount } else { Nat.sub(_amount, tokenFee) };
                //totalSent += _amount;
                let txi = _newTx(#Withdraw, account, tokenId, mainAddress, _address, eAmount);
                let status : Minter.RetrieveStatus = {
                    account = account;
                    retrieveAccount = withdrawalAccount;
                    burnedBlockIndex = height;
                    ethAddress = _address;
                    amount = eAmount; 
                    txIndex = txi;
                };
                retrievals := Trie.put(retrievals, keyn(txi), Nat.equal, status).0;
                _pushWithdrawal(accountId, txi);
                _putRetrievingTxIndex(txi);
                // ICTC
                let txiBlob = Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(txi))); 
                let saga = _getSaga();
                let toid : Nat = saga.create("retrieve", #Forward, ?accountId, null);
                let task1 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#getNonce(txi, ?[toid])), [], 0);
                let ttid1 = saga.push(toid, task1, null, null);
                let task2 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#createTx(txi)), [], 0);
                let ttid2 = saga.push(toid, task2, null, null);
                let task3 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#signTx(txi)), [], 0);
                let ttid3 = saga.push(toid, task3, null, null);
                let task4 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#sendTx(txi)), [], 0);
                let ttid4 = saga.push(toid, task4, null, null);
                saga.close(toid);
                await* _ictcSagaRun(toid, false);
                lastExecutionDuration := Time.now() - __start;
                if (lastExecutionDuration > maxExecutionDuration) { maxExecutionDuration := lastExecutionDuration };
                // record event
                // 
                // swap fee
                // 
                blockIndex += 1;
                return #Ok({ 
                    blockIndex = Nat.sub(blockIndex, 1); 
                    amount = eAmount; 
                    retrieveFee = tokenFee;
                    txIndex = txi;
                    toid = toid;
                });
            };
            case(#Err(#InsufficientFunds({ balance }))){
                return #Err(#GenericError({ code = 401; message="401: Insufficient balance when burning token.";}));
            };
            case(_){
                return #Err(#GenericError({ code = 401; message = "401: Error on burning token";}));
            };
        };
    };
    public shared(msg) func update_retrievals() : async [(Minter.TxStatus, Timestamp)]{
        assert(_notPaused() or _onlyOwner(msg.caller));
        if (not(_checkAsyncMessageLimit())){
            countRejections += 1; 
            throw Error.reject("405: IC network is busy, please try again later.");
        };
        if (_now() < _getLatestVisitTime(msg.caller) + MIN_VISIT_INTERVAL){
            throw Error.reject("400: Access is allowed only once every " # Nat.toText(MIN_VISIT_INTERVAL) # " seconds!");
        };
        _setLatestVisitTime(msg.caller);
        if (_now() > lastUpdateTxsTime + 120){
            lastUpdateTxsTime := _now();
            for (txi in List.toArray(retrievalPendings).vals()){
                await* _syncTxStatus(txi, true);
            };
            let retrievals = List.toArray(List.mapFilter<TxIndex, (Minter.TxStatus, Timestamp)>(retrievalPendings, func (txi: TxIndex): ?(Minter.TxStatus, Timestamp){
                switch(Trie.get(transactions, keyn(txi), Nat.equal)){
                    case(?(tx, ts)){
                        if (_now() > ts + 600){ return ?(tx, ts) }else{ return null};
                    };
                    case(_){ return null };
                };
            }));
            return retrievals;
        };
        return [];
    };
    public shared(msg) func cover_tx(_txi: TxIndex, _sa: ?[Nat8]) : async ?BlockHeight{
        assert(_notPaused() or _onlyOwner(msg.caller));
        if (not(_checkAsyncMessageLimit())){
            countRejections += 1; 
            throw Error.reject("405: IC network is busy, please try again later.");
        };
        if (_now() < _getLatestVisitTime(msg.caller) + MIN_VISIT_INTERVAL){
            throw Error.reject("400: Access is allowed only once every " # Nat.toText(MIN_VISIT_INTERVAL) # " seconds!");
        };
        _setLatestVisitTime(msg.caller);
        let callerAccountId = _accountId(msg.caller, _sa);
        switch(Trie.get(transactions, keyn(_txi), Nat.equal)){
            case(?(tx, ts)){
                assert(_now() > ts + 20*60); // 20 minuts
                let accountId = _accountId(tx.account.owner, tx.account.subaccount);
                assert(callerAccountId == accountId or _onlyOwner(msg.caller));
            };
            case(_){};
        };
        await* _syncTxStatus(_txi, true);
        return await* _coverTx(_txi, false, ?true, 0);
    };

    public query func get_minter_address() : async EthAddress{
        return _getEthAddressQuery(_accountId(Principal.fromActor(this), null)).0;
    };
    public query func get_depositing_balance(_token: ?EthAddress, _account : { owner: Principal; subaccount : ?[Nat8] }): async Wei{
        let tokenId = Option.get(_token, ethToken);
        let accountId = _accountId(_account.owner, _account.subaccount);
        return _getBalance(accountId, tokenId);
    };
    public query func get_total_balance(_token: ?EthAddress): async Wei{
        let tokenId = Option.get(_token, ethToken);
        let accountId = _accountId(Principal.fromActor(this), null);
        return _getBalance(accountId, tokenId);
    };
    public query func get_fee_balance(_token: ?EthAddress): async Wei{
        let tokenId = Option.get(_token, ethToken);
        return _getTotalFee(tokenId);
    };
    public query func get_tx(_txi: TxIndex) : async ?Minter.TxStatus{
        return _getTx(_txi);
    }; 
    public query func retrieval(_txi: TxIndex) : async ?Minter.RetrieveStatus{  
        switch(Trie.get(retrievals, keyn(_txi), Nat.equal)){
            case(?(status)){
                return ?status;
            };
            case(_){
                return null;
            };
        };
    };
    public query func retrieval_list(_account: Address) : async [Minter.RetrieveStatus]{  //latest 500 records
        let accountId = _getAccountId(_account);
        switch(Trie.get(withdrawals, keyb(accountId), Blob.equal)){
            case(?(list)){
                return Tools.slice(List.toArray(List.mapFilter<TxIndex, Minter.RetrieveStatus>(list, func (_txi: TxIndex): ?Minter.RetrieveStatus{
                    Trie.get(retrievals, keyn(_txi), Nat.equal);
                })), 0, ?499);
            };
            case(_){
                return [];
            };
        };
    };
    public query func retrieving_txs() : async [(Minter.TxStatus, Timestamp)]{
        return Tools.slice(List.toArray(List.mapFilter<TxIndex, (Minter.TxStatus, Timestamp)>(retrievalPendings, func (_txi: TxIndex): ?(Minter.TxStatus, Timestamp){
            Trie.get(transactions, keyn(_txi), Nat.equal);
        })), 0, ?499);
    };
    
    /** Debug **/

    public shared(msg) func debug_sync() : async (Nat, Nat, Nat, Text){
        assert(_onlyOwner(msg.caller));
        chainId := await* _fetchChainId();
        gasPrice := await* _fetchGasPrice();
        ethBlockNumber := (await* _fetchBlockNumber(), _now());
        let selfAddress = await* _getEthAddress(_accountId(Principal.fromActor(this), null), true);
        return (chainId, gasPrice, ethBlockNumber.0, selfAddress.0);
    };
    public query func debug_rpcLogs(_page: ?ListPage, _size: ?ListSize) : async TrieList<RpcId, RpcLog>{
        return trieItems<RpcId, RpcLog>(rpcLogs, Option.get(_page, 1), Option.get(_size, 20));
    };
    public shared(msg) func debug_clear_rpcLogs() : async (){
        rpcLogs := Trie.empty<RpcId, RpcLog>();
    };
    public shared(msg) func debug_get_address(_account : { owner: Principal; subaccount : ?[Nat8] }) : async (EthAddress, Nonce){
        assert(_onlyOwner(msg.caller));
        let accountId = _accountId(_account.owner, _account.subaccount);
        return await* _getEthAddress(accountId, true);
    };
    public shared(msg) func debug_get_balance(_token: ?EthAddress, _address: EthAddress) : async Nat{
        assert(_onlyOwner(msg.caller));
        return await* _fetchEthBalance(_address, false);
    };
    public shared(msg) func debug_get_tx(_txHash: TxHash) : async (Bool, BlockHeight, Status, ?Text){
        assert(_onlyOwner(msg.caller));
        return await* _fetchTxReceipt(_txHash);
    };
    public shared(msg) func debug_clear_txs(): async (){
        assert(_onlyOwner(msg.caller));
        deposits := Trie.empty<AccountId, TxIndex>();
        transactions := Trie.empty<TxIndex, (tx: Minter.TxStatus, updatedTime: Timestamp)>();
    };
    public shared(msg) func debug_local_getNonce(_txi: TxIndex) : async {txi: Nat; address: EthAddress; nonce: Nonce}{
        assert(_onlyOwner(msg.caller));
        return await* _local_getNonce(_txi, null);
    };
    public shared(msg) func debug_local_createTx(_txi: TxIndex) : async {txi: Nat; rawTx: [Nat8]; txHash: TxHash}{
        assert(_onlyOwner(msg.caller));
        return await* _local_createTx(_txi);
    };
    public shared(msg) func debug_local_signTx(_txi: TxIndex) : async ({txi: Nat; signature: Blob; rawTx: [Nat8]; txHash: TxHash}){
        assert(_onlyOwner(msg.caller));
        let res = await* _local_signTx(_txi);
        return (res);
    };
    public shared(msg) func debug_local_sendTx(_txi: TxIndex) : async {txi: Nat; result: Result.Result<TxHash, Text>; rpcId: RpcId}{
        assert(_onlyOwner(msg.caller));
        let res = await* _local_sendTx(_txi);
        return (res);
    };
    public shared(msg) func debug_sync_tx(_txi: TxIndex) : async (){
        assert(_onlyOwner(msg.caller));
        await* _syncTxStatus(_txi, true);
    };
    public shared(msg) func debug_parse_tx(_data: Blob): async ETHUtils.Result_2{
        assert(_onlyOwner(msg.caller));
        return await utils.parse_transaction(Blob.toArray(_data));
    };
    private var testMainnet: Bool = false;
    public shared(msg) func debug_send_to(_principal: Principal, _from: EthAddress, _to: EthAddress, _amount: Wei): async TxIndex{
        assert(_onlyOwner(msg.caller));
        testMainnet := true;
        let accountId = _accountId(_principal, null);
        let txi = _newTx(#Deposit, {owner = _principal; subaccount = null }, ethToken, _from, _to, _amount);
        //ICTC:
        let saga = _getSaga();
        let txiBlob = Blob.fromArray(Binary.BigEndian.fromNat64(Nat64.fromNat(txi))); 
        let toid : Nat = saga.create("deposit--", #Backward, ?accountId, null);
        let task1 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#getNonce(txi, ?[toid])), [], 0);
        let comp1 = _buildTask(?txiBlob, Principal.fromActor(this), #__skip, [], 0);
        let ttid1 = saga.push(toid, task1, ?comp1, null);
        let task2 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#createTx(txi)), [], 0);
        let comp2 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#createTx_comp(txi)), [], 0);
        let ttid2 = saga.push(toid, task2, ?comp2, null);
        let task3 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#signTx(txi)), [], 0);
        let comp3 = _buildTask(?txiBlob, Principal.fromActor(this), #__skip, [], 0);
        let ttid3 = saga.push(toid, task3, ?comp3, null);
        let task4 = _buildTask(?txiBlob, Principal.fromActor(this), #This(#sendTx(txi)), [], 0);
        let comp4 = _buildTask(?txiBlob, Principal.fromActor(this), #__skip, [], 0);
        let ttid4 = saga.push(toid, task4, ?comp4, null);
        saga.close(toid);
        await* _ictcSagaRun(toid, false);
        testMainnet := false;
        return txi;
    };
    public shared(msg) func debug_cover_tx(_txi: TxIndex) : async ?BlockHeight{
        assert(_onlyOwner(msg.caller));
        testMainnet := true;
        let res = await* _coverTx(_txi, false, null, 0);
        testMainnet := false;
        return res;
    };

    /* ===========================
      Management section
    ============================== */
    public query func getOwner() : async Principal{  
        return owner;
    };
    public shared(msg) func changeOwner(_newOwner: Principal) : async Bool{ 
        assert(_onlyOwner(msg.caller));
        owner := _newOwner;
        return true;
    };
    public shared(msg) func setPause(_pause: Bool) : async Bool{ 
        assert(_onlyOwner(msg.caller));
        pause := _pause;
        return true;
    };
    public shared(msg) func setRpcUrl(_url: Text) : async Bool{ 
        assert(_onlyOwner(msg.caller));
        rpcUrl := _url;
        chainId := await* _fetchChainId();
        return true;
    };
    public shared(msg) func rebuildTx(_txi: TxIndex, _resetNonce: Bool, _refetchGasPrice: Bool, _amountSub: Wei) : async ?BlockHeight{
        assert(_onlyOwner(msg.caller));
        await* _syncTxStatus(_txi, true);
        return await* _coverTx(_txi, _resetNonce, ?_refetchGasPrice, _amountSub);
    };
    public shared(msg) func resetNonce(_isLatest: Bool) : async Nonce{
        assert(_onlyOwner(msg.caller));
        let mainAccountId = _accountId(Principal.fromActor(this), null);
        let (mainAddress, mainNonce) = _getEthAddressQuery(mainAccountId);
        let nonce = await* _fetchAccountNonce(mainAddress, _isLatest);
        _setEthAccount(mainAccountId, mainAddress, nonce);
        return nonce;
    };

    /**
    * ICTC Transaction Explorer Interface
    * (Optional) Implement the following interface, which allows you to browse transaction records and execute compensation transactions through a UI interface.
    * https://cmqwp-uiaaa-aaaaj-aihzq-cai.raw.ic0.app/
    */
    // ICTC: management functions
    private stable var ictc_admins: [Principal] = [];
    private func _onlyIctcAdmin(_caller: Principal) : Bool { 
        return Option.isSome(Array.find(ictc_admins, func (t: Principal): Bool{ t == _caller }));
    }; 
    private func _onlyBlocking(_toid: Nat) : Bool{
        /// Saga
        switch(_getSaga().status(_toid)){
            case(?(status)){ return status == #Blocking };
            case(_){ return false; };
        };
        /// 2PC
        // switch(_getTPC().status(_toid)){
        //     case(?(status)){ return status == #Blocking };
        //     case(_){ return false; };
        // };
    };
    public query func ictc_getAdmins() : async [Principal]{
        return ictc_admins;
    };
    public shared(msg) func ictc_addAdmin(_admin: Principal) : async (){
        assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller));
        if (Option.isNull(Array.find(ictc_admins, func (t: Principal): Bool{ t == _admin }))){
            ictc_admins := Tools.arrayAppend(ictc_admins, [_admin]);
        };
    };
    public shared(msg) func ictc_removeAdmin(_admin: Principal) : async (){
        assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller));
        ictc_admins := Array.filter(ictc_admins, func (t: Principal): Bool{ t != _admin });
    };

    // SagaTM Scan
    public query func ictc_TM() : async Text{
        return "Saga";
    };
    /// Saga
    public query func ictc_getTOCount() : async Nat{
        return _getSaga().count();
    };
    public query func ictc_getTO(_toid: SagaTM.Toid) : async ?SagaTM.Order{
        return _getSaga().getOrder(_toid);
    };
    public query func ictc_getTOs(_page: Nat, _size: Nat) : async {data: [(SagaTM.Toid, SagaTM.Order)]; totalPage: Nat; total: Nat}{
        return _getSaga().getOrders(_page, _size);
    };
    public query func ictc_getTOPool() : async [(SagaTM.Toid, ?SagaTM.Order)]{
        return _getSaga().getAliveOrders();
    };
    public query func ictc_getTT(_ttid: SagaTM.Ttid) : async ?SagaTM.TaskEvent{
        return _getSaga().getActuator().getTaskEvent(_ttid);
    };
    public query func ictc_getTTByTO(_toid: SagaTM.Toid) : async [SagaTM.TaskEvent]{
        return _getSaga().getTaskEvents(_toid);
    };
    public query func ictc_getTTs(_page: Nat, _size: Nat) : async {data: [(SagaTM.Ttid, SagaTM.TaskEvent)]; totalPage: Nat; total: Nat}{
        return _getSaga().getActuator().getTaskEvents(_page, _size);
    };
    public query func ictc_getTTPool() : async [(SagaTM.Ttid, SagaTM.Task)]{
        let pool = _getSaga().getActuator().getTaskPool();
        let arr = Array.map<(SagaTM.Ttid, SagaTM.Task), (SagaTM.Ttid, SagaTM.Task)>(pool, 
        func (item:(SagaTM.Ttid, SagaTM.Task)): (SagaTM.Ttid, SagaTM.Task){
            (item.0, item.1);
        });
        return arr;
    };
    public query func ictc_getTTErrors(_page: Nat, _size: Nat) : async {data: [(Nat, SagaTM.ErrorLog)]; totalPage: Nat; total: Nat}{
        return _getSaga().getActuator().getErrorLogs(_page, _size);
    };
    public query func ictc_getCalleeStatus(_callee: Principal) : async ?SagaTM.CalleeStatus{
        return _getSaga().getActuator().calleeStatus(_callee);
    };

    // Transaction Governance
    public shared(msg) func ictc_clearLog(_expiration: ?Int, _delForced: Bool) : async (){ // Warning: Execute this method with caution
        assert(_onlyOwner(msg.caller));
        _getSaga().clear(_expiration, _delForced);
    };
    public shared(msg) func ictc_clearTTPool() : async (){ // Warning: Execute this method with caution
        assert(_onlyOwner(msg.caller));
        _getSaga().getActuator().clearTasks();
    };
    public shared(msg) func ictc_blockTO(_toid: SagaTM.Toid) : async ?SagaTM.Toid{
        assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller));
        assert(not(_onlyBlocking(_toid)));
        let saga = _getSaga();
        return saga.block(_toid);
    };
    // public shared(msg) func ictc_removeTT(_toid: SagaTM.Toid, _ttid: SagaTM.Ttid) : async ?SagaTM.Ttid{ // Warning: Execute this method with caution
    //     assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller));
    //     assert(_onlyBlocking(_toid));
    //     let saga = _getSaga();
    //     saga.open(_toid);
    //     let ttid = saga.remove(_toid, _ttid);
    //     saga.close(_toid);
    //     return ttid;
    // };
    public shared(msg) func ictc_appendTT(_businessId: ?Blob, _toid: SagaTM.Toid, _forTtid: ?SagaTM.Ttid, _callee: Principal, _callType: SagaTM.CallType, _preTtids: [SagaTM.Ttid]) : async SagaTM.Ttid{
        // Governance or manual compensation (operation allowed only when a transaction order is in blocking status).
        assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller));
        assert(_onlyBlocking(_toid));
        let saga = _getSaga();
        saga.open(_toid);
        let taskRequest = _buildTask(_businessId, _callee, _callType, _preTtids, 0);
        //let ttid = saga.append(_toid, taskRequest, null, null);
        let ttid = saga.appendComp(_toid, Option.get(_forTtid, 0), taskRequest, null);
        return ttid;
    };
    /// Try the task again
    public shared(msg) func ictc_redoTT(_toid: SagaTM.Toid, _ttid: SagaTM.Ttid) : async ?SagaTM.Ttid{
        // Warning: proceed with caution!
        assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller));
        let saga = _getSaga();
        let ttid = saga.redo(_toid, _ttid);
        await* _ictcSagaRun(_toid, true);
        return ttid;
    };
    /// set status of pending task
    public shared(msg) func ictc_doneTT(_toid: SagaTM.Toid, _ttid: SagaTM.Ttid, _toCallback: Bool) : async ?SagaTM.Ttid{
        // Warning: proceed with caution!
        assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller));
        let saga = _getSaga();
        try{
            let ttid = await* saga.taskDone(_toid, _ttid, _toCallback);
            return ttid;
        }catch(e){
            throw Error.reject("420: internal call error: "# Error.message(e)); 
        };
    };
    /// set status of pending order
    public shared(msg) func ictc_doneTO(_toid: SagaTM.Toid, _status: SagaTM.OrderStatus, _toCallback: Bool) : async Bool{
        // Warning: proceed with caution!
        assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller));
        let saga = _getSaga();
        saga.close(_toid);
        try{
            let res = await* saga.done(_toid, _status, _toCallback);
            return res;
        }catch(e){
            throw Error.reject("420: internal call error: "# Error.message(e)); 
        };
    };
    /// Complete blocking order
    public shared(msg) func ictc_completeTO(_toid: SagaTM.Toid, _status: SagaTM.OrderStatus) : async Bool{
        // After governance or manual compensations, this method needs to be called to complete the transaction order.
        assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller));
        assert(_onlyBlocking(_toid));
        let saga = _getSaga();
        saga.close(_toid);
        await* _ictcSagaRun(_toid, true);
        try{
            let r = await* _getSaga().complete(_toid, _status);
            return r;
        }catch(e){
            throw Error.reject("430: ICTC error: "# Error.message(e)); 
        };
    };
    public shared(msg) func ictc_runTO(_toid: SagaTM.Toid) : async ?SagaTM.OrderStatus{
        assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller));
        let saga = _getSaga();
        saga.close(_toid);
        try{
            countAsyncMessage += 2;
            let r = await saga.run(_toid);
            countAsyncMessage -= Nat.min(2, countAsyncMessage);
            return r;
        }catch(e){
            countAsyncMessage -= Nat.min(2, countAsyncMessage);
            throw Error.reject("430: ICTC error: "# Error.message(e)); 
        };
    };
    public shared(msg) func ictc_runTT() : async Bool{ 
        // There is no need to call it normally, but can be called if you want to execute tasks in time when a TO is in the Doing state.
        assert(_onlyOwner(msg.caller) or _onlyIctcAdmin(msg.caller) or _notPaused());
        if (not(_checkAsyncMessageLimit())){
            throw Error.reject("405: IC network is busy, please try again later."); 
        };
        // _sessionPush(msg.caller);
        let saga = _getSaga();
        if (_onlyOwner(msg.caller)){
            await* _ictcSagaRun(0, true);
        } else if (Time.now() > lastSagaRunningTime + ICTC_RUN_INTERVAL*ns_){ 
            await* _ictcSagaRun(0, false);
        };
        return true;
    };
    /**
    * End: ICTC Transaction Explorer Interface
    */

    /* ===========================
      DRC207 section
    ============================== */
    public query func drc207() : async DRC207.DRC207Support{
        return {
            monitorable_by_self = false;
            monitorable_by_blackhole = { allowed = true; canister_id = ?Principal.fromText("7hdtw-jqaaa-aaaak-aaccq-cai"); };
            cycles_receivable = true;
            timer = { enable = false; interval_seconds = null; }; 
        };
    };
    /// canister_status
    // public shared(msg) func canister_status() : async DRC207.canister_status {
    //     // _sessionPush(msg.caller);
    //     // if (_tps(15, null).1 > setting.MAX_TPS*5 or _tps(15, ?msg.caller).0 > 2){ 
    //     //     assert(false); 
    //     // };
    //     let ic : DRC207.IC = actor("aaaaa-aa");
    //     await ic.canister_status({ canister_id = Principal.fromActor(this) });
    // };
    // receive cycles
    public func wallet_receive(): async (){
        let amout = Cycles.available();
        let accepted = Cycles.accept(amout);
    };
    /// timer tick
    // public shared(msg) func timer_tick(): async (){
    //     //
    // };

    private func timerLoop() : async (){
        gasPrice := await* _fetchGasPrice();
        ethBlockNumber := (await* _fetchBlockNumber(), _now());
    };
    private var timerId: Nat = 0;
    public shared(msg) func timerStart(_intervalSeconds: Nat): async (){
        assert(_onlyOwner(msg.caller));
        Timer.cancelTimer(timerId);
        timerId := Timer.recurringTimer(#seconds(_intervalSeconds), timerLoop);
    };
    public shared(msg) func timerStop(): async (){
        assert(_onlyOwner(msg.caller));
        Timer.cancelTimer(timerId);
    };

    /* ===========================
      Upgrade section
    ============================== */
    private stable var __sagaDataNew: ?SagaTM.Data = null;
    system func preupgrade() {
        let data = _getSaga().getData();
        __sagaDataNew := ?data;
        // assert(List.size(data.actuator.tasks.0) == 0 and List.size(data.actuator.tasks.1) == 0);
        Timer.cancelTimer(timerId);
    };
    system func postupgrade() {
        switch(__sagaDataNew){
            case(?(data)){
                _getSaga().setData(data);
                __sagaDataNew := null;
            };
            case(_){};
        };
        timerId := Timer.recurringTimer(#seconds(3600*2), timerLoop);
    };

};