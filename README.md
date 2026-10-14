# etcd backup to S3, driven by ACM policy

ACM policy manifests that back up cluster state to S3 from an ACM hub running on
**ROSA with Hosted Control Planes**, covering both the hub and its managed
clusters, including the etcd encryption keys.

---

## Read this first: the hub cannot have an etcd snapshot

The hub runs on ROSA HCP. Its etcd members live in a **Red Hat-owned AWS
account** — there are no control plane nodes in your account, `oc debug
node/<master>` has nothing to attach to, and `/usr/local/bin/cluster-backup.sh`
does not exist anywhere you can reach. There is no API, supported or otherwise,
that hands you a hub etcd snapshot.

Worse, you cannot fall back on Red Hat having one: per [Red Hat solution
7045845](https://access.redhat.com/solutions/7045845), SRE does **not** back up
etcd data on ROSA clusters, and the [ROSA service
definition](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/introduction_to_rosa/policies-and-service-definition)
puts backup and restore of your own data on you.

So this repo does the thing that is actually achievable, and that actually
matters for hub recovery:

| Target | Mechanism | Why |
|---|---|---|
| **Hub** (ROSA HCP) | ACM `BackupSchedule` → OADP/Velero → S3 | etcd is unreachable. Backs up the ACM state that matters — managed cluster registrations, policies, applications, credentials — and is the supported path for restoring onto a replacement hub. |
| **Managed clusters** (standalone OCP) | CronJob → `cluster-backup.sh` → S3 | Full control plane access, so a real etcd snapshot is possible. |
| **Managed clusters** (ROSA / ARO / OSD / ROKS) | *excluded by Placement* | Same constraint as the hub. Back their *applications* up with OADP instead. |

If what you need is point-in-time rollback of the hub's own etcd, no manifest in
any repo can give you that on HCP — that requires a self-managed hub.

---

## What gets backed up

**Hub** — six Velero schedules (credentials, hive credentials, cluster
credentials, resources, generic resources, managed clusters), every 2 hours,
30-day TTL, to `s3://<hub-bucket>/acm-hub/`.

**Each managed cluster**, every 6 hours:

```
s3://<snapshot-bucket>/etcd-snapshots/<cluster>/<ts>/
    snapshot_<ts>.db                     # etcdctl snapshot
    SHA256SUMS

s3://<keys-bucket>/etcd-keys/<cluster>/<ts>/
    static_kuberesources_<ts>.tar.gz     # static pod resources + ENCRYPTION KEYS
    encryption-keys_<ts>.tar.gz          # independent export of encryption-key-* secrets
    SHA256SUMS
```

### Why two buckets

`static_kuberesources_<ts>.tar.gz` contains the etcd encryption keys when etcd
encryption is enabled — [Red Hat's
guidance](https://docs.redhat.com/en/documentation/openshift_container_platform/4.16/html/backup_and_restore/control-plane-backup-and-restore)
is to store it separately from the snapshot, because whoever holds both holds
the decrypted cluster. Here they go to different buckets under different KMS
keys, so read access to one does not imply the other.

### The encryption keys, specifically

You asked for these "if possible" — it is, two ways over:

1. `cluster-backup.sh` already folds them into `static_kuberesources_<ts>.tar.gz`.
2. The `encryption-keys` init container additionally exports the
   `encryption-key-*` secrets from `openshift-config-managed` verbatim, plus
   `ENCRYPTION-TYPE.txt` recording whether encryption was on and which provider.

The second exists because the tarball is opaque and tied to a version-specific
restore flow. The explicit export lets you decrypt an old snapshot offline, or
recover keys if the tarball layout drifts between releases. It costs a few KB.

If a cluster has etcd encryption disabled, the job records that fact and moves
on rather than failing.

---

## Layout

```
hub-config/            apply to the hub directly (namespace, config, credential)
policies/hub/          ACM hub backup chain (OADP → DPA → BackupSchedule)
policies/managed/      managed cluster etcd backup (prereqs → CronJob)
policies/optional/     backup-staleness detection; validate before trusting
aws/                   buckets, KMS keys, IAM policies, setup script
docs/RESTORE.md        both restore procedures
```

Configuration lives in **one** place: the `etcd-backup-config` ConfigMap on the
hub. The managed cluster policies read it at template-resolution time with
`{{hub fromConfigMap ... hub}}`, so changing the schedule or bucket is a
ConfigMap edit, not a policy edit.

---

## Install

### 1. AWS

```bash
cd aws
REGION=us-east-1 PREFIX=acm-etcd-backup ./setup-aws.sh          # dry run
REGION=us-east-1 PREFIX=acm-etcd-backup ./setup-aws.sh --apply
```

Creates three versioned, encrypted, private buckets; three KMS keys with
rotation; lifecycle rules; the hub IRSA role; and a write-only uploader IAM
user. It prints the exact values to paste into the manifests. It does **not**
create access keys — run that yourself so the secret only ever exists in your
shell:

```bash
aws iam create-access-key --user-name acm-etcd-backup-uploader
```

### 2. Fill in the placeholders

Everything needing an edit is marked `CHANGEME`:

```bash
grep -rn CHANGEME hub-config/ policies/
```

| File | Value |
|---|---|
| `hub-config/02-etcd-backup-config.yaml` | buckets, region, KMS key ARNs, schedule |
| `policies/hub/policy-hub-backup-oadp.yaml` | OADP channel, `ROLEARN` |
| `policies/hub/policy-hub-backup-dpa.yaml` | hub bucket, region, KMS key |

For the OADP channel, read what your ACM version expects rather than guessing:

```bash
oc get cm acm-redhat-oadp-operator-subscription \
  -n open-cluster-management-backup -o yaml
```

(That ConfigMap appears only after the first policy enables the `cluster-backup`
component, so it is fine to apply the chain, read the value, and correct it.)

### 3. Apply to the hub

```bash
oc apply -f hub-config/01-policies-namespace.yaml

# the S3 credential - lives only on the hub, never in git
cp hub-config/03-etcd-backup-s3-secret.example.yaml /tmp/s3-secret.yaml
$EDITOR /tmp/s3-secret.yaml
oc apply -f /tmp/s3-secret.yaml && shred -u /tmp/s3-secret.yaml

oc apply -f hub-config/02-etcd-backup-config.yaml
oc apply -f policies/hub/
oc apply -f policies/managed/
```

The hub chain is ordered with `spec.dependencies`, so each policy waits for the
previous one to report Compliant. Expect the whole chain to settle in 5–10
minutes while the OADP operator installs.

### 4. Opt managed clusters in

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
oc get policy -n etcd-backup-policies                                  # all Compliant
oc get backupschedule -n open-cluster-management-backup                # phase Enabled
oc get backupstoragelocation -n open-cluster-management-backup         # Available
```

Then force one managed cluster run rather than waiting six hours:

```bash
oc --context prod-cluster-01 -n ocp-etcd-backup \
  create job --from=cronjob/etcd-backup etcd-backup-manual-$(date +%s)
oc --context prod-cluster-01 -n ocp-etcd-backup logs -l app.kubernetes.io/name=etcd-backup --all-containers -f

aws s3 ls s3://<snapshot-bucket>/etcd-snapshots/prod-cluster-01/ --recursive
aws s3 ls s3://<keys-bucket>/etcd-keys/prod-cluster-01/ --recursive
```

---

## How the managed cluster job works

A `CronJob` pinned to a control plane node (`nodeSelector:
node-role.kubernetes.io/master`), with three stages:

1. **`snapshot`** (privileged, `hostNetwork`, `hostPID`) — `chroot`s to the host
   and runs the etcd operator's own `/usr/local/bin/cluster-backup.sh` into
   `/var/tmp/etcd-backup`. If that script is absent it fails loudly with an
   explanation rather than producing an empty backup.
2. **`encryption-keys`** — exports the `encryption-key-*` secrets and the
   `APIServer` CR, tars them alongside the snapshot.
3. **`upload`** — checksums everything, uploads snapshot and key material to
   their respective buckets with SSE-KMS, **verifies each object landed**, and
   only then deletes the local copies.

Details worth knowing:

- `hostNetwork` is required because etcd listens in the host network namespace
  and `chroot` does not cross namespaces. That in turn requires
  `dnsPolicy: ClusterFirstWithHostNet`, or `oc` in stage 2 cannot resolve the API.
- Verification uses `s3api list-objects-v2`, not `head-object`, specifically so
  the credential needs no `s3:GetObject` — see below.
- **If any stage fails, the staging directory is left in place** and the Job
  goes `Failed`. Nothing is deleted on a path that did not confirm success.
- `concurrencyPolicy: Forbid` plus `activeDeadlineSeconds: 3600` means a hung
  run cannot pile up behind itself.
- Retention is the S3 lifecycle rule's job (30 days), not the node's. Snapshots
  and keys never linger on disk.

---

## Security notes

**The uploader credential is write-only.** No `s3:GetObject`, and an explicit
`Deny` on all delete actions. A compromised managed cluster can write its own
backups and nothing else — it cannot read back another cluster's etcd snapshot
or encryption keys, and cannot destroy history. Restores require a separate,
human-held role.

**The S3 credential never appears in git.** It lives as one secret on the hub;
the policy pulls it with `{{hub fromSecret ... hub}}`, and ACM encrypts values
resolved that way per-cluster before replication, using a key held in the
cluster's own namespace.

**The hub uses no static keys at all.** Velero authenticates via IRSA — setting
`ROLEARN` on the OADP Subscription makes the Cloud Credential Operator mint the
`cloud-credentials` secret through `AssumeRoleWithWebIdentity`.

**The backup pod is privileged** and mounts the host filesystem. That is
unavoidable for an etcd snapshot. It is confined to the `ocp-etcd-backup`
namespace, the SCC grant is a namespace-scoped RoleBinding rather than a
cluster-wide one, and secret read access is a `Role` in
`openshift-config-managed` rather than cluster-wide secret access.

**Guard the keys bucket like cluster-admin.** Snapshot + keys together is a
plaintext copy of the cluster.

### Alternative: IRSA instead of static keys

Where the managed clusters are themselves on AWS, drop the IAM user entirely:

```bash
./setup-aws.sh --apply --no-iam-user
```

Then per managed cluster, create a role trusting *that* cluster's OIDC issuer
for `system:serviceaccount:ocp-etcd-backup:etcd-backup`, annotate the service
account with `eks.amazonaws.com/role-arn`, and delete the two
`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` env entries from the CronJob. This
is strictly better where it is available; it is not the default only because
managed clusters are commonly on-prem.

---

## Detecting a stale backup

A CronJob that exists but has failed every run for a month still reports
Compliant — the policy only checks the object exists. This is the most likely
way this setup fails silently, so pick one of:

**S3-side (recommended).** Nothing to validate, and it checks the thing you
actually care about, that an object arrived:

```bash
aws s3api list-objects-v2 --bucket "$SNAPSHOT_BUCKET" \
  --prefix "etcd-snapshots/${CLUSTER}/" \
  --query 'sort_by(Contents,&LastModified)[-1].LastModified' --output text
```

Wire it to a CloudWatch alarm, or use S3 Storage Lens / an EventBridge rule on
`s3:ObjectCreated:*` with a metric filter.

**Policy-side.** `policies/optional/policy-etcd-backup-freshness.yaml` reports
NonCompliant when `status.lastSuccessfulTime` is older than 12 hours. It relies
on sprig template functions inside `object-templates-raw`, which vary by ACM
version and **have not been validated against your hub** — apply it on its own
and confirm it reports Compliant on a healthy cluster before trusting it.

---

## Limitations

- **No hub etcd snapshot is possible.** Covered at the top; it is a property of
  ROSA HCP, not of these manifests.
- **Managed OpenShift clusters get no etcd backup either** and are excluded by
  Placement. Use OADP per-cluster for their application data.
- **Hosted clusters** (HyperShift) keep etcd as a StatefulSet in the hosting
  cluster's control plane namespace and would need a different job targeting
  that namespace. Not applicable with a ROSA HCP hub, which cannot host them.
- **Same-z-stream restore constraint.** An etcd snapshot restores only onto the
  same z-stream release. Upgrading a cluster invalidates older snapshots for
  restore purposes — worth noting in your upgrade runbook.
- **Images must be reachable.** `ose-cli` from `registry.redhat.io` and the AWS
  CLI from a public registry. Mirror both and update `ose_cli_image` /
  `aws_cli_image` in the ConfigMap for disconnected clusters. Pin tags; `latest`
  is the default for convenience, not a recommendation.
- **The freshness policy is unvalidated.** See above.

## Verification status

The YAML in this repo parses cleanly and the three embedded container scripts
pass `bash -n`; the upload script was additionally exercised against a mocked
AWS CLI, covering the success path, the missing-snapshot path, and the
upload-did-not-land path. None of it has been applied to a live ACM hub — treat
the first run as a test, and rehearse `docs/RESTORE.md` before you depend on it.

## References

- [ROSA policies and service definition](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/introduction_to_rosa/policies-and-service-definition)
- [Who backs up etcd on ROSA? (solution 7045845)](https://access.redhat.com/solutions/7045845)
- [OpenShift control plane backup and restore](https://docs.redhat.com/en/documentation/openshift_container_platform/4.16/html/backup_and_restore/control-plane-backup-and-restore)
- [ACM business continuity / backup and restore](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.13/html-single/business_continuity/index)
- [Backing up applications on ROSA STS using OADP](https://docs.okd.io/latest/backup_and_restore/application_backup_and_restore/oadp-rosa/oadp-rosa-backing-up-applications.html)
- [ACM policy API concepts](https://open-cluster-management.io/docs/getting-started/integration/policy-controllers/policy/)
