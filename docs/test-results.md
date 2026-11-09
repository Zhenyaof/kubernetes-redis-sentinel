# Redis Sentinel Test Results

**Execution date:** 2026-11-09
**Environment:** Single-node Kubernetes lab on Ubuntu 24.04
**Redis version:** 7.4.12

## 1. Automated acceptance test

Test script:

`tests/acceptance/redis-sentinel-acceptance.sh`

The acceptance test verifies the deployed Redis and Sentinel components,
including:

- All Redis and Sentinel PVCs are Bound.
- Sentinel quorum is healthy.
- Exactly one Redis instance is the master.
- The master has two connected replicas.
- Both replicas report an active replication link.
- All three Sentinel instances agree on the current master.
- The `redis-master` Service targets the current master.
- A temporary test key is replicated to all three Redis instances.

**Result:** PASS

## 2. Controlled failover and recovery test

Test script:

`tests/acceptance/redis-sentinel-failover.sh`

The test performs a controlled failure of the current Redis master Pod.

### Executed scenario

1. Verify all six PVCs are Bound.
2. Verify Sentinel quorum and the initial master with two replicas.
3. Write a test key and confirm it exists on all three Redis instances.
4. Delete the current master Pod.
5. Wait for Sentinel to promote a replica.
6. Verify one master and two connected replicas are restored.
7. Verify the deleted Pod is recreated and Running.
8. Verify all three Sentinels agree on the new master.
9. Verify the `redis-master` Service points to the new master.
10. Verify the test key remains available on all three Redis instances.

### Observed result

| Check | Result |
|---|---|
| Initial master | redis-0 |
| Deleted master Pod | redis-0 |
| Promoted master | redis-2 |
| Two replicas restored | PASS |
| Deleted Pod recreated | PASS |
| Three Sentinels agree | PASS |
| Service targets new master | PASS |
| Test key available on all Redis Pods | PASS |

**Result: FAILOVER AND RECOVERY PASSED**

## 3. Startup race condition and correction

During an earlier failover test, a recreated Redis Pod accepted a
stale master address returned by Sentinel before the failover election
had fully converged.

The Pod consequently attempted to replicate from the old master IP,
which was no longer reachable.

The Redis startup discovery logic was updated to validate a Sentinel
candidate before selecting it:

- Require a majority of Sentinel responses.
- Require three consecutive matching discovery rounds.
- Connect to the candidate using Redis authentication.
- Require PING to return PONG.
- Require ROLE to report `master`.
- Continue discovery if the candidate is unreachable or is not a master.

After deploying this change, the recreated Redis Pod discovered the
current master, completed a full synchronization, and rejoined as a
replica.

The subsequent controlled failover and recovery test passed.

## 4. Scope and limitations

These tests demonstrate Redis Pod-level failure detection, Sentinel
master promotion, replica recovery, and data continuity in the tested
environment.

All workloads run on a single Kubernetes node using node-local
`local-path` storage. The results do not demonstrate node-level high
availability, storage redundancy, or disaster recovery.

Automated backup and restore testing are not yet implemented.
