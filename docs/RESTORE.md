# Restore procedures

Written for: the OpenShift platform engineer on call during an outage.

Two independent recovery paths. They protect different things and share nothing
but the S3 account.

| You lost | Use | Section |
|---|---|---|
| The ACM hub (ROSA HCP cluster gone/broken) | OADP/Velero restore onto a replacement hub | [1](#1-restoring-the-acm-hub) |
| A managed cluster's etcd / control plane quorum | etcd snapshot restore on that cluster | [2](#2-restoring-a-managed-clusters-etcd) |

> A restore is the only thing that proves a backup works. Rehearse both of these
> against a throwaway cluster before you need them, and record how long each took.

---

## 1. Restoring the ACM hub

The hub runs on ROSA HCP, so there is no etcd snapshot to roll back to — you do
not recover the *same* hub, you stand up a replacement and pour the ACM state
back into it.

### 1.1 Build the replacement hub

1. Create a new ROSA HCP cluster.
2. Install the **same ACM version or newer** than the backup hub was running.
   A newer hub can read an older backup; the reverse is not supported.
3. Install the same operators into the same namespaces as the original.
4. Install OADP into `open-cluster-management-backup` and create a
   `DataProtectionApplication` pointing at **the same bucket and prefix** as the
   original (`policies/hub/policy-hub-backup-dpa.yaml`).

   The new cluster has a **different OIDC issuer**, so its IRSA role trust
   policy must be regenerated:

   ```bash
   OIDC_PROVIDER=$(oc get authentication cluster \
     -o jsonpath='{.spec.serviceAccountIssuer}' | sed 's|https://||')
   sed -e "s|ACCOUNT_ID|<account>|g" -e "s|OIDC_PROVIDER|${OIDC_PROVIDER}|g" \
     aws/iam-trust-policy-oadp-hub.json > /tmp/trust.json
   aws iam update-assume-role-policy \
     --role-name acm-etcd-backup-hub-oadp \
     --policy-document file:///tmp/trust.json
   ```

5. Do **not** apply `policies/hub/policy-hub-backup-schedule.yaml` yet. An active
   `BackupSchedule` on the new hub writing to the same bucket triggers a
   `BackupCollision` and can overwrite the backups you are about to restore from.

### 1.2 Confirm the backups are visible

```bash
oc get backupstoragelocation -n open-cluster-management-backup   # want: Available
oc get backups.velero.io -n open-cluster-management-backup
```

If no backups appear, Velero cannot read the bucket. Fix that before continuing
— an empty restore will *succeed* and leave you with an empty hub.

### 1.3 Restore

```yaml
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Restore
metadata:
  name: restore-acm
  namespace: open-cluster-management-backup
spec:
  cleanupBeforeRestore: CleanupRestored
  veleroManagedClustersBackupName: latest
  veleroCredentialsBackupName: latest
  veleroResourcesBackupName: latest
```

`veleroManagedClustersBackupName: latest` is what re-attaches the managed
clusters. Set it to `skip` if you are building a passive/standby hub that should
not take ownership of clusters the active hub still manages — two hubs both
claiming the same managed cluster is a bad day.

Watch it:

```bash
oc get restore.cluster.open-cluster-management.io restore-acm \
  -n open-cluster-management-backup -o yaml -w
```

### 1.4 Verify, then re-enable scheduling

```bash
oc get managedcluster                     # all clusters back, and Available
oc get policy -A
oc get applications.argoproj.io -A
```

Managed clusters reconnect via the `ManagedServiceAccount` tokens captured
because `useManagedServiceAccount: true` was set on the `BackupSchedule`. If a
cluster stays `Unknown` for more than ~15 minutes, re-import that one by hand.

Only once the hub is confirmed healthy, apply
`policies/hub/policy-hub-backup-schedule.yaml` to resume backups.

---

## 2. Restoring a managed cluster's etcd

This is the OpenShift etcd disaster-recovery procedure. It is disruptive: it
takes the cluster down, reverts every object to the snapshot's point in time,
and anything created since is gone. Only use it for lost quorum or a
catastrophic control plane failure.

> Follow the etcd restore procedure for **the cluster's own OpenShift version** —
> the steps change between releases. This section covers only the part specific
> to this repo: getting the files back out of S3 and reassembled.

### 2.1 Identify the backup

```bash
CLUSTER=prod-cluster-01
aws s3 ls "s3://${SNAPSHOT_BUCKET}/etcd-snapshots/${CLUSTER}/"
```

Pick a timestamp. The constraint that catches people out: **the backup must be
from the same z-stream release as the cluster you are restoring onto.** Check
what the cluster was running at that time before committing.

### 2.2 Download both halves

The snapshot and the key material live in **different buckets** by design, and a
restore needs both.

```bash
TS=20261014120000
WORK=$(mktemp -d); cd "$WORK"

aws s3 cp "s3://${SNAPSHOT_BUCKET}/etcd-snapshots/${CLUSTER}/${TS}/" . --recursive
aws s3 cp "s3://${KEYS_BUCKET}/etcd-keys/${CLUSTER}/${TS}/"          . --recursive
```

This needs a role with `s3:GetObject` on both buckets. The credential the backup
job uses deliberately cannot do this — restores are a human action.

### 2.3 Verify integrity before you rely on it

```bash
sha256sum -c SHA256SUMS
```

There are two `SHA256SUMS` objects, one per bucket, written from the same source
file — they are identical, and the second download overwrites the first
harmlessly. A mismatch means a corrupt or truncated upload: pick an older
backup.

### 2.4 Reassemble the restore directory

`restore-etcd.sh` expects both files side by side with their original names:

```bash
mkdir -p backup
mv "snapshot_${TS}.db" "static_kuberesources_${TS}.tar.gz" backup/
ls backup/
# snapshot_20261014120000.db  static_kuberesources_20261014120000.tar.gz
```

`encryption-keys_${TS}.tar.gz` is **not** part of the restore directory — it is
the independent copy of the encryption keys (see 2.6). Leave it out.

### 2.5 Run the restore

Copy `backup/` to a recovery control plane host and follow the
"Restoring to a previous cluster state" procedure for that OpenShift version:

```bash
scp -r backup core@<recovery-host>:/home/core/
ssh core@<recovery-host> sudo -E /usr/local/bin/cluster-restore.sh /home/core/backup
```

Then bring the remaining control plane hosts back per the version's docs, and
afterwards rotate credentials — a restore reverts service account signing keys
and certificates to their state at snapshot time.

### 2.6 About the etcd encryption keys

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

To read the keys back:

```bash
tar -xzf "encryption-keys_${TS}.tar.gz"
cat encryption-keys/ENCRYPTION-TYPE.txt
ls encryption-keys/
```

If `ENCRYPTION-TYPE.txt` says `identity (disabled)`, the snapshot was never
encrypted at the application layer and the keys are irrelevant — but note the
snapshot is then only as protected as the S3 bucket holding it.
