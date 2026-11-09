# Screenshot Evidence

Screenshots must be captured from the actual Kubernetes environment
after the corresponding test has passed.

Store screenshots in `docs/images/`.

| Filename | Evidence |
|---|---|
| 01-cluster-overview.png | Kubernetes node and Redis namespace |
| 02-redis-statefulset.png | Redis StatefulSet and Pods |
| 03-persistent-volumes.png | PVC and PV status |
| 04-redis-replication.png | Redis master and replicas |
| 05-sentinel-quorum.png | Sentinel monitoring and quorum |
| 06-redis-failover.png | Successful master promotion |
| 07-failover-recovery.png | Replication after failover |
| 08-persistence-recovery.png | Data surviving Pod recreation |

Do not use simulated, edited, or fabricated terminal output as evidence.
