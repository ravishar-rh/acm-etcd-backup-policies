#!/usr/bin/env bash
#
# Creates the AWS side of the backup setup:
#
#   3 buckets   - hub (ACM/Velero), etcd snapshots, etcd key material
#   3 KMS keys  - one per bucket, so the key material can be locked down
#                 independently of the snapshots
#   1 IAM role  - IRSA role assumed by Velero on the ROSA HCP hub
#   1 IAM user  - write-only uploader for the managed cluster CronJobs
#                 (skip with --no-iam-user and use IRSA instead where the
#                  managed clusters are themselves on AWS - see README)
#
# Dry run by default. Nothing is created until you pass --apply.
#
#   ./setup-aws.sh                 # show the plan
#   ./setup-aws.sh --apply         # create it
#
set -euo pipefail

# ---------------------------------------------------------------- settings --
REGION="${REGION:-us-east-1}"
PREFIX="${PREFIX:-acm-etcd-backup}"          # bucket name prefix; must be globally unique
HUB_KUBECONTEXT="${HUB_KUBECONTEXT:-}"        # optional: oc context for the hub

HUB_BUCKET="${HUB_BUCKET:-${PREFIX}-hub}"
SNAPSHOT_BUCKET="${SNAPSHOT_BUCKET:-${PREFIX}-snapshots}"
KEYS_BUCKET="${KEYS_BUCKET:-${PREFIX}-keys}"

HUB_ROLE_NAME="${HUB_ROLE_NAME:-${PREFIX}-hub-oadp}"
UPLOADER_USER_NAME="${UPLOADER_USER_NAME:-${PREFIX}-uploader}"

APPLY=0
MAKE_IAM_USER=1
for arg in "$@"; do
  case "$arg" in
    --apply)       APPLY=1 ;;
    --no-iam-user) MAKE_IAM_USER=0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

run() {
  if [ "${APPLY}" -eq 1 ]; then
    echo "+ $*" >&2
    "$@"
  else
    echo "  would run: $*"
  fi
}

need() { command -v "$1" >/dev/null || { echo "missing required tool: $1" >&2; exit 1; }; }
need aws
need jq

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

# --------------------------------------------------- hub OIDC provider ------
# Velero on the hub authenticates with AssumeRoleWithWebIdentity against the
# hub cluster's own OIDC issuer. Read it from the hub rather than asking for it.
if [ -n "${OIDC_PROVIDER:-}" ]; then
  :
else
  need oc
  OC=(oc)
  [ -n "${HUB_KUBECONTEXT}" ] && OC=(oc --context "${HUB_KUBECONTEXT}")
  ISSUER="$("${OC[@]}" get authentication cluster -o jsonpath='{.spec.serviceAccountIssuer}')"
  if [ -z "${ISSUER}" ]; then
    echo "Could not read .spec.serviceAccountIssuer from the hub." >&2
    echo "Point oc at the ROSA HCP hub, or set OIDC_PROVIDER=oidc.op1.openshiftapps.com/xxxx" >&2
    exit 1
  fi
  OIDC_PROVIDER="${ISSUER#https://}"
fi

cat <<EOF

Plan
  account              ${ACCOUNT_ID}
  region               ${REGION}
  hub OIDC provider    ${OIDC_PROVIDER}

  hub backup bucket    ${HUB_BUCKET}          (ACM hub state via OADP/Velero)
  snapshot bucket      ${SNAPSHOT_BUCKET}     (etcd snapshot_*.db)
  key material bucket  ${KEYS_BUCKET}         (static_kuberesources + encryption keys)

  hub IRSA role        ${HUB_ROLE_NAME}
  uploader IAM user    $([ "${MAKE_IAM_USER}" -eq 1 ] && echo "${UPLOADER_USER_NAME}" || echo "(skipped)")

EOF
[ "${APPLY}" -eq 1 ] || echo "DRY RUN - re-run with --apply to create these."

# --------------------------------------------------------------- buckets ----
make_bucket() {
  local bucket="$1"
  if aws s3api head-bucket --bucket "${bucket}" 2>/dev/null; then
    echo "  bucket ${bucket} already exists, leaving it alone"
    return
  fi
  if [ "${REGION}" = "us-east-1" ]; then
    run aws s3api create-bucket --bucket "${bucket}" --region "${REGION}"
  else
    run aws s3api create-bucket --bucket "${bucket}" --region "${REGION}" \
      --create-bucket-configuration "LocationConstraint=${REGION}"
  fi
  run aws s3api put-public-access-block --bucket "${bucket}" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
  run aws s3api put-bucket-versioning --bucket "${bucket}" \
    --versioning-configuration Status=Enabled
}

make_key() {
  # echoes the key ARN
  local alias="alias/$1" desc="$2" arn
  arn="$(aws kms describe-key --key-id "${alias}" --query KeyMetadata.Arn --output text 2>/dev/null || true)"
  if [ -n "${arn}" ] && [ "${arn}" != "None" ]; then
    echo "${arn}"
    return
  fi
  if [ "${APPLY}" -eq 0 ]; then
    echo "arn:aws:kms:${REGION}:${ACCOUNT_ID}:key/WOULD-BE-CREATED"
    return
  fi
  arn="$(aws kms create-key --description "${desc}" --region "${REGION}" \
           --query KeyMetadata.Arn --output text)"
  # Redirected: anything these print would be captured as part of the ARN
  # by the caller's command substitution.
  aws kms create-alias --alias-name "${alias}" --target-key-id "${arn}" \
    --region "${REGION}" >/dev/null
  aws kms enable-key-rotation --key-id "${arn}" --region "${REGION}" >/dev/null
  echo "${arn}"
}

