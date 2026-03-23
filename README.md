# WebArena Build — Unity HPC

This directory contains the WebArena environments adapted to run under **Apptainer** on UMass Unity HPC (Docker is forbidden on Unity).

## Environments

| Environment | Directory | Port | Apptainer Instance |
|---|---|---|---|
| Magento storefront | `shopping/` | 7770 | `webarena_shopping` |
| Magento admin panel | `shopping_admin/` | 7780 | `webarena_shopping_admin` |
| Reddit (Postmill forum) | `reddit/` | 9999 | `webarena_reddit` |
| GitLab | `gitlab/` | 8023 | `webarena_gitlab` |

See the `README.md` in each subdirectory for first-time setup instructions.

---

## Running Both Servers Simultaneously

Shopping and shopping_admin **cannot run on the same compute node** — both use MySQL on port 3306 and Elasticsearch on port 9200. Run each on its own node using SLURM.

### Start both

Submit each as a separate batch job:

```bash
sbatch shopping/slurm_shopping.sh
sbatch shopping_admin/slurm_shopping_admin.sh
```

Each script allocates a CPU node, starts the Apptainer instance, then runs `sleep infinity` to keep the node alive. Check which nodes were assigned:

```bash
squeue -u $USER --format="%i %j %N %T"
```

Verify both are serving HTTP (from any node on the cluster, including your current session):

```bash
curl -s -o /dev/null -w "shopping HTTP: %{http_code}\n" http://<shopping-node>:7770
curl -s -o /dev/null -w "shopping_admin HTTP: %{http_code}\n" http://<shopping-admin-node>:7780
```

HTTP 302 is the expected healthy response (Magento redirects root to the storefront/login).

### Access from your laptop

A single SSH command can tunnel both ports simultaneously:

```bash
ssh -L 7770:<shopping-node>:7770 -L 7780:<shopping-admin-node>:7780 -L 9999:<reddit-node>:9999 -L 8023:<gitlab-node>:8023 <username>@unity.rc.umass.edu
```

The Unity login node has network access to all compute nodes and acts as a relay for both tunnels. Then open:
- Shopping storefront: `http://localhost:7770`
- Admin panel: `http://localhost:7780/admin`
- GitLab: `http://localhost:8023/explore`

### Stop both

```bash
scancel <shopping-job-id>
scancel <shopping-admin-job-id>
```

`scancel` ends the `sleep infinity`, releases the node, and kills the Apptainer instance with it.

To stop one instance without releasing the node (e.g. to restart it):
```bash
ssh <node-hostname> "apptainer instance stop webarena_shopping"
# or
ssh <node-hostname> "apptainer instance stop webarena_shopping_admin"
```

### Check all running jobs

```bash
squeue -u $USER --format="%i %j %N %T %l %M"
```

---

## SLURM Job Scripts

| Script | Purpose |
|---|---|
| `shopping/slurm_shopping.sh` | Runs `webarena_shopping` on a CPU node |
| `shopping_admin/slurm_shopping_admin.sh` | Runs `webarena_shopping_admin` on a CPU node |
| `reddit/slurm_reddit.sh` | Runs `webarena_reddit` on a CPU node |
| `gitlab/slurm_gitlab.sh` | Runs `webarena_gitlab` on a CPU node |

All request: 4 CPUs, 32 GB RAM, `cpu` partition, 8-hour time limit.

---

## Checking Service Health

Service logs are on the shared filesystem and readable from any node:

```bash
# supervisord status for shopping
tail -30 shopping/webarena_data/log/supervisord.log

# supervisord status for shopping_admin
tail -30 shopping_admin/webarena_data/log/supervisord.log

# Magento exception log (shopping)
tail -50 shopping/webarena_data/magento_var/log/exception.log
```
