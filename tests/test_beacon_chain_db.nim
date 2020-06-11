# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or https://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or https://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import  options, unittest, sequtils,
  ../beacon_chain/[beacon_chain_db, extras, interop, ssz, state_transition],
  ../beacon_chain/spec/[beaconstate, datatypes, digest, crypto],
  eth/db/kvstore,
  # test utilies
  ./testutil, ./testblockutil

proc getStateRef(db: BeaconChainDB, root: Eth2Digest): NilableBeaconStateRef =
  # load beaconstate the way BlockPool does it - into an existing instance
  let res = BeaconStateRef()
  if db.getState(root, res[], noRollback):
    return res

template wrappedTimedTest(name: string, body: untyped) =
  # `check` macro takes a copy of whatever it's checking, on the stack!
  block: # Symbol namespacing
    proc wrappedTest() =
      timedTest name:
        body
    wrappedTest()

suiteReport "Beacon chain DB" & preset():
  wrappedTimedTest "empty database" & preset():
    var
      db = init(BeaconChainDB, kvStore MemStoreRef.init())
    check:
      db.getStateRef(Eth2Digest()).isNil
      db.getBlock(Eth2Digest()).isNone

  wrappedTimedTest "sanity check blocks" & preset():
    var
      db = init(BeaconChainDB, kvStore MemStoreRef.init())

    let
      signedBlock = SignedBeaconBlock()
      root = hash_tree_root(signedBlock.message)

    db.putBlock(signedBlock)

    check:
      db.containsBlock(root)
      db.getBlock(root).get() == signedBlock

    db.putStateRoot(root, signedBlock.message.slot, root)
    check:
      db.getStateRoot(root, signedBlock.message.slot).get() == root

  wrappedTimedTest "sanity check states" & preset():
    var
      db = init(BeaconChainDB, kvStore MemStoreRef.init())

    let
      state = BeaconStateRef()
      root = hash_tree_root(state[])

    db.putState(state[])

    check:
      db.containsState(root)
      hash_tree_root(db.getStateRef(root)[]) == root

  wrappedTimedTest "find ancestors" & preset():
    var
      db = init(BeaconChainDB, kvStore MemStoreRef.init())

    let
      a0 = SignedBeaconBlock(message: BeaconBlock(slot: GENESIS_SLOT + 0))
      a0r = hash_tree_root(a0.message)
      a1 = SignedBeaconBlock(message:
        BeaconBlock(slot: GENESIS_SLOT + 1, parent_root: a0r))
      a1r = hash_tree_root(a1.message)
      a2 = SignedBeaconBlock(message:
        BeaconBlock(slot: GENESIS_SLOT + 2, parent_root: a1r))
      a2r = hash_tree_root(a2.message)

    doAssert toSeq(db.getAncestors(a0r)) == []
    doAssert toSeq(db.getAncestors(a2r)) == []

    db.putBlock(a2)

    doAssert toSeq(db.getAncestors(a0r)) == []
    doAssert toSeq(db.getAncestors(a2r)) == [(a2r, a2)]

    db.putBlock(a1)

    doAssert toSeq(db.getAncestors(a0r)) == []
    doAssert toSeq(db.getAncestors(a2r)) == [(a2r, a2), (a1r, a1)]

    db.putBlock(a0)

    doAssert toSeq(db.getAncestors(a0r)) == [(a0r, a0)]
    doAssert toSeq(db.getAncestors(a2r)) == [(a2r, a2), (a1r, a1), (a0r, a0)]

  wrappedTimedTest "cold storage" & preset():
    var
      db = init(BeaconChainDB, kvStore MemStoreRef.init())
    
    let
      a0 = SignedBeaconBlock(message: BeaconBlock(slot: GENESIS_SLOT + 0))
      a0r = hash_tree_root(a0.message)
      a1 = SignedBeaconBlock(message:
        BeaconBlock(slot: GENESIS_SLOT + 1, parent_root: a0r))
      a1r = hash_tree_root(a1.message)
      a2 = SignedBeaconBlock(message:
        BeaconBlock(slot: GENESIS_SLOT + 3, parent_root: a1r))
      a2r = hash_tree_root(a2.message)
    
    db.putPersistentBlock(a0)
    db.putPersistentBlock(a1)
    db.putPersistentBlock(a2)

    let blck = db.getBlock(hash_tree_root(a1.message)).get
    check:
      blck.message.parent_root == a0r

    let blck2 = db.getFinalizedBlock(Slot(3)).get
    check:
      blck2.message.parent_root == a1r

  wrappedTimedTest "pruning db to persistent storage" & preset():
    var
      db = init(BeaconChainDB, kvStore MemStoreRef.init())
    
    let
      a0 = SignedBeaconBlock(message: BeaconBlock(slot: GENESIS_SLOT + 0))
      a0r = hash_tree_root(a0.message)
      a1 = SignedBeaconBlock(message:
        BeaconBlock(slot: GENESIS_SLOT + 1, parent_root: a0r))
      a1r = hash_tree_root(a1.message)
      a2 = SignedBeaconBlock(message:
        BeaconBlock(slot: GENESIS_SLOT + 3, parent_root: a1r))
      a2r = hash_tree_root(a2.message)

    db.putBlock(a0)
    db.putBlock(a1)
    db.putBlock(a2)

    db.pruneToPersistent(a2r)

    check:
      db.isFinalized(a0r)
      db.isFinalized(a1r)
      db.isFinalized(a2r)
      #Blocks shouldn't be on kvStore
      not db.containsBlock(a0r)
      not db.containsBlock(a1r)
      not db.containsBlock(a2r)

    let blck0 = db.getBlock(hash_tree_root(a0.message)).get
    let blck1 = db.getBlock(hash_tree_root(a1.message)).get
    let blck2 = db.getBlock(hash_tree_root(a2.message)).get
    
    check:
      hash_tree_root(blck0.message) == a0r
      hash_tree_root(blck1.message) == a1r
      hash_tree_root(blck2.message) == a2r

    

  wrappedTimedTest "sanity check genesis roundtrip" & preset():
    # This is a really dumb way of checking that we can roundtrip a genesis
    # state. We've been bit by this because we've had a bug in the BLS
    # serialization where an all-zero default-initialized bls signature could
    # not be deserialized because the deserialization was too strict.
    var
      db = init(BeaconChainDB, kvStore MemStoreRef.init())

    let
      state = initialize_beacon_state_from_eth1(
        eth1BlockHash, 0, makeInitialDeposits(SLOTS_PER_EPOCH), {skipBlsValidation})
      root = hash_tree_root(state[])

    db.putState(state[])

    check db.containsState(root)
    let state2 = db.getStateRef(root)

    check:
      hash_tree_root(state2[]) == root
