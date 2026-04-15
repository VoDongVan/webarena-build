# WebArena Wikipedia (Kiwix)

Runs the WebArena Wikipedia mirror using [kiwix-serve](https://github.com/kiwix/kiwix-tools) as a rootless Apptainer container inside a SLURM job.

- **Port:** 8888
- **URL:** `http://<node>:8888/`
- **No login required**

---

## Files

| File | Purpose |
|---|---|
| `download.sh` | Pulls the kiwix-serve Docker image and downloads the Wikipedia ZIM file |
| `set_up.sh` | One-time setup (verifies SIF and ZIM file are present) |
| `run_wikipedia.sh` | Starts the service; called by the SLURM script |
| `slurm_wikipedia.sh` | SLURM batch wrapper (submit with `sbatch`) |
| `test_wikipedia.sh` | Smoke test |
| `wikipedia.sif` | Apptainer image (built by `download.sh`) |
| `data/` | Contains the Wikipedia ZIM file (~85 GB) |

---

## First-Time Setup

Wikipedia is different from the other WebArena services: it has no pre-built Docker tar on the CMU mirror. The Docker image is pulled directly from the GitHub Container Registry, and the content is a standalone ZIM file.

From a compute node (or submit as a SLURM job for the long download):

```bash
sbatch download.sh   # pulls kiwix-serve SIF + downloads ~85 GB ZIM file
```

Or interactively:

```bash
bash download.sh
```

After the download completes:

```bash
bash set_up.sh       # verifies everything is in place
```

Then start with `sbatch slurm_wikipedia.sh` or via `bash ../../launch_all.sh`.

---

## How It Starts (run_wikipedia.sh)

Wikipedia is the simplest service — it has no database, no mutable state, and no service discovery complexity. The ZIM file is read-only.

`run_wikipedia.sh`:
1. Verifies `wikipedia.sif` and `data/wikipedia_en_all_maxi_2022-05.zim` exist
2. Runs `kiwix-serve` directly via `apptainer exec` (not `apptainer instance start`)
3. Bind-mounts `data/` as `/data` inside the container
4. Polls port 8888 until HTTP 200 or 302 is received (up to 30 attempts × 5s)
5. Writes `homepage/.wikipedia_node` to signal readiness

There is no workspace extracted to `/tmp` — the ZIM file is served directly from NFS (`data/`) via read-only access. kiwix-serve only reads the ZIM file; it does not write to disk during normal operation, so NFS is fine here.

**Why `apptainer exec` instead of `apptainer instance start`?** Some HPC nodes block the `cgroup` and `dbus` operations that `apptainer instance start` requires to register a named instance. `apptainer exec ... kiwix-serve ... &` runs the process directly without creating a named instance, avoiding these errors entirely.

---

## ZIM File

The ZIM file (`wikipedia_en_all_maxi_2022-05.zim`) is the English Wikipedia snapshot from May 2022 at ~85 GB. It is downloaded once and kept on NFS (`data/`). It does not need to be refreshed unless the benchmark dataset changes.

The `-c` flag in the `wget` command in `download.sh` enables resume — if the download is interrupted, re-running `download.sh` continues from where it left off.

---

## Issues Solved and How

### 1. `apptainer instance start` fails on some nodes — cgroup / dbus errors

On certain HPC nodes, `apptainer instance start` fails because registering a named instance requires cgroup management and dbus, which may not be available or permitted.

**Fix:** Use `apptainer exec ... kiwix-serve ... &` instead of creating a named instance. The process runs in the background without the instance registration overhead. The SLURM job's `trap` sends `SIGTERM` to `kiwix-serve` on job end.

---

### 2. No writable state needed — no NFS lock issues

kiwix-serve reads the ZIM file and serves its contents. It does not write lock files, create sockets, or use database connections. NFS is perfectly adequate for this read-only workload.
