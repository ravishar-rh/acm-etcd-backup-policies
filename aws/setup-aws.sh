#!/usr/bin/env bash
#
# Creates the AWS side of the managed cluster etcd backup:
#
#   2 buckets   - etcd snapshots, and (separately) etcd key material
#   2 KMS keys  - one per bucket, so key material is locked down independently
#   1 IAM user  - write-only uploader for the etcd-backup-upload CronJob
#
# With --create-credential it also mints an access key for that user and parks
# it in AWS Secrets Manager, which is where your ClusterSecretStore reads from.
# That value is what secret_remote_key in the ConfigMap points at.
#
# Dry run by default. Nothing is created until you pass --apply.
#
#   ./setup-aws.sh                              # show the plan
#   ./setup-aws.sh --apply                      # create buckets, keys, IAM user
#   ./setup-aws.sh --apply --create-credential  # ...and the Secrets Manager entry
#
set -euo pipefail

# ---------------------------------------------------------------- settings --
REGION="${REGION:-eu-west-1}"

# Where the Secrets Manager entry lives. This is NOT always the bucket region:
# it must match the region configured on the ClusterSecretStore that ESO reads
# through, or ESO will look in the wrong region and never find the credential.
#   e.g.  REGION=eu-west-1 SECRETS_REGION=us-east-2 ./setup-aws.sh --apply ...
SECRETS_REGION="${SECRETS_REGION:-${REGION}}"
PREFIX="${PREFIX:-acm-etcd-backup}"          # bucket name prefix; globally unique

SNAPSHOT_BUCKET="${SNAPSHOT_BUCKET:-${PREFIX}-snapshots}"
KEYS_BUCKET="${KEYS_BUCKET:-${PREFIX}-keys}"
UPLOADER_USER_NAME="${UPLOADER_USER_NAME:-${PREFIX}-uploader}"
SECRET_NAME="${SECRET_NAME:-${PREFIX}/s3-uploader}"

APPLY=0
CREATE_CRED=0
for arg in "$@"; do
  case "$arg" in
    --apply)             APPLY=1 ;;
    --create-credential) CREATE_CRED=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

run() {
  if [ "${APPLY}" -eq 1 ]; then echo "+ $*" >&2; "$@"
  else echo "  would run: $*"; fi
}
need() { command -v "$1" >/dev/null || { echo "missing required tool: $1" >&2; exit 1; }; }
need aws
need jq

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

if [ "${SNAPSHOT_BUCKET}" = "${KEYS_BUCKET}" ]; then
  echo "FATAL: snapshot and keys buckets must differ - both use the same" >&2
  echo "       <cluster>/<timestamp>/ layout and would overwrite each other." >&2
  exit 1
fi

cat <<EOF

Plan
  account              ${ACCOUNT_ID}
  bucket/KMS region    ${REGION}
  secrets mgr region   ${SECRETS_REGION}   (must match your ClusterSecretStore)

  snapshot bucket      ${SNAPSHOT_BUCKET}   (snapshot_*.db)
  key material bucket  ${KEYS_BUCKET}       (static_kuberesources + encryption keys)
  layout               s3://<bucket>/<cluster-name>/<timestamp>/

  uploader IAM user    ${UPLOADER_USER_NAME}
  secrets manager key  $([ "${CREATE_CRED}" -eq 1 ] && echo "${SECRET_NAME}" || echo "(skipped; pass --create-credential)")

EOF
[ "${APPLY}" -eq 1 ] || echo "DRY RUN - re-run with --apply to create these."

# --------------------------------------------------------------- buckets ----
make_bucket() {
  local bucket="$1"
  if aws s3api head-bucket --bucket "${bucket}" 2>/dev/null; then
    echo "  bucket ${bucket} already exists, leaving it alone"; return
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
  if [ -n "${arn}" ] && [ "${arn}" != "None" ]; then echo "${arn}"; return; fi
  if [ "${APPLY}" -eq 0 ]; then
    echo "arn:aws:kms:${REGION}:${ACCOUNT_ID}:key/WOULD-BE-CREATED"; return
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
  run aws s3api put-bucket-encryption --bucket "$1" \
    --server-side-encryption-configuration "$(jq -nc --arg k "$2" '{
      Rules: [{
        ApplyServerSideEncryptionByDefault: { SSEAlgorithm: "aws:kms", KMSMasterKeyID: $k },
        BucketKeyEnabled: true
      }]
    }')"
}

echo
echo "== buckets =="
make_bucket "${SNAPSHOT_BUCKET}"
make_bucket "${KEYS_BUCKET}"

echo
echo "== KMS keys =="
SNAP_KMS_ARN="$(make_key "${PREFIX}-snapshots" "etcd snapshots")"
KEYS_KMS_ARN="$(make_key "${PREFIX}-keys"      "etcd encryption key material")"
echo "  snapshots ${SNAP_KMS_ARN}"
echo "  keys      ${KEYS_KMS_ARN}"
encrypt_bucket "${SNAPSHOT_BUCKET}" "${SNAP_KMS_ARN}"
encrypt_bucket "${KEYS_BUCKET}"     "${KEYS_KMS_ARN}"

echo
echo "== lifecycle (retention in S3; on-node retention is local_keep) =="
for b in "${SNAPSHOT_BUCKET}" "${KEYS_BUCKET}"; do
  run aws s3api put-bucket-lifecycle-configuration --bucket "${b}" \
    --lifecycle-configuration "file://${HERE}/s3-lifecycle.json"
