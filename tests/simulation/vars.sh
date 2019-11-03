#!/bin/bash

PWD_CMD="pwd"
# get native Windows paths on Mingw
uname | grep -qi mingw && PWD_CMD="pwd -W"

cd $(dirname $0)

SIM_ROOT="$($PWD_CMD)"

# Set a default value for the env vars usually supplied by a Makefile
cd $(git rev-parse --show-toplevel)
: ${GIT_ROOT:="$($PWD_CMD)"}
cd - &>/dev/null

# When changing these, also update the readme section on running simulation
# so that the run_node example is correct!
NUM_VALIDATORS=${VALIDATORS:-192}
NUM_NODES=${NODES:-2}
NUM_MISSING_NODES=${MISSING_NODES:-0}

SIMULATION_DIR="${SIM_ROOT}/data"
METRICS_DIR="${SIM_ROOT}/prometheus"
VALIDATORS_DIR="${SIM_ROOT}/validators"
SNAPSHOT_FILE="${SIMULATION_DIR}/state_snapshot.ssz"
NETWORK_BOOTSTRAP_FILE="${SIMULATION_DIR}/bootstrap_nodes.txt"
BEACON_NODE_BIN="${SIMULATION_DIR}/beacon_node"
DEPLOY_DEPOSIT_CONTRACT_BIN="${SIMULATION_DIR}/deploy_deposit_contract"
MASTER_NODE_ADDRESS_FILE="${SIMULATION_DIR}/node-0/beacon_node.address"
BASE_METRICS_PORT=8008
# Set DEPOSIT_WEB3_URL_ARG to empty to get genesis state from file, not using web3
# DEPOSIT_WEB3_URL_ARG=--web3-url=ws://localhost:8545
DEPOSIT_WEB3_URL_ARG=""
DEPOSIT_CONTRACT_ADDRESS="0x"

