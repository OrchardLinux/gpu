#!/bin/busybox sh
# BEFORE_INIT NEGATIVE CONTROL: should fault if the PDS kernel code is fetched.
. /run/agx-init48.sh
# An intentionally unmapped code offset in the PDS heap. This distinguishes
# a pre-dispatch stall/incorrect packet from a PDS instruction/completion issue.
put32 scratch 0x60008 0x400001
