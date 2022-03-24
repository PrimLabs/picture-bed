import BucketHttp "Bucket-HTTP";
import Blob "mo:base/Blob";
import Text "mo:base/Text";
import Array "mo:base/Array";
import Result "mo:base/Result";
import Iter "mo:base/Iter";
import Nat "mo:base/Nat";
import Debug "mo:base/Debug";
import SM "mo:base/ExperimentalStableMemory";
import TrieSet "mo:base/TrieSet";
import Principal "mo:base/Principal";


shared(initralizer) actor class PictureBed(owner: [Principal]) = this{

    type HttpRequest = BucketHttp.HttpRequest; 
    type HttpResponse = BucketHttp.HttpResponse;
    type Error = {
        #NotAdmin;
        #INSUFFICIENT_MEMORY;
        #BlobSizeError;
        #INVALID_KEY;
    };

    stable var entries : [(Text, [(Nat64, Nat)])] = [];
    stable var admin_entries: [Principal] = [];
    var admin = TrieSet.fromArray<Principal>(owner, Principal.hash, Principal.equal);
    let bucket = BucketHttp.BucketHttp(true); // true : upgradable, false : unupgradable
    
    //host/static/<photo_id>
    private func decodeurl(url: Text): Text {
        let path = Iter.toArray(Text.tokens(url, #text("/")));
        if(path.size() == 2 and path[0] == "static") {
            return path[1];
        };
        return "Wrong key";
    };

    public shared({caller}) func putImg(key: Text,value: Blob) : async Result.Result<(), Error>{
        if(TrieSet.mem<Principal>(admin, caller, Principal.hash(caller), Principal.equal) == false) return #err(#NotAdmin);
        switch(bucket.put(key, value)){
            case(#err(e)){ return #err(e) };
            case(_){};
        };
        #ok(())
    };

    public shared({caller}) func build_http(): async Bool{
        if(TrieSet.mem<Principal>(admin, caller, Principal.hash(caller), Principal.equal) == false) return false;
        bucket.build_http(decodeurl);
        true
    };

    public shared({caller}) func addowner(newowner: Principal): async Bool {
        if(TrieSet.mem<Principal>(admin, caller, Principal.hash(caller), Principal.equal) == false) return false;
        admin := TrieSet.put<Principal>(admin, newowner, Principal.hash(newowner), Principal.equal);
        true
    };

    public query({caller}) func getImg(key: Text) : async Result.Result<[Blob], Error>{
        switch(bucket.get(key)){
            case(#err(e)){ #err(e) };
            case(#ok(blob)){
                #ok(blob)
            }
        }
    };
        
    public query func http_request(request: HttpRequest): async HttpResponse {
        bucket.http_request(request)
    };

    system func preupgrade(){
        entries := bucket.preupgrade();
        admin_entries := TrieSet.toArray<Principal>(admin);
    };

    system func postupgrade(){
        bucket.postupgrade(entries);
        entries := [];
        admin := TrieSet.fromArray<Principal>(admin_entries, Principal.hash, Principal.equal);
        admin_entries  := [];
    };

}
