#!/usr/bin/env bash
set -u

NAMESPACE="redis-lab"
REDIS_PODS=(redis-0 redis-1 redis-2)
SENTINEL_PODS=(sentinel-0 sentinel-1 sentinel-2)
FAILURES=0

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; FAILURES=$((FAILURES + 1)); }

get_info() {
    kubectl exec "$1" -n "$NAMESPACE" -- \
        sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli --raw INFO replication' 2>/dev/null
}

echo "===== REDIS SENTINEL FAILOVER TEST ====="

# 1. Safety preflight
for pod in "${REDIS_PODS[@]}" "${SENTINEL_PODS[@]}"; do
    STATUS=$(kubectl get pod "$pod" -n "$NAMESPACE" \
        -o jsonpath='{.status.phase}' 2>/dev/null)

    if [ "$STATUS" != "Running" ]; then
        echo "[ABORT] $pod is not Running"
        exit 1
    fi
done

PVC_COUNT=$(kubectl get pvc -n "$NAMESPACE" \
    -o jsonpath='{range .items[?(@.status.phase=="Bound")]}x{end}' | wc -c)

if [ "$PVC_COUNT" -ne 6 ]; then
    echo "[ABORT] Expected 6 Bound PVCs, found $PVC_COUNT"
    exit 1
fi
pass "All six PVCs are Bound"

QUORUM=$(kubectl exec sentinel-0 -n "$NAMESPACE" -- \
    redis-cli -p 26379 SENTINEL CKQUORUM mymaster 2>/dev/null)

if ! echo "$QUORUM" | grep -q '^OK'; then
    echo "[ABORT] Sentinel quorum unavailable"
    exit 1
fi
pass "Sentinel quorum is healthy"

# 2. Discover the current master
MASTER_COUNT=0
MASTER_POD=""
MASTER_IP=""

for pod in "${REDIS_PODS[@]}"; do
    INFO=$(get_info "$pod") || {
        echo "[ABORT] Cannot read replication info from $pod"
        exit 1
    }

    ROLE=$(printf '%s\n' "$INFO" | awk -F: '$1=="role"{gsub("\r","",$2); print $2}')

    if [ "$ROLE" = "master" ]; then
        MASTER_COUNT=$((MASTER_COUNT + 1))
        MASTER_POD="$pod"
        MASTER_IP=$(kubectl get pod "$pod" -n "$NAMESPACE" \
            -o jsonpath='{.status.podIP}')
        MASTER_INFO="$INFO"
    fi
done

if [ "$MASTER_COUNT" -ne 1 ] || [ -z "$MASTER_IP" ]; then
    echo "[ABORT] Expected exactly one Redis master; found $MASTER_COUNT"
    exit 1
fi

REPLICAS=$(printf '%s\n' "$MASTER_INFO" |
    awk -F: '$1=="connected_slaves"{gsub("\r","",$2); print $2}')

if [ "$REPLICAS" != "2" ]; then
    echo "[ABORT] Master has ${REPLICAS:-unknown} connected replicas"
    exit 1
fi

pass "Current master is $MASTER_POD ($MASTER_IP), with two replicas"

# 3. Write a marker before failure
TEST_KEY="failover:test:$(date +%s)"
TEST_VALUE="redis-sentinel-failover"

