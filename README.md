# etcd backup to S3, driven by ACM policy

ACM policies that snapshot etcd on managed OpenShift clusters, keep the backup
on the node, and copy it to S3 from a separate CronJob five minutes later —
including the etcd encryption keys.

```
                        hub (ROSA HCP)
                   ACM Policy + Placement
                              │
              ┌───────────────┴───────────────┐
              ▼                               ▼
      managed cluster A                managed cluster B
   ┌──────────────────────┐
   │  00:00  etcd-backup  │ ──► /var/lib/etcd-backup/<ts>/  .complete
   │  00:05  upload       │ ──► s3://bucket/<cluster>/<ts>/ .uploaded
   └──────────────────────┘      (backup stays on the node)
```

---

## Scope

The hub is **out of scope** — it is an ACM control point here, not a backup
target. (Worth knowing if that changes: the hub runs on ROSA HCP, where etcd
lives in a Red Hat-owned AWS account and no snapshot is obtainable by anyone,
including Red Hat SRE. The earlier OADP/Velero hub-backup chain is in git
history at `b905d24` if you want it back.)

| Target | Covered | Why |
|---|---|---|
| Managed clusters, standalone OpenShift | yes | Full control plane access, so a real etcd snapshot is possible |
| Managed clusters, ROSA / ARO / OSD / ROKS | no — excluded by Placement | Control plane is in the vendor's account; no master nodes, no `cluster-backup.sh` |
| The ACM hub | no — excluded by Placement | Out of scope |

---

## How it works

Two CronJobs, deliberately decoupled, handing off through the node's filesystem.

**`etcd-backup`** (default `0 */6 * * *`) runs on a control plane node and
writes to `/var/lib/etcd-backup/<ts>/`:

1. `snapshot` — `chroot`s to the host and runs the etcd operator's own
   `/usr/local/bin/cluster-backup.sh`. Refuses to start if free space is under
   roughly twice the current etcd database size.
2. `encryption-keys` — exports the `encryption-key-*` secrets and the
   `APIServer` CR.
3. `finalize` — writes `BACKUP-INFO.txt` and `SHA256SUMS`, marks the directory
   `.complete`, and prunes old runs down to `local_keep`.

**`etcd-backup-upload`** (default `5 */6 * * *`) copies anything finished but
not yet uploaded to S3, and **deletes nothing**.

### Why the markers matter more than the 5 minutes

The gap is just two cron expressions; nothing enforces it. What makes the
handoff correct is the two marker files:

- The uploader only touches directories marked `.complete`, so a snapshot that
  overruns its window is never half-copied — it is simply collected on the next
  pass.
- `.uploaded` is written **last, and only after every object is confirmed
  present in S3**. A failed upload leaves no marker and is retried, rather than
  being silently skipped.

So the 5 minutes is a sensible default, not a correctness requirement. Widen it
freely if your snapshots are large.

### Why the uploader runs on every master

The snapshot can land on any control plane node and `hostPath` is per-node, so
a single upload pod would only ever see one node's backups. The upload Job runs
`completions: 3` / `parallelism: 3` with required pod anti-affinity on
`kubernetes.io/hostname`, putting one pod on each master. Pods that find nothing
new exit immediately. Set `control_plane_count` if you do not have three.

---

## What lands in S3

Each cluster owns a top-level directory named after it:

```
s3://<s3_bucket>/<cluster>/<ts>/snapshot_<ts>.db
s3://<s3_bucket>/<cluster>/<ts>/BACKUP-INFO.txt
s3://<s3_bucket>/<cluster>/<ts>/SHA256SUMS

s3://<s3_keys_bucket>/<cluster>/<ts>/static_kuberesources_<ts>.tar.gz
s3://<s3_keys_bucket>/<cluster>/<ts>/encryption-keys_<ts>.tar.gz
s3://<s3_keys_bucket>/<cluster>/<ts>/SHA256SUMS
```

### Why two buckets

