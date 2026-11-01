#!/bin/busybox sh
# BEFORE_INIT hook: valid PDS context-store/load program as well as terminate.
. /run/agx-init32.sh
# Context state +0x38/+0x3c -> RGX_CDM_CONTEXT_PDS0 at 0x4a8/0x4ac.
# Use the same single-HALT program, avoiding an implicit PDS fetch from VA 0.
put32 scratch 0x53038 0x201000
put32 scratch 0x5303c 0x201010