WRITE=$(kubectl exec "$MASTER_POD" -n "$NAMESPACE" -- \
    sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli --raw SET "$1" "$2" EX 600' \
    sh "$TEST_KEY" "$TEST_VALUE" 2>/dev/null)

if [ "$WRITE" != "OK" ]; then
    echo "[ABORT] Could not write pre-failover test key"
    exit 1
fi

for pod in "${REDIS_PODS[@]}"; do
    VALUE=""
    for attempt in $(seq 1 10); do
        VALUE=$(kubectl exec "$pod" -n "$NAMESPACE" -- \
            sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli --raw GET "$1"' \
            sh "$TEST_KEY" 2>/dev/null) || VALUE=""
        [ "$VALUE" = "$TEST_VALUE" ] && break
        sleep 1
    done

    if [ "$VALUE" != "$TEST_VALUE" ]; then
        echo "[ABORT] Test key did not replicate to $pod; master will NOT be deleted"
        exit 1
    fi
done
pass "Pre-failover test key exists on all three Redis Pods"

# 4. Deliberately delete only the current master Pod
echo "[ACTION] Deleting master Pod: $MASTER_POD"
kubectl delete pod "$MASTER_POD" -n "$NAMESPACE" --wait=false || exit 1

# 5. Wait for a different master to be elected and full recovery
NEW_MASTER_IP=""
NEW_MASTER_POD=""
RECOVERED=0

for attempt in $(seq 1 120); do
    CANDIDATE=$(kubectl exec sentinel-0 -n "$NAMESPACE" -- \
        redis-cli --raw -p 26379 SENTINEL get-master-addr-by-name mymaster 2>/dev/null |
        head -n 1)

    if [ -n "$CANDIDATE" ] && [ "$CANDIDATE" != "$MASTER_IP" ]; then
        NEW_MASTER_IP="$CANDIDATE"
    fi

    if [ -n "$NEW_MASTER_IP" ]; then
        MASTER_COUNT=0
        NEW_MASTER_POD=""
        ALL_HEALTHY=1

        for pod in "${REDIS_PODS[@]}"; do
            INFO=$(get_info "$pod") || {
                ALL_HEALTHY=0
                break
            }

            ROLE=$(printf '%s\n' "$INFO" |
                awk -F: '$1=="role"{gsub("\r","",$2); print $2}')

            if [ "$ROLE" = "master" ]; then
                MASTER_COUNT=$((MASTER_COUNT + 1))
                NEW_MASTER_POD="$pod"
                CONNECTED=$(printf '%s\n' "$INFO" |
                    awk -F: '$1=="connected_slaves"{gsub("\r","",$2); print $2}')

                POD_IP=$(kubectl get pod "$pod" -n "$NAMESPACE" \
                    -o jsonpath='{.status.podIP}' 2>/dev/null)

                [ "$CONNECTED" = "2" ] || ALL_HEALTHY=0
                [ "$POD_IP" = "$NEW_MASTER_IP" ] || ALL_HEALTHY=0

            elif [ "$ROLE" = "slave" ]; then
                LINK=$(printf '%s\n' "$INFO" |
                    awk -F: '$1=="master_link_status"{gsub("\r","",$2); print $2}')
                [ "$LINK" = "up" ] || ALL_HEALTHY=0
            else
                ALL_HEALTHY=0
            fi
        done

        [ "$MASTER_COUNT" -eq 1 ] || ALL_HEALTHY=0

        # Confirm the deleted StatefulSet Pod has been recreated.
        RECREATED_PHASE=$(kubectl get pod "$MASTER_POD" -n "$NAMESPACE" \
            -o jsonpath='{.status.phase}' 2>/dev/null)
        [ "$RECREATED_PHASE" = "Running" ] || ALL_HEALTHY=0

        # Require all three Sentinels to agree on the promoted master.
        for sentinel in "${SENTINEL_PODS[@]}"; do
            SENTINEL_IP=$(kubectl exec "$sentinel" -n "$NAMESPACE" -- \
                redis-cli --raw -p 26379 SENTINEL get-master-addr-by-name mymaster \
                2>/dev/null | head -n 1)

            [ "$SENTINEL_IP" = "$NEW_MASTER_IP" ] || ALL_HEALTHY=0
        done

        if [ "$ALL_HEALTHY" -eq 1 ]; then
            RECOVERED=1
            break
        fi
    fi

    sleep 1
done

if [ "$RECOVERED" -ne 1 ]; then
    fail "Full Redis and Sentinel recovery did not complete within 120 seconds"

    echo
    echo "===== FAILURE DIAGNOSTICS ====="
    kubectl get pods -n "$NAMESPACE" -o wide

    for sentinel in "${SENTINEL_PODS[@]}"; do
        echo "--- $sentinel master view ---"
        kubectl exec "$sentinel" -n "$NAMESPACE" -- \
            redis-cli --raw -p 26379 SENTINEL get-master-addr-by-name mymaster \
            2>/dev/null || true
    done
else
    pass "New master elected: $NEW_MASTER_POD ($NEW_MASTER_IP)"
    pass "One master and two connected replicas restored"
    pass "Deleted Pod $MASTER_POD recreated and Running"
    pass "All three Sentinels agree on the new master"
fi

# 6. Verify all Sentinels agree with the new master
if [ "$RECOVERED" -eq 1 ]; then
    for pod in "${SENTINEL_PODS[@]}"; do
        IP=$(kubectl exec "$pod" -n "$NAMESPACE" -- \
            redis-cli --raw -p 26379 SENTINEL get-master-addr-by-name mymaster 2>/dev/null |
            head -n 1)

        if [ "$IP" = "$NEW_MASTER_IP" ]; then
            pass "$pod agrees on new master"
        else
            fail "$pod reports ${IP:-no master}, expected $NEW_MASTER_IP"
        fi
    done

    SERVICE_IP=$(kubectl get endpoints redis-master -n "$NAMESPACE" \
        -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)

    if [ "$SERVICE_IP" = "$NEW_MASTER_IP" ]; then
        pass "redis-master Service points to new master"
    else
        fail "Service endpoint $SERVICE_IP does not match $NEW_MASTER_IP"
    fi

    # Verify the pre-failover data survived promotion and recovery.
    for pod in "${REDIS_PODS[@]}"; do
        VALUE=$(kubectl exec "$pod" -n "$NAMESPACE" -- \
            sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli --raw GET "$1"' \
            sh "$TEST_KEY" 2>/dev/null)

        if [ "$VALUE" = "$TEST_VALUE" ]; then
            pass "$pod retains the pre-failover test key"
        else
            fail "$pod is missing the pre-failover test key"
        fi
    done
fi

echo
echo "===== FAILOVER TEST SUMMARY ====="
if [ "$FAILURES" -eq 0 ] && [ "$RECOVERED" -eq 1 ]; then
    echo "RESULT: FAILOVER AND RECOVERY PASSED"
    exit 0
else
    echo "RESULT: FAILOVER TEST FAILED"
    exit 1
fi