encrypt_bucket() {
  local bucket="$1" key_arn="$2"
  run aws s3api put-bucket-encryption --bucket "${bucket}" \
    --server-side-encryption-configuration "$(jq -nc --arg k "${key_arn}" '{
      Rules: [{
        ApplyServerSideEncryptionByDefault: { SSEAlgorithm: "aws:kms", KMSMasterKeyID: $k },
        BucketKeyEnabled: true
      }]
    }')"
}

echo
echo "== buckets =="
for b in "${HUB_BUCKET}" "${SNAPSHOT_BUCKET}" "${KEYS_BUCKET}"; do
  make_bucket "${b}"
done

echo
echo "== KMS keys =="
HUB_KMS_ARN="$(make_key "${PREFIX}-hub"       "ACM hub backup (OADP/Velero)")"
SNAP_KMS_ARN="$(make_key "${PREFIX}-snapshots" "etcd snapshots")"
KEYS_KMS_ARN="$(make_key "${PREFIX}-keys"      "etcd encryption key material")"
echo "  hub       ${HUB_KMS_ARN}"
echo "  snapshots ${SNAP_KMS_ARN}"
echo "  keys      ${KEYS_KMS_ARN}"

encrypt_bucket "${HUB_BUCKET}"      "${HUB_KMS_ARN}"
encrypt_bucket "${SNAPSHOT_BUCKET}" "${SNAP_KMS_ARN}"
encrypt_bucket "${KEYS_BUCKET}"     "${KEYS_KMS_ARN}"

echo
echo "== lifecycle (retention) =="
for b in "${SNAPSHOT_BUCKET}" "${KEYS_BUCKET}"; do
  run aws s3api put-bucket-lifecycle-configuration --bucket "${b}" \
    --lifecycle-configuration "file://${HERE}/s3-lifecycle.json"
done
echo "  hub bucket retention is driven by BackupSchedule.spec.veleroTtl, not lifecycle"

# ----------------------------------------------------------- hub IRSA role --
echo
echo "== hub IRSA role =="
sed -e "s|ACCOUNT_ID|${ACCOUNT_ID}|g" \
    -e "s|OIDC_PROVIDER|${OIDC_PROVIDER}|g" \
    "${HERE}/iam-trust-policy-oadp-hub.json" > "${WORK}/hub-trust.json"

sed -e "s|HUB_BACKUP_BUCKET|${HUB_BUCKET}|g" \
    -e "s|HUB_KMS_KEY_ARN|${HUB_KMS_ARN}|g" \
    "${HERE}/iam-policy-oadp-hub.json" > "${WORK}/hub-perms.json"

if aws iam get-role --role-name "${HUB_ROLE_NAME}" >/dev/null 2>&1; then
  echo "  role ${HUB_ROLE_NAME} exists; updating trust policy"
  run aws iam update-assume-role-policy --role-name "${HUB_ROLE_NAME}" \
    --policy-document "file://${WORK}/hub-trust.json"
else
  run aws iam create-role --role-name "${HUB_ROLE_NAME}" \
    --assume-role-policy-document "file://${WORK}/hub-trust.json"
fi
run aws iam put-role-policy --role-name "${HUB_ROLE_NAME}" \
  --policy-name "${PREFIX}-hub-oadp" \
  --policy-document "file://${WORK}/hub-perms.json"

HUB_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${HUB_ROLE_NAME}"

# --------------------------------------------------- managed cluster creds --
if [ "${MAKE_IAM_USER}" -eq 1 ]; then
  echo
  echo "== managed cluster uploader =="
  sed -e "s|SNAPSHOT_BUCKET|${SNAPSHOT_BUCKET}|g" \
      -e "s|KEYS_BUCKET|${KEYS_BUCKET}|g" \
      -e "s|SNAPSHOT_KMS_KEY_ARN|${SNAP_KMS_ARN}|g" \
      -e "s|KEYS_KMS_KEY_ARN|${KEYS_KMS_ARN}|g" \
      "${HERE}/iam-policy-etcd-backup-managed.json" > "${WORK}/uploader-perms.json"

  if ! aws iam get-user --user-name "${UPLOADER_USER_NAME}" >/dev/null 2>&1; then
    run aws iam create-user --user-name "${UPLOADER_USER_NAME}"
  else
    echo "  user ${UPLOADER_USER_NAME} already exists"
  fi
  run aws iam put-user-policy --user-name "${UPLOADER_USER_NAME}" \
    --policy-name "${PREFIX}-uploader" \
    --policy-document "file://${WORK}/uploader-perms.json"

  echo
  echo "  Access keys are NOT created here on purpose - run this yourself so the"
  echo "  secret only ever exists in your shell, and rotate it on a schedule:"
  echo
  echo "    aws iam create-access-key --user-name ${UPLOADER_USER_NAME}"
fi

# ---------------------------------------------------------------- summary ---
cat <<EOF

================================================================================
Next: wire these values into the manifests
================================================================================

hub-config/02-etcd-backup-config.yaml
  s3_bucket:        ${SNAPSHOT_BUCKET}
  s3_keys_bucket:   ${KEYS_BUCKET}
  s3_region:        ${REGION}
  kms_key_id:       ${SNAP_KMS_ARN}
  kms_key_id_keys:  ${KEYS_KMS_ARN}

policies/hub/policy-hub-backup-oadp.yaml
  ROLEARN value:    ${HUB_ROLE_ARN}

policies/hub/policy-hub-backup-dpa.yaml
  objectStorage.bucket: ${HUB_BUCKET}
  config.region:        ${REGION}
  config.kmsKeyId:      ${HUB_KMS_ARN}

EOF
[ "${APPLY}" -eq 1 ] || echo "(DRY RUN - nothing above was actually created)"
