import TrieMap "mo:base/TrieMap";
import Result "mo:base/Result";
import Blob "mo:base/Blob";
import Array "mo:base/Array";
import Text "mo:base/Text";
import Nat64 "mo:base/Nat64";
import SM "mo:base/ExperimentalStableMemory";
import Prim "mo:⛔";

module {

    public type Error = {
        #INSUFFICIENT_MEMORY;
        #BlobSizeError;
        #INVALID_KEY;
    };

    public class Bucket(upgradable : Bool) {
        private let THRESHOLD               = 6442450944;
        // MAX_PAGE_SIZE = 8 GB(total size of stable memory currently) / 64 KB(each page size = 64 KB)
        private let PAGE_SIZE               = 131072;
        private let MAX_PAGE_NUMBER         = 131072 : Nat64;
        private let MAX_QUERY_SIZE          = 3144728;
        private var offset                  = 8; // 0 - 7 is used for offset
        var assets = TrieMap.TrieMap<Blob, [(Nat64, Nat)]>(Blob.equal, Blob.hash);

        public func put(key: Blob, value : Blob): Result.Result<(), Error> {
            switch(_getField(value.size())) {
                case(#ok(field)) {
                    switch(assets.get(key)){
                        case null {
                            assets.put(key, [field]);
                        };
                        case(?pre_field){
                            let present_field = Array.append<(Nat64, Nat)>(pre_field, [field]);
                            assets.put(key, present_field);
                        }
                    }
                };
                case(#err(err)) { return #err(err) };
            };
            #ok(())
        };

        public func get(key: Blob): Result.Result<[Blob], Error> {
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

        // return entries
        public func preupgrade(): [(Blob, [(Nat64, Nat)])] {
            SM.storeNat64(0 : Nat64, Nat64.fromNat(offset));
            var index = 0;
            var assets_entries = Array.init<(Blob, [(Nat64, Nat)])>(assets.size(), ("":Blob, []));
            for (kv in assets.entries()) {
                assets_entries[index] := kv;
                index += 1;
            };
            Array.freeze<(Blob, [(Nat64, Nat)])>(assets_entries)
        };

        public func postupgrade(entries : [var (Blob, [(Nat64, Nat)])]): () {
            offset := Nat64.toNat(SM.loadNat64(0:Nat64));
            assets := TrieMap.fromEntries<Blob, [(Nat64, Nat)]>(entries.vals(), Blob.equal, Blob.hash);
        };

        private func _loadFromSM(field : (Nat64, Nat)) : Blob {
            SM.loadBlob(field.0, field.1)
        };

        // FINISHED
        private func _getField(total_size : Nat) : Result.Result<(Nat64, Nat), Error> {
            switch (_inspectSize(total_size)) {
                case (#err(err)) { #err(err) };
                case (#ok(_)) {
                    let field = (Nat64.fromNat(offset), total_size);
                    offset += total_size;
                    #ok(field)
                };
            }
        };

        // FINISHED
        // check total_size
        private func _inspectSize(total_size : Nat) : Result.Result<(), Error> {
            if (total_size <= _getAvailableMemorySize()) { #ok(()) } else { #err(#INSUFFICIENT_MEMORY) };
        };

        // upload时根据分配好的write_page以vals的形式写入数据
        // When uploading, write data in the form of vals according to the assigned write_page
        private func _storageData(start : Nat64, data : Blob) {
            assert(Nat64.toNat(start) == data.size());
            SM.storeBlob(start, data)
        };

        // FINISHED
        // return available memory size can be allocated
        private func _getAvailableMemorySize() : Nat{
            if(upgradable){
                assert(THRESHOLD >= Prim.rts_memory_size() + offset);
                THRESHOLD - Prim.rts_memory_size() - offset
            }else{
                THRESHOLD - offset
            }
        };

        // FINISHED
        // grow SM memory pages of size "size"
        private func _growStableMemoryPage(size : Nat) {
            if(offset == 8){ ignore SM.grow(1 : Nat64) };
            let available_mem : Nat = Nat64.toNat(SM.size()) * PAGE_SIZE - offset;
            if (available_mem < size) {
                let need_allo_size : Nat = size - available_mem;
                let growPage = Nat64.fromNat(size / PAGE_SIZE + 1);
                if ((growPage + SM.size() <= MAX_PAGE_NUMBER)) {
                    ignore SM.grow(growPage);
                } else if ((growPage + SM.size() - 1 : Nat64) == MAX_PAGE_NUMBER) {
                    let newGrowPage : Nat64 = growPage - 1;
                    if (newGrowPage > 0) {
                        ignore SM.grow(newGrowPage);
                    };
                };
            };
        };

    }; 
};
