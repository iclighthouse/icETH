// 3ondx-siaaa-aaaam-abf3q-cai

module {
  public type HttpHeader = { value : Text; name : Text };
  public type HttpResponse = {
    status : Nat;
    body : [Nat8];
    headers : [HttpHeader];
  };
  public type Registered = { chain_id : Nat64; api_provider : Text };
  public type Result = { #Ok : Text; #Err : Text };
  public type RpcTarget = {
    #url_with_api_key : Text;
    #registered : Registered;
  };
  public type TransformArgs = { context : [Nat8]; response : HttpResponse };
  public type Self = actor {
    add_controller : shared Principal -> async ();
    json_rpc : shared (payload: Text, max_response_bytes: Nat64, target: RpcTarget) -> async Result;
    register_api_key : shared (chain_id: Nat64, api_provider: Text, url_with_key: Text) -> async ();
    registrations : shared query () -> async [Registered];
    transform : shared query TransformArgs -> async HttpResponse;
  }
}