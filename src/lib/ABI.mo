import Nat "mo:base/Nat";
import Nat64 "mo:base/Nat64";
import Buffer "mo:base/Buffer";
import Array "mo:base/Array";
import Text "mo:base/Text";
import Option "mo:base/Option";
import Binary "icl/Binary";
import Hex "icl/Hex";

module {
    type EthAccount = [Nat8];
    type BigNat = (Nat64, Nat64, Nat64, Nat64);
    private func _toBigNat(_nat: Nat) : BigNat{
        let A1: Nat64 = Nat64.fromNat(_nat / (2**192));
        let _nat2: Nat = (_nat - Nat64.toNat(A1) * (2**192));
        let A2: Nat64 = Nat64.fromNat(_nat2 / (2**128));
        let _nat3: Nat = (_nat2 - Nat64.toNat(A2) * (2**128));
        let A3: Nat64 = Nat64.fromNat(_nat3 / (2**64));
        let A4: Nat64 = Nat64.fromNat(_nat3 - Nat64.toNat(A3) * (2**64));
        return (A1, A2, A3, A4);
    };
    private func _toNat(_bignat: BigNat) : Nat{
        return Nat64.toNat(_bignat.0) * (2**192) + Nat64.toNat(_bignat.1) * (2**128) + Nat64.toNat(_bignat.2) * (2**64) + Nat64.toNat(_bignat.3);
    };

    // **********Tools************

    public func arrayAppend<T>(a: [T], b: [T]) : [T]{
        let buffer = Buffer.Buffer<T>(1);
        for (t in a.vals()){
            buffer.add(t);
        };
        for (t in b.vals()){
            buffer.add(t);
        };
        return Buffer.toArray(buffer);
    };
    public func slice<T>(a: [T], from: Nat, to: ?Nat): [T]{
        let len = a.size();
        if (len == 0) { return []; };
        var to_: Nat = Option.get(to, Nat.sub(len, 1));
        if (len <= to_){ to_ := len - 1; };
        var na: [T] = [];
        var i: Nat = from;
        while ( i <= to_ ){
            na := arrayAppend(na, Array.make(a[i]));
            i += 1;
        };
        return na;
    };

    public func shrinkBytes(_data: [Nat8]) : [Nat8]{
        var ret = _data;
        while (ret.size() > 1 and ret[0] == 0){
            ret := slice(ret, 1, null);
        };
        return ret;
    };
    public func shrink(_data: [Nat8]) : [Nat8]{
        var ret = _data;
        while (ret.size() > 0 and ret[0] == 0){
            ret := slice(ret, 1, null);
        };
        return ret;
    };
    public func toBytes32(_data: [Nat8]) : [Nat8]{
        var ret = _data;
        while (ret.size() < 32){
            ret := arrayAppend([0:Nat8], ret);
        };
        return ret;
    };

    public func toHex(_data: [Nat8]) : Text{
        return "0x"#Hex.encode(_data);
    };
    public func fromHex(_hexWith0x: Text) : ?[Nat8]{
        if (_hexWith0x.size() >= 2){
            var hex = Option.get(Text.stripStart(_hexWith0x, #text("0x")), _hexWith0x);
            if (hex.size() % 2 > 0){ hex := "0"#hex; };
            if (hex == "") { return ?[] };
            switch(Hex.decode(hex)){
                case(#ok(r)){ return ?r; };
                case(_){ return null; };
            };
        };
        return null;
    };

    // **********ABI************

    public func fromNat(_nat: Nat) : [Nat8]{
        let bignat = _toBigNat(_nat);
        let b0 = Binary.BigEndian.fromNat64(bignat.0);
        let b1 = Binary.BigEndian.fromNat64(bignat.1);
        let b2 = Binary.BigEndian.fromNat64(bignat.2);
        let b3 = Binary.BigEndian.fromNat64(bignat.3);
        return arrayAppend(arrayAppend(b0, b1), arrayAppend(b2, b3));
    };
    public func toNat(_data: [Nat8]) : Nat{
        assert(_data.size() == 32);
        let b0 = slice(_data, 0, ?7);
        let b1 = slice(_data, 8, ?15);
        let b2 = slice(_data, 16, ?23);
        let b3 = slice(_data, 24, ?31);
        let bignat : BigNat = (
            Binary.BigEndian.toNat64(b0), 
            Binary.BigEndian.toNat64(b1), 
            Binary.BigEndian.toNat64(b2), 
            Binary.BigEndian.toNat64(b3)
        );
        return _toNat(bignat);
    };
    public func natToHex(_n: Nat) : Text{
        return toHex(shrinkBytes(fromNat(_n)));
    };

    public func addressABIEncode(_account: EthAccount) : [Nat8]{
        assert(_account.size() == 20);
        return toBytes32(_account);
    };
    public func addressABIDecode(_data: [Nat8]) : EthAccount{
        assert(_data.size() == 32);
        return shrinkBytes(_data);
    };

};
