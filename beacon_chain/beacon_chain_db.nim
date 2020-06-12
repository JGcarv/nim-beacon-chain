{.push raises: [Defect].}

import
  typetraits, stew/[results, endians2],
  serialization, chronicles,
  eth/db/kvstore,
  faststreams,
  persistent_store, sequtils,
  ./spec/[datatypes, digest, crypto],
  ./ssz/[ssz_serialization, merkleization], ./state_transition

type
  BeaconChainDB* = ref object
    ## Database storing resolved blocks and states - resolved blocks are such
    ## blocks that form a chain back to the tail block.
    ##
    ## We assume that the database backend is working / not corrupt - as such,
    ## we will raise a Defect any time there is an issue. This should be
    ## revisited in the future, when/if the calling code safely can handle
    ## corruption of this kind.
    ##
    ## We do however make an effort not to crash on invalid data inside the
    ## database - this may have a number of "natural" causes such as switching
    ## between different versions of the client and accidentally using an old
    ## database.
    backend: KvStoreRef
    persistent: PersistentStore

  DbKeyKind = enum
    kHashToState
    kHashToBlock
    kHeadBlock # Pointer to the most recent block selected by the fork choice
    kTailBlock ##\
    ## Pointer to the earliest finalized block - this is the genesis block when
    ## the chain starts, but might advance as the database gets pruned
    ## TODO: determine how aggressively the database should be pruned. For a
    ##       healthy network sync, we probably need to store blocks at least
    ##       past the weak subjectivity period.
    kBlockSlotStateRoot ## BlockSlot -> state_root mapping
    kBlockHashToSlot

# Subkeys essentially create "tables" within the key-value store by prefixing
# each entry with a table id

func subkey(kind: DbKeyKind): array[1, byte] =
  result[0] = byte ord(kind)

func subkey[N: static int](kind: DbKeyKind, key: array[N, byte]):
    array[N + 1, byte] =
  result[0] = byte ord(kind)
  result[1 .. ^1] = key

func subkey(kind: type BeaconState, key: Eth2Digest): auto =
  subkey(kHashToState, key.data)

func subkey(kind: type SignedBeaconBlock, key: Eth2Digest): auto =
  subkey(kHashToBlock, key.data)

func subkey(kind: type Eth2Digest, key: Eth2Digest): auto =
  subkey(kBlockHashToSlot, key.data)

func subkey(root: Eth2Digest, slot: Slot): array[40, byte] =
  var ret: array[40, byte]
  # big endian to get a naturally ascending order on slots in sorted indices
  ret[0..<8] = toBytesBE(slot.uint64)
  # .. but 7 bytes should be enough for slots - in return, we get a nicely
  # rounded key length
  ret[0] = byte ord(kBlockSlotStateRoot)
  ret[8..<40] = root.data

  ret

proc init*(T: type BeaconChainDB, backend: KVStoreRef): BeaconChainDB =
  var persistent: PersistentStore
  try:
    persistent = PersistentStore.init()
  except Exception:
    warn "Unable to create cold storage files"
  T(backend: backend, persistent:persistent)

proc put(db: BeaconChainDB, key: openArray[byte], v: auto) =
  db.backend.put(key, SSZ.encode(v)).expect("working database")

proc get(db: BeaconChainDB, key: openArray[byte], T: typedesc): Opt[T] =
  var res: Opt[T]
  proc decode(data: openArray[byte]) =
    try:
      res.ok SSZ.decode(data, T)
    except SerializationError as e:
      # If the data can't be deserialized, it could be because it's from a
      # version of the software that uses a different SSZ encoding
      warn "Unable to deserialize data, old database?",
        err = e.msg, typ = name(T), dataLen = data.len
      discard

  discard db.backend.get(key, decode).expect("working database")

  res

proc putBlock*(db: BeaconChainDB, key: Eth2Digest, value: SignedBeaconBlock) =
  db.put(subkey(type value, key), value)

proc putState*(db: BeaconChainDB, key: Eth2Digest, value: BeaconState) =
  # TODO prune old states - this is less easy than it seems as we never know
  #      when or if a particular state will become finalized.

  db.put(subkey(type value, key), value)

proc putState*(db: BeaconChainDB, value: BeaconState) =
  db.putState(hash_tree_root(value), value)

proc putStateRoot*(db: BeaconChainDB, root: Eth2Digest, slot: Slot,
    value: Eth2Digest) =
  db.backend.put(subkey(root, slot), value.data).expect(
    "working database")

proc putBlock*(db: BeaconChainDB, value: SignedBeaconBlock) =
  db.putBlock(hash_tree_root(value.message), value)

proc delBlock*(db: BeaconChainDB, key: Eth2Digest) =
  db.backend.del(subkey(SignedBeaconBlock, key)).expect(
    "working database")

proc delState*(db: BeaconChainDB, key: Eth2Digest) =
  db.backend.del(subkey(BeaconState, key)).expect("working database")

proc delStateRoot*(db: BeaconChainDB, root: Eth2Digest, slot: Slot) =
  db.backend.del(subkey(root, slot)).expect("working database")

proc putHeadBlock*(db: BeaconChainDB, key: Eth2Digest) =
  db.backend.put(subkey(kHeadBlock), key.data).expect("working database")

proc putTailBlock*(db: BeaconChainDB, key: Eth2Digest) =
  db.backend.put(subkey(kTailBlock), key.data).expect("working database")

