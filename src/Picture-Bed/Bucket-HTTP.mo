import TrieMap "mo:base/TrieMap";
import Result "mo:base/Result";
import Blob "mo:base/Blob";
import Array "mo:base/Array";
import Text "mo:base/Text";
import Nat64 "mo:base/Nat64";
import Nat "mo:base/Nat";
import SM "mo:base/ExperimentalStableMemory";
import Prim "mo:⛔";

module {

    public type Error = {
        #INSUFFICIENT_MEMORY;
        #BlobSizeError;
        #INVALID_KEY;
    };

    public type HeaderField = (Text, Text);
    public type StreamingCallbackHttpResponse = {
        body: Blob;
        token: ?Token;
    };
    public type Token = {};
    public type StreamingStrategy = {
        #Callback: {
            callback: query (Token) -> async(StreamingCallbackHttpResponse);
            token: Token;
        }
    };
    public type HttpRequest = {
        method: Text;
        url: Text;
        headers: [HeaderField];
        body: Blob;
    };
    public type HttpResponse = {
        status_code: Nat16;
        headers: [HeaderField];
        body: Blob;
        streaming_strategy: ?StreamingStrategy;
    };
    
    public type DecodeUrl = (Text) -> (Text);
    
    public class BucketHttp(upgradable : Bool) {
        private let THRESHOLD               = 6442450944;
        // MAX_PAGE_SIZE = 8 GB(total size of stable memory currently) / 64 KB(each page size = 64 KB)
        private let MAX_PAGE_BYTE           = 65536;
        private let MAX_PAGE_NUMBER         = 131072 : Nat64;
        private let MAX_QUERY_SIZE          = 3144728;
        private var offset                  = 8; // 0 - 7 is used for offset
        private var decodeurl: ?DecodeUrl   = null;
        var assets = TrieMap.TrieMap<Text, [(Nat64, Nat)]>(Text.equal, Text.hash);

        public func put(key: Text, value : Blob): Result.Result<(), Error> {
            switch(_getField(value.size())) {
                case(#ok(field)) {
                    switch(assets.get(key)){
                        case null {
                            assets.put(key, [field]);
                        };
                        case(?pre_field){
                            let present_field = Array.append<(Nat64, Nat)>(pre_field, [field]);
                            assets.put(key, present_field);
                        };
                    };
                    _storageData(field.0, value);
                };
                case(#err(err)) { return #err(err) };
            };
            #ok(())
        };

        public func get(key: Text): Result.Result<[Blob], Error> {
            switch(assets.get(key)) {
                case(null) { return #err(#INVALID_KEY) };
                case(?field) {
                    let res = Array.init<Blob>(field.size(), "":Blob);
                    var index = 0;
                    for(f in field.vals()){
                        res[index] := _loadFromSM(f);
                        index += 1;
                    };
                    #ok(Array.freeze<Blob>(res))
                };
            };
        };

        public func http_request(request: HttpRequest): HttpResponse {
            switch(decodeurl) {
                case(null) { return errStaticpage("decodeurl wrong");};
                case(?getkey) {
                    let key = getkey(request.url);
                    switch(get(key)) {
                        case(#err(err)) { return errStaticpage("get wrong");};
                        case(#ok(ans)) {
                            let number = ans.size();
                            if(number == 1) {
                                let payload = ans[0];
                                return {
                                    status_code = 200;
                                    headers = [("Content-Type", "text/plain"), ("Content-Length", Nat.toText(payload.size()))];
                                    streaming_strategy = null;
                                    body = payload;
                                };
                            };
                        };
                    };                    
                };
            };
            errStaticpage("somting wrong")
        };

        public func build_http(fn_: DecodeUrl): () {
            decodeurl := ?fn_;
        };
        
        // return entries
        public func preupgrade(): [(Text, [(Nat64, Nat)])] {
            SM.storeNat64(0 : Nat64, Nat64.fromNat(offset));
            var index = 0;
            var assets_entries = Array.init<(Text, [(Nat64, Nat)])>(assets.size(), ("", []));
            for (kv in assets.entries()) {
                assets_entries[index] := kv;
                index += 1;
            };
            Array.freeze<(Text, [(Nat64, Nat)])>(assets_entries)
        };

        public func postupgrade(entries : [(Text, [(Nat64, Nat)])]): () {
            offset := Nat64.toNat(SM.loadNat64(0:Nat64));
            assets := TrieMap.fromEntries<Text, [(Nat64, Nat)]>(entries.vals(), Text.equal, Text.hash);
        };

        private func _loadFromSM(field : (Nat64, Nat)) : Blob {
            SM.loadBlob(field.0, field.1)
        };

        private func _getField(total_size : Nat) : Result.Result<(Nat64, Nat), Error> {
            switch (_inspectSize(total_size)) {
                case (#err(err)) { #err(err) };
                case (#ok(_)) {
                    let field = (Nat64.fromNat(offset), total_size);
                    _growStableMemoryPage(total_size);
                    offset += total_size;
                    #ok(field)
                };
            }
        };

        // check total_size
        private func _inspectSize(total_size : Nat) : Result.Result<(), Error> {
            if (total_size <= _getAvailableMemorySize()) { #ok(()) } else { #err(#INSUFFICIENT_MEMORY) };
        };

        // upload时根据分配好的write_page以vals的形式写入数据
        // When uploading, write data in the form of vals according to the assigned write_page
        private func _storageData(start : Nat64, data : Blob) {
            SM.storeBlob(start, data)
        };

        // return available memory size can be allocated
        private func _getAvailableMemorySize() : Nat{
            if(upgradable){
                assert(THRESHOLD >= Prim.rts_memory_size() + offset);
                THRESHOLD - Prim.rts_memory_size() - offset
            }else{
                THRESHOLD - offset
            }
        };

        // grow SM memory pages of size "size"
        private func _growStableMemoryPage(size : Nat) {
            if(offset == 8){ ignore SM.grow(1 : Nat64) };
            let available_mem : Nat = Nat64.toNat(SM.size()) * MAX_PAGE_BYTE + 1 - offset;
            if (available_mem < size) {
                let need_allo_size : Nat = size - available_mem;
                let growPage = Nat64.fromNat(need_allo_size / MAX_PAGE_BYTE + 1);
                ignore SM.grow(growPage);
            }
        };

        private func errStaticpage(err: Text): HttpResponse {
            {
                status_code = 404;
                headers = [("Content-Type", "text/plain")];
                body = Text.encodeUtf8(err);
                streaming_strategy = null;
            }
        };

    };
};
