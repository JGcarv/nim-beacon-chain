# beacon_chain
# Copyright (c) 2018-Present Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  # Standard library
  os, unittest, strutils,
  # Beacon chain internals
  ../../beacon_chain/spec/[datatypes, validator, state_transition_epoch],
  # Test utilities
  ../testutil,
  ./fixtures_utils,
  ../helpers/debug_state

from ../../beacon_chain/spec/beaconstate import process_registry_updates
  # XXX: move to state_transition_epoch?

# TODO: parsing SSZ
#       can overwrite the calling function stack
#       https://github.com/status-im/nim-beacon-chain/issues/369
#
# We store the state on the heap to avoid that

template runSuite(suiteDir, testName: string, transitionProc: untyped{ident}, useCache: static bool): untyped =
  # We wrap the tests in a proc to avoid running out of globals
  # in the future: Nim supports up to 3500 globals
  # but unittest with the macro/templates put everything as globals
  # https://github.com/nim-lang/Nim/issues/12084#issue-486866402

  proc `suiteImpl _ transitionProc`() =
    suiteReport "Official - Epoch Processing - " & testName & preset():
      for testDir in walkDirRec(suiteDir, yieldFilter = {pcDir}):

        let unitTestName = testDir.rsplit(DirSep, 1)[1]
        timedTest testName & " - " & unitTestName & preset():
          var preState = newClone(parseTest(testDir/"pre.ssz", SSZ, BeaconState))
          let postState = newClone(parseTest(testDir/"post.ssz", SSZ, BeaconState))

          when useCache:
            var cache = get_empty_per_epoch_cache()
            transitionProc(preState[], cache)
          else:
            transitionProc(preState[])

          reportDiff(preState, postState)

  `suiteImpl _ transitionProc`()

# Justification & Finalization
# ---------------------------------------------------------------

const JustificationFinalizationDir = SszTestsDir/const_preset/"phase0"/"epoch_processing"/"justification_and_finalization"/"pyspec_tests"
runSuite(JustificationFinalizationDir, "Justification & Finalization",  process_justification_and_finalization, useCache = true)

# Rewards & Penalties
# ---------------------------------------------------------------

# No test upstream

# Registry updates
# ---------------------------------------------------------------

const RegistryUpdatesDir = SszTestsDir/const_preset/"phase0"/"epoch_processing"/"registry_updates"/"pyspec_tests"
runSuite(RegistryUpdatesDir, "Registry updates",  process_registry_updates, useCache = false)

# Slashings
# ---------------------------------------------------------------

const SlashingsDir = SszTestsDir/const_preset/"phase0"/"epoch_processing"/"slashings"/"pyspec_tests"
runSuite(SlashingsDir, "Slashings",  process_slashings, useCache = false)

# Final updates
# ---------------------------------------------------------------

const FinalUpdatesDir = SszTestsDir/const_preset/"phase0"/"epoch_processing"/"final_updates"/"pyspec_tests"
runSuite(FinalUpdatesDir, "Final updates",  process_final_updates, useCache = false)
