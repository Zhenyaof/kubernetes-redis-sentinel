# Redis Sentinel on Kubernetes

A Kubernetes-based Redis deployment using StatefulSets, persistent volumes,
master-replica replication, and Redis Sentinel for automatic failover.

## Architecture

- Three Redis instances managed by a StatefulSet.
- Three Redis Sentinel instances managed by a StatefulSet.
- Persistent volumes for Redis data and Sentinel configuration.
- Headless Services for stable StatefulSet discovery.
- A ClusterIP Service exposing the current Redis master.
- Redis authentication using a Kubernetes Secret.
- Redis AOF persistence and replica synchronization.

All workloads currently run on a single-node Kubernetes lab.
This demonstrates process-level failover and recovery, not node-level
high availability.

## Verified functionality

- Three Sentinel instances discover and monitor the Redis master.
- Sentinel quorum is established.
- Redis replicas synchronize data from the master.
- Sentinel promotes a replica after master Pod failure.
- Redis instances recover their roles after Pod recreation.
- Recreated Redis replicas discover the promoted master using Sentinel
  discovery and validate the candidate with authenticated PING and ROLE
  commands before configuring replication.
- PVC-backed data survives Redis Pod recreation.
- Replication resumes with two online replicas.

These results have been verified using automated acceptance tests.
See [Test Results](docs/test-results.md) for the executed test scenarios
and their outcomes.

## Repository structure

- `kubernetes/redis/` — Redis StatefulSet, Services, and ConfigMap.
- `kubernetes/sentinel/` — Sentinel StatefulSet, Services, and ConfigMap.
- `scripts/` — Redis and Sentinel entrypoint scripts.
- `docs/` — Test evidence and screenshot documentation.

## Environment

- Kubernetes v1.37.0
- Redis 7.4.12
- Ubuntu 24.04
- containerd 2.2.1
- Local Path Provisioner
- Single-node VMware virtual machine

## Deployment

The cluster must have working DNS and a StorageClass named `local-path`.

Create the namespace:

    kubectl create namespace redis-lab

Create the Redis authentication Secret:

    kubectl create secret generic redis-auth --namespace redis-lab --from-literal=password="$(openssl rand -hex 32)"

Apply the Redis resources:

    kubectl apply -f kubernetes/redis/redis-configmap.yaml
    kubectl apply -f kubernetes/redis/redis-services.yaml
    kubectl apply -f kubernetes/redis/redis-statefulset.yaml

Apply the Sentinel resources:

    kubectl apply -f kubernetes/sentinel/sentinel-configmap.yaml
    kubectl apply -f kubernetes/sentinel/sentinel-services.yaml
    kubectl apply -f kubernetes/sentinel/sentinel-statefulset.yaml

Inspect the deployment:

    kubectl get pods,pvc,services -n redis-lab

## Testing

Verification coverage:

- Redis replication and data synchronization.
- Sentinel quorum.
- Automatic master promotion after Pod failure.
- Redis Pod recreation and role recovery.
- Persistence of data on PVC-backed storage.

Automated acceptance tests:

- `tests/acceptance/redis-sentinel-acceptance.sh`
- `tests/acceptance/redis-sentinel-failover.sh`

See [Test Results](docs/test-results.md) for execution details.

## Security and limitations

- Redis credentials are supplied through Kubernetes Secrets.
- Do not commit credentials or generated Secret manifests.
- Sentinel command access is currently unauthenticated and intended
  for internal cluster communication.
- Local-path storage is node-local and does not provide node-level
  storage redundancy.
- Loss of a PVC can result in data loss.
- Automated backup and disaster recovery are not implemented.
