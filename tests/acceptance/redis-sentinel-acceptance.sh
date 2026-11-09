#!/usr/bin/env bash
set -u

NAMESPACE="redis-lab"
REDIS_PODS=(redis-0 redis-1 redis-2)
SENTINEL_PODS=(sentinel-0 sentinel-1 sentinel-2)
FAILURES=0

pass() {
    echo "[PASS] $1"
}

fail() {
    echo "[FAIL] $1"
    FAILURES=$((FAILURES + 1))
}

echo "===== REDIS SENTINEL ACCEPTANCE TESTS ====="

# 1. Sentinel quorum
if kubectl exec sentinel-0 -n "$NAMESPACE" -- \
    redis-cli -p 26379 SENTINEL CKQUORUM mymaster 2>/dev/null |
    grep -q '^OK'; then
    pass "Sentinel quorum is healthy"
else
    fail "Sentinel quorum is unavailable"
fi

# 2. Discover Redis roles
MASTER_COUNT=0
MASTER_POD=""
MASTER_IP=""

for pod in "${REDIS_PODS[@]}"; do
    INFO=$(kubectl exec "$pod" -n "$NAMESPACE" -- sh -c \
        'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli --raw INFO replication' 2>/dev/null) || {
        fail "$pod replication information unavailable"
        continue
    }

    ROLE=$(printf '%s\n' "$INFO" | awk -F: '$1=="role"{gsub("\r","",$2); print $2}')
    if [ "$ROLE" = "master" ]; then
        MASTER_COUNT=$((MASTER_COUNT + 1))
        MASTER_POD="$pod"
        MASTER_IP=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.podIP}')
    fi
done

if [ "$MASTER_COUNT" -eq 1 ]; then
    pass "Exactly one Redis master: $MASTER_POD"
else
    fail "Expected one Redis master, found $MASTER_COUNT"
fi

# 3. Verify master has two connected replicas
if [ -n "$MASTER_POD" ]; then
    INFO=$(kubectl exec "$MASTER_POD" -n "$NAMESPACE" -- sh -c \
        'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli --raw INFO replication' 2>/dev/null)

    REPLICAS=$(printf '%s\n' "$INFO" | awk -F: '$1=="connected_slaves"{gsub("\r","",$2); print $2}')

    if [ "$REPLICAS" = "2" ]; then
        pass "Master has two connected replicas"
    else
        fail "Expected two connected replicas, found ${REPLICAS:-unknown}"
    fi
fi

# 4. Verify replica links
for pod in "${REDIS_PODS[@]}"; do
    INFO=$(kubectl exec "$pod" -n "$NAMESPACE" -- sh -c \
        'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli --raw INFO replication' 2>/dev/null) || continue

    ROLE=$(printf '%s\n' "$INFO" | awk -F: '$1=="role"{gsub("\r","",$2); print $2}')

    if [ "$ROLE" = "slave" ]; then
        LINK=$(printf '%s\n' "$INFO" | awk -F: '$1=="master_link_status"{gsub("\r","",$2); print $2}')
        if [ "$LINK" = "up" ]; then
            pass "$pod replication link is up"
        else
            fail "$pod replication link is not up"
        fi
    fi
done

# 5. Verify all Sentinels agree on the master
if [ -n "$MASTER_IP" ]; then
    for pod in "${SENTINEL_PODS[@]}"; do
        SENTINEL_IP=$(kubectl exec "$pod" -n "$NAMESPACE" -- \
            redis-cli --raw -p 26379 SENTINEL get-master-addr-by-name mymaster 2>/dev/null |
            head -n 1)

        if [ "$SENTINEL_IP" = "$MASTER_IP" ]; then
            pass "$pod agrees on master $MASTER_IP"
        else
            fail "$pod reports ${SENTINEL_IP:-no master}, expected $MASTER_IP"
        fi
    done
fi

# 6. Verify redis-master Service endpoint
SERVICE_IP=$(kubectl get endpoints redis-master -n "$NAMESPACE" \
    -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)

if [ -n "$MASTER_IP" ] && [ "$SERVICE_IP" = "$MASTER_IP" ]; then
    pass "redis-master Service points to the current master"
else
    fail "Service endpoint ($SERVICE_IP) does not match master ($MASTER_IP)"
fi

# 7. Write a temporary key and verify replication
if [ -n "$MASTER_POD" ] && [ "$MASTER_COUNT" -eq 1 ]; then
    TEST_KEY="acceptance:test:$(date +%s)"
    TEST_VALUE="redis-sentinel-acceptance"

    WRITE_RESULT=$(kubectl exec "$MASTER_POD" -n "$NAMESPACE" -- \
        sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli --raw SET "$1" "$2" EX 300' \
        sh "$TEST_KEY" "$TEST_VALUE" 2>/dev/null)

    if [ "$WRITE_RESULT" = "OK" ]; then
        pass "Temporary test key written to master"

        for pod in "${REDIS_PODS[@]}"; do
            VALUE=""
            for attempt in $(seq 1 10); do
                VALUE=$(kubectl exec "$pod" -n "$NAMESPACE" -- \
                    sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli --raw GET "$1"' \
                    sh "$TEST_KEY" 2>/dev/null) || VALUE=""

                [ "$VALUE" = "$TEST_VALUE" ] && break
                sleep 1
            done

            if [ "$VALUE" = "$TEST_VALUE" ]; then
                pass "$pod contains the replicated test key"
            else
                fail "$pod does not contain the test key after 10 seconds"
            fi
        done
    else
        fail "Could not write test key to master"
    fi
fi
echo
echo "===== TEST SUMMARY ====="

if [ "$FAILURES" -eq 0 ]; then
    echo "RESULT: ALL ACCEPTANCE TESTS PASSED"
    exit 0
else
    echo "RESULT: $FAILURES ACCEPTANCE TEST(S) FAILED"
    exit 1
fi