done

# --------------------------------------------------- uploader IAM identity --
echo
echo "== uploader IAM user =="
sed -e "s|SNAPSHOT_BUCKET|${SNAPSHOT_BUCKET}|g" \
    -e "s|KEYS_BUCKET|${KEYS_BUCKET}|g" \
    -e "s|SNAPSHOT_KMS_KEY_ARN|${SNAP_KMS_ARN}|g" \
    -e "s|KEYS_KMS_KEY_ARN|${KEYS_KMS_ARN}|g" \
    "${HERE}/iam-policy-etcd-backup.json" > "${WORK}/uploader-perms.json"

if aws iam get-user --user-name "${UPLOADER_USER_NAME}" >/dev/null 2>&1; then
  echo "  user ${UPLOADER_USER_NAME} already exists"
else
  run aws iam create-user --user-name "${UPLOADER_USER_NAME}"
fi
run aws iam put-user-policy --user-name "${UPLOADER_USER_NAME}" \
  --policy-name "${PREFIX}-uploader" \
  --policy-document "file://${WORK}/uploader-perms.json"

# ------------------------------------- credential -> AWS Secrets Manager ----
if [ "${CREATE_CRED}" -eq 1 ]; then
  echo
  echo "== access key -> Secrets Manager (${SECRET_NAME}) =="
  if [ "${APPLY}" -eq 0 ]; then
    echo "  would create an access key for ${UPLOADER_USER_NAME}"
    echo "  would store it at ${SECRET_NAME} with properties"
    echo "    aws_access_key_id / aws_secret_access_key"
  else
    # The plaintext key exists only inside this command substitution and the
    # temp file below, both of which go away with the trap on exit.
    KEYJSON="$(aws iam create-access-key --user-name "${UPLOADER_USER_NAME}" \
                 --query 'AccessKey.{aws_access_key_id:AccessKeyId,aws_secret_access_key:SecretAccessKey}' \
                 --output json)"
    printf '%s' "${KEYJSON}" > "${WORK}/cred.json"
    chmod 600 "${WORK}/cred.json"

    if aws secretsmanager describe-secret --secret-id "${SECRET_NAME}" \
         --region "${SECRETS_REGION}" >/dev/null 2>&1; then
      aws secretsmanager put-secret-value --secret-id "${SECRET_NAME}" \
        --secret-string "file://${WORK}/cred.json" --region "${SECRETS_REGION}" >/dev/null
      echo "  rotated existing secret ${SECRET_NAME}"
      echo "  NOTE: the previous access key is still active - delete it once"
      echo "        every cluster has picked up the new value:"
      echo "          aws iam list-access-keys --user-name ${UPLOADER_USER_NAME}"
    else
      # Secrets Manager cannot encrypt with a KMS key from another region, so
      # the customer-managed key is only usable when the secret and the keys
      # bucket share a region. Otherwise fall back to the AWS-managed key.
      SM_KMS=()
      if [ "${SECRETS_REGION}" = "${REGION}" ]; then
        SM_KMS=(--kms-key-id "${KEYS_KMS_ARN}")
      else
        echo "  note: ${SECRETS_REGION} != ${REGION}, so the secret uses the"
        echo "        AWS-managed Secrets Manager key rather than ${KEYS_KMS_ARN}"
      fi
      aws secretsmanager create-secret --name "${SECRET_NAME}" \
        --description "S3 uploader credential for the etcd backup CronJob" \
        --secret-string "file://${WORK}/cred.json" \
        "${SM_KMS[@]}" --region "${SECRETS_REGION}" >/dev/null
      echo "  created ${SECRET_NAME} in ${SECRETS_REGION}"
    fi
  fi
  echo
  echo "  Your ClusterSecretStore needs secretsmanager:GetSecretValue on this"
  echo "  secret, and kms:Decrypt on ${KEYS_KMS_ARN}."
fi

# ---------------------------------------------------------------- summary ---
cat <<EOF

================================================================================
Next: paste these into config/02-backup-settings.yaml
================================================================================

  s3_bucket:        ${SNAPSHOT_BUCKET}
  s3_keys_bucket:   ${KEYS_BUCKET}
  s3_region:        ${REGION}
  secret_remote_key: ${SECRET_NAME}

  (Secrets Manager entry is in ${SECRETS_REGION}; the ClusterSecretStore's own
   region setting governs where ESO reads it - s3_region below is only used by
   the upload job to reach the buckets.)

  # Aliases, not ARNs - a KMS ARN would put your AWS account ID into the
  # GitOps repo for no benefit. The ARNs are shown below for reference only;
  # do not paste them into the ConfigMap.
  kms_key_id:       alias/${PREFIX}-snapshots
  kms_key_id_keys:  alias/${PREFIX}-keys

    (snapshots key ARN: ${SNAP_KMS_ARN})
    (keys key ARN:      ${KEYS_KMS_ARN})

Still to set by hand (they describe your existing ESO setup, not anything
created here):

  secret_store_name: <your ClusterSecretStore>
  secret_store_kind: ClusterSecretStore

EOF
[ "${APPLY}" -eq 1 ] || echo "(DRY RUN - nothing above was actually created)"