`static_kuberesources_<ts>.tar.gz` contains the etcd encryption keys when etcd
encryption is enabled. [Red Hat's
guidance](https://docs.redhat.com/en/documentation/openshift_container_platform/4.16/html/backup_and_restore/control-plane-backup-and-restore)
is to store it apart from the snapshot, because whoever holds both holds the
decrypted cluster. They go to different buckets under different KMS keys, so
read access to one does not imply the other. The two buckets must differ —
both use the same `<cluster>/<ts>/` path and would otherwise collide.

### The encryption keys, specifically

Captured twice:

1. `cluster-backup.sh` already folds them into `static_kuberesources_<ts>.tar.gz`.
2. The `encryption-keys` container additionally exports the `encryption-key-*`
   secrets verbatim, plus `ENCRYPTION-TYPE.txt` recording whether encryption was
   on and which provider.

The second exists because the tarball is opaque and tied to a version-specific
restore flow. The explicit export lets you decrypt an old snapshot offline, or
recover keys if the layout drifts between releases. It costs a few KB. Clusters
with encryption disabled record that fact and carry on rather than failing.

---

## On-node retention — read this one

Backups stay on the node, as asked. `/var/lib/etcd-backup` normally shares a
filesystem with `/var/lib/etcd`, so an unbounded pile of multi-GB snapshots
would eventually take etcd down — a far worse outcome than a missed backup.

Two guards, neither of which you asked for but both of which this needs:

- **`local_keep` (default 2)** — after each successful snapshot, older runs are
  pruned oldest-first. If it has to drop one that never reached S3 it logs a
  loud `WARNING`, because that means uploads are broken and backups are being
  lost.
- **Pre-flight space check** — the snapshot refuses to start unless free space
  exceeds roughly 2× the current etcd database plus 1 GiB.

If you want deeper on-node history, give `/var/lib/etcd-backup` its own mount
first, then raise `local_keep`.

---

## Layout

```
hub-config/            apply to the hub directly (namespace, config)
policies/              the two policies + Placement
policies/optional/     backup-staleness detection; validate before trusting
aws/                   buckets, KMS keys, IAM policy, setup script
docs/RESTORE.md        restore procedure
```

Configuration lives in **one** place: the `etcd-backup-config` ConfigMap on the
hub. The policies read it with `{{hub fromConfigMap ... hub}}`, so changing the
schedule or bucket is a ConfigMap edit, not a policy edit. It sits in the same
namespace as the policies because ACM restricts hub template lookups to the
policy's own namespace.

---

## Install

### 1. AWS

```bash
cd aws
REGION=us-east-1 PREFIX=acm-etcd-backup ./setup-aws.sh                     # dry run
REGION=us-east-1 PREFIX=acm-etcd-backup ./setup-aws.sh --apply --create-credential
```

Creates two versioned, encrypted, private buckets; two KMS keys with rotation;
lifecycle rules; and a write-only uploader IAM user. With
`--create-credential` it also mints the access key and stores it in **AWS
Secrets Manager**, which is what your ClusterSecretStore reads. It prints the
exact values to paste into the ConfigMap.

Your ClusterSecretStore needs `secretsmanager:GetSecretValue` on that secret and
`kms:Decrypt` on the keys KMS key.

### 2. Fill in the placeholders

```bash
grep -rn CHANGEME hub-config/
```

Everything is in `hub-config/02-etcd-backup-config.yaml`: buckets, region, KMS
ARNs, schedules, and the three fields describing your existing external secret
(`secret_store_name`, `secret_store_kind`, `secret_remote_key`).

### 3. Apply to the hub

```bash
oc apply -f hub-config/
oc apply -f policies/
```

No credential is applied by hand — the prereqs policy creates an
`ExternalSecret` in `ocp-etcd-backup` on each managed cluster that pulls from
your existing store, and the CronJob policy will not deploy until that
ExternalSecret reports `Ready=True`.

### 4. Opt clusters in

Nothing happens to a managed cluster until you label it:

```bash
oc label managedcluster prod-cluster-01 etcd-backup=enabled
```

The Placement additionally requires `product.open-cluster-management.io ==
OpenShift`, so a ROSA/ARO/OSD cluster cannot pick the policy up even if
mislabelled. Confirm what your clusters report:

```bash
oc get managedcluster -o json | jq -r \
  '.items[] | "\(.metadata.name)\t\(.status.clusterClaims[]
   | select(.name=="product.open-cluster-management.io") | .value)"'
```

### 5. Verify

```bash
oc get policy -n etcd-backup-policies                     # all Compliant
oc --context prod-cluster-01 -n ocp-etcd-backup get externalsecret,cronjob
```

Then force a run rather than waiting six hours:

```bash
C="oc --context prod-cluster-01 -n ocp-etcd-backup"
$C create job --from=cronjob/etcd-backup manual-backup-$(date +%s)
$C logs -l app.kubernetes.io/name=etcd-backup --all-containers -f

# backup should now be on the node, unuploaded
oc --context prod-cluster-01 debug node/<master> -- \
  chroot /host ls -l /var/lib/etcd-backup/

$C create job --from=cronjob/etcd-backup-upload manual-upload-$(date +%s)
$C logs -l app.kubernetes.io/name=etcd-backup-upload --all-containers -f

aws s3 ls "s3://<snapshot-bucket>/prod-cluster-01/" --recursive
```

---

## Security notes

**The uploader credential is write-only.** No `s3:GetObject`, and an explicit
`Deny` on all delete actions. A compromised managed cluster can write its own
backups and nothing else — it cannot read back another cluster's etcd snapshot
or encryption keys, and cannot destroy history. Restores require a separate,
human-held role. This is also why upload verification uses `list-objects-v2`
rather than `head-object`, which would need `s3:GetObject`.

**No credential is in git or on the hub.** The External Secrets Operator syncs
it from your existing store straight into the backup namespace on each managed
cluster. Rotate by running `setup-aws.sh --apply --create-credential` again;
ESO picks up the new value within `refreshInterval` (1h). Delete the old access
key once every cluster has rolled over.

**The snapshot pod is privileged** and mounts the host filesystem. That is
unavoidable for an etcd snapshot. It is confined to `ocp-etcd-backup`, the SCC
grant is a namespace-scoped RoleBinding rather than cluster-wide, and secret
read access is a `Role` in `openshift-config-managed` rather than cluster-wide
secret access. The upload pod is privileged too (to read the root-owned
hostPath) but drops `hostNetwork` and `hostPID` — it never talks to etcd.

**Backups now sit on the node.** A snapshot on local disk is readable by anyone
with node access, and contains the whole cluster. That is the trade for keeping
them locally; `local_keep` bounds the window.

**Guard the keys bucket like cluster-admin.** Snapshot + keys together is a
plaintext copy of the cluster.

---

## Detecting a stale backup

A CronJob that exists but has failed every run still reports Compliant — the
policy only checks the object exists. This is the most likely way this setup
fails silently, so pick one of:

**S3-side (recommended).** Nothing to validate, and it checks the thing you
actually care about — that an object arrived:

```bash
aws s3api list-objects-v2 --bucket "$SNAPSHOT_BUCKET" --prefix "${CLUSTER}/" \
  --query 'sort_by(Contents,&LastModified)[-1].LastModified' --output text
```

Wire it to a CloudWatch alarm, or an EventBridge rule on `s3:ObjectCreated:*`.

**Policy-side.** `policies/optional/policy-etcd-backup-freshness.yaml` reports
NonCompliant when either CronJob's `status.lastSuccessfulTime` is older than 12
hours. It relies on sprig template functions inside `object-templates-raw`,
which vary by ACM version and **have not been validated against your hub** —
apply it on its own and confirm it reports Compliant on a healthy cluster
before trusting it.

Also watch for `WARNING: pruning ... which never reached S3` in the
`etcd-backup` finalize logs. That is the on-node retention telling you uploads
have been failing long enough to start losing backups.

---

## Limitations

- **Managed OpenShift clusters get no etcd backup** and are excluded by
  Placement. Use OADP per-cluster for their application data.
- **Same-z-stream restore constraint.** An etcd snapshot restores only onto the
  same z-stream release, which is why `BACKUP-INFO.txt` records the version.
  Upgrading a cluster invalidates older snapshots for restore purposes — worth
  noting in your upgrade runbook.
- **`control_plane_count` is static.** If it exceeds the number of schedulable
  masters, the upload Job cannot satisfy anti-affinity and fails at
  `activeDeadlineSeconds` rather than partially succeeding.
- **Images must be reachable.** `ose-cli` from `registry.redhat.io` and the AWS
  CLI from a public registry. Mirror both and update `ose_cli_image` /
  `aws_cli_image` for disconnected clusters. Pin the tags; `latest` is the
  default for convenience, not a recommendation.
- **ESO API version.** Manifests use `external-secrets.io/v1`; `v1beta1` was
  removed in ESO v0.17.0 and its compatibility flag expired in May 2026. The
  schemas are identical, so on an older ESO this is a one-word change.
- **The freshness policy is unvalidated.** See above.

## Verification status

All YAML parses, the four embedded container scripts pass `bash -n`, and
`setup-aws.sh` and the IAM policy are syntactically valid. The upload and
finalize scripts were exercised against a mocked AWS CLI, covering: a mixed
directory of complete/incomplete/already-uploaded runs; an upload where S3
silently drops the object (no `.uploaded` written, backup retained, non-zero
exit); and retention pruning including the never-uploaded warning path.

None of it has been applied to a live cluster. Treat the first run as a test,
and rehearse `docs/RESTORE.md` before you depend on it.

## References

- [OpenShift control plane backup and restore](https://docs.redhat.com/en/documentation/openshift_container_platform/4.16/html/backup_and_restore/control-plane-backup-and-restore)
- [ACM policy API concepts](https://open-cluster-management.io/docs/getting-started/integration/policy-controllers/policy/)
- [External Secrets Operator — v1 API](https://external-secrets.io/latest/guides/templating-v1/)