proc getState*(
    db: BeaconChainDB, key: Eth2Digest, output: var BeaconState,
    rollback: RollbackProc): bool =
  ## Load state into `output` - BeaconState is large so we want to avoid
  ## re-allocating it if possible
  ## Return `true` iff the entry was found in the database and `output` was
  ## overwritten.
  # TODO rollback is needed to deal with bug - use `noRollback` to ignore:
  #      https://github.com/nim-lang/Nim/issues/14126
  # TODO RVO is inefficient for large objects:
  #      https://github.com/nim-lang/Nim/issues/13879
  # TODO address is needed because there's no way to express lifetimes in nim
  #      we'll use unsafeAddr to find the code later
  let outputAddr = unsafeAddr output # callback is local
  proc decode(data: openArray[byte]) =
    try:
      # TODO can't write to output directly..
      outputAddr[] = SSZ.decode(data, BeaconState)
    except SerializationError as e:
      # If the data can't be deserialized, it could be because it's from a
      # version of the software that uses a different SSZ encoding
      warn "Unable to deserialize data, old database?", err = e.msg
      rollback(outputAddr[])

  db.backend.get(subkey(BeaconState, key), decode).expect("working database")

proc getStateRoot*(db: BeaconChainDB,
                   root: Eth2Digest,
                   slot: Slot): Opt[Eth2Digest] =
  db.get(subkey(root, slot), Eth2Digest)

proc getHeadBlock*(db: BeaconChainDB): Opt[Eth2Digest] =
  db.get(subkey(kHeadBlock), Eth2Digest)

proc getTailBlock*(db: BeaconChainDB): Opt[Eth2Digest] =
  db.get(subkey(kTailBlock), Eth2Digest)

proc containsBlock*(db: BeaconChainDB, key: Eth2Digest): bool =
  db.backend.contains(subkey(SignedBeaconBlock, key)).expect("working database")

proc containsState*(db: BeaconChainDB, key: Eth2Digest): bool =
  db.backend.contains(subkey(BeaconState, key)).expect("working database")

proc read(fn: string, offset,len: uint64, T:type): Opt[T] =
  var res: Opt[T]
  try:
    fn.read(offset, len) do (data: openArray[byte]):
      res.ok SSZ.decode(data, T)
  except Exception as e:
    warn "Unable to deserialize data, old database?", err = e.msg
  res

proc getPersistentBlock*(db: BeaconChainDB, slot: Slot): Opt[SignedBeaconBlock] =
  let uintsize = uint64 sizeof(uint64)
  let indices_offset = slot * uintsize
  var offset = db.persistent.indices.read(indices_offset, uintsize,uint64)
  var len = db.persistent.storage.read(offset.get, uintsize, uint64)
  var value = db.persistent.storage.read(offset.get + uintsize, len.get, SignedBeaconBlock)
  value

proc putPersistentBlock*(db: BeaconChainDB, value:SignedBeaconBlock) =
  var headSlot, available_off: uint64
  try:
    headSlot = db.persistent.indices.getSize() div 8 - 1
    available_off = db.persistent.storage.getSize()
  except CatchableError:
    warn "Unable to read cold storage size"

  var valueStream = memoryOutput()
  var valueCursor = valueStream.delayFixedSizeWrite(sizeOf(uint64))
  var valueSszWriter = SszWriter.init(valueStream)
  let cursorStart = valueStream.pos
  
  var keyStream = memoryOutput()

  try:
    if value.message.slot > Slot(0):
      let diff = int value.message.slot - headSlot
      keyStream.write repeat(byte(0), (diff - 1) * 8)

    valueSszWriter.writeValue(value)
    
    var keySszWriter = SszWriter.init(keyStream)
    keySszWriter.writeValue(available_off)
  except IOError:
    warn "Error writing ssz"

  valueCursor.finalWrite toBytesLE(uint64 (valueStream.pos - cursorStart))

  db.backend.put(subkey(type Eth2Digest, hash_tree_root(value.message)), SSZ.encode(value.message.slot)).expect("working database")
  try:
    db.persistent.put(keyStream.getOutput, valueStream.getOutput)
  except Exception:
    warn "Unable to write to cold storage"
    

proc getBlock*(db: BeaconChainDB, key: Eth2Digest): Opt[SignedBeaconBlock] =
  if(db.containsBlock(key)):
    return db.get(subkey(SignedBeaconBlock, key), SignedBeaconBlock)
  var slot = db.get(subkey(Eth2Digest, key), uint64)

  if slot.isSome():
    return db.getPersistentBlock(Slot(slot.get))

proc getFinalizedBlock*(db: BeaconChainDB, key: Slot): Opt[SignedBeaconBlock] =
  db.getPersistentBlock(key)

proc isFinalized*(db: BeaconChainDB, key: Eth2Digest): bool =
  db.backend.contains(subkey(Eth2Digest, key)).expect("working database")

proc getSlotForRoot(db: BeaconChainDB, key: Eth2Digest): Option[Slot] =
  let slot = db.get(subkey(Eth2Digest, key), uint64)
  if slot.isSome:
    return some(Slot(slot.get))

  none(Slot)

iterator getAncestors*(db: BeaconChainDB, root: Eth2Digest):
    tuple[root: Eth2Digest, blck: SignedBeaconBlock] =
  ## Load a chain of ancestors for blck - returns a list of blocks with the
  ## oldest block last (blck will be at result[0]).
  ##
  ## The search will go on until the ancestor cannot be found.

  var root = root
  while (let blck = db.getBlock(root); blck.isOk()):
    yield (root, blck.get())
    root = blck.get().message.parent_root

proc pruneToPersistent*(db: BeaconChainDB, root: Eth2Digest) =
  var temp_root = newSeq[Eth2Digest](0)
  for root, blck in db.getAncestors(root):
    if(not db.containsBlock(root)):
      break
    temp_root.add(root)
  for i in countdown(temp_root.len - 1 ,0):
    let blck = db.getBlock(temp_root[i])
    if blck.isSome():
      db.putPersistentBlock(blck.get)
      db.delBlock(temp_root[i])
  