# Restoring a managed cluster's etcd

Written for: the OpenShift platform engineer on call during an outage.

This is the OpenShift etcd disaster-recovery procedure. It is disruptive: it
takes the cluster down, reverts every object to the snapshot's point in time,
and anything created since is gone. Only use it for lost quorum or a
catastrophic control plane failure.

> Follow the etcd restore procedure for **the cluster's own OpenShift version** —
> the steps change between releases. This document covers only the part specific
> to this repo: finding the backup and reassembling it.

> A restore is the only thing that proves a backup works. Rehearse this against
> a throwaway cluster before you need it, and record how long it took.

---

## 0. Check the node first

Backups are **left on the control plane node** after upload, so the fastest
path usually skips S3 entirely:

```bash
oc debug node/<master> -- chroot /host ls -lh /var/lib/etcd-backup/
```

Each directory is one run. Two marker files tell you its state:

| Marker | Meaning |
|---|---|
| `.complete` | the snapshot finished and is internally consistent |
| `.uploaded` | this directory was confirmed present in S3 |
| neither | the snapshot was interrupted — **do not restore from it** |

`BACKUP-INFO.txt` records the cluster, the node, and the OpenShift version at
snapshot time. Read it before anything else:

```bash
oc debug node/<master> -- chroot /host cat /var/lib/etcd-backup/<ts>/BACKUP-INFO.txt
```

If a usable directory is there, jump to [step 4](#4-reassemble-the-restore-directory).
Only `local_keep` runs are kept (default 2), and the node may itself be the
thing that died — in which case, continue below.

---

## 1. Find the backup in S3

Each cluster owns a top-level directory named after it:

```bash
CLUSTER=prod-cluster-01
aws s3 ls "s3://${SNAPSHOT_BUCKET}/${CLUSTER}/"
```

Pick a timestamp, then read its provenance before committing to it:

```bash
TS=20261022T060000Z
aws s3 cp "s3://${SNAPSHOT_BUCKET}/${CLUSTER}/${TS}/BACKUP-INFO.txt" -
```

The constraint that catches people out: **the backup must be from the same
z-stream release as the cluster you are restoring onto.** That is what
`openshiftVersion` in `BACKUP-INFO.txt` is for. If the cluster has been upgraded
since, older snapshots are not restorable.

---

## 2. Download both halves

The snapshot and the key material live in **different buckets** by design, and
a restore needs both.

```bash
WORK=$(mktemp -d); cd "$WORK"

aws s3 cp "s3://${SNAPSHOT_BUCKET}/${CLUSTER}/${TS}/" . --recursive
aws s3 cp "s3://${KEYS_BUCKET}/${CLUSTER}/${TS}/"     . --recursive
```

This needs a role with `s3:GetObject` on both buckets. The credential the upload
job uses deliberately cannot do this — restores are a human action.

---

## 3. Verify integrity

```bash
sha256sum -c SHA256SUMS
```

There is a `SHA256SUMS` object in each bucket, written from the same source
file — they are identical, and the second download overwrites the first
harmlessly. A mismatch means a corrupt or truncated upload: pick an older
backup.

---

## 4. Reassemble the restore directory

`cluster-restore.sh` expects both files side by side with their original names:

```bash
mkdir -p backup
mv "snapshot_${TS}.db" "static_kuberesources_${TS}.tar.gz" backup/
ls backup/
# snapshot_20261022T060000Z.db  static_kuberesources_20261022T060000Z.tar.gz
```

`encryption-keys_${TS}.tar.gz`, `BACKUP-INFO.txt` and `SHA256SUMS` are **not**
part of the restore directory. Leave them out.

---

## 5. Run the restore

Copy `backup/` to a recovery control plane host and follow the "Restoring to a
previous cluster state" procedure for that OpenShift version:

```bash
scp -r backup core@<recovery-host>:/home/core/
ssh core@<recovery-host> sudo -E /usr/local/bin/cluster-restore.sh /home/core/backup
```

Then bring the remaining control plane hosts back per the version's docs, and
afterwards rotate credentials — a restore reverts service account signing keys
and certificates to their state at snapshot time.

---

## 6. About the etcd encryption keys

If the cluster had etcd encryption enabled, the values in `snapshot_*.db` are
encrypted at rest and useless without the keys.

- `static_kuberesources_<ts>.tar.gz` contains those keys, which is exactly why
  it is stored in a separate bucket under a separate KMS key. **Whoever holds
  both files holds the plaintext cluster.** Treat read access to the keys bucket
  as equivalent to cluster-admin.
- `encryption-keys_<ts>.tar.gz` is this repo's own independent export: the
  `encryption-key-*` secrets from `openshift-config-managed`, plus
  `ENCRYPTION-TYPE.txt` recording whether encryption was on and which provider
  (`aescbc` / `aesgcm`).

The normal restore path only needs the `static_kuberesources` tarball. The
explicit export is the escape hatch for the awkward cases: inspecting an old
snapshot offline, or recovering keys when the tarball's internal layout has
drifted across OpenShift releases.

```bash
tar -xzf "encryption-keys_${TS}.tar.gz"
cat encryption-keys/ENCRYPTION-TYPE.txt
ls encryption-keys/
```

If `ENCRYPTION-TYPE.txt` says `identity (disabled)`, the snapshot was never
encrypted at the application layer and the keys are irrelevant — but note the
snapshot is then only as protected as the bucket holding it.

---

## Appendix: restoring from the node's local copy

If the node is alive and holds a `.complete` directory, pull it directly:

```bash
TS=20261022T060000Z
oc debug node/<master> -- chroot /host tar -czf - -C /var/lib/etcd-backup "${TS}" \
  > "${TS}.tar.gz"
tar -xzf "${TS}.tar.gz"
cd "${TS}" && sha256sum -c SHA256SUMS
```

Then continue from [step 4](#4-reassemble-the-restore-directory). This skips
the S3 round trip, which matters when the snapshot is several GB.
