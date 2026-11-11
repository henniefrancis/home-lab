# Authentik database backup target (K5, ADR-015): one private, versioned S3 bucket in af-south-1 that the Pi can WRITE to and
# nothing else. The Pi encrypts every dump on the host with age (scripts/backup-authentik.sh) and only ever holds the owner's PUBLIC
# recipient, so the object is already client-side encrypted when it arrives. That is why the bucket uses SSE-S3 (AES256), not a
# customer managed key: a CMK adds cost and a key policy to review, and it would protect nothing that age does not already protect.
# What protects the bucket instead:
#   - the Pi host role may only s3:PutObject under authentik/ (identity.tf, statement WriteAuthentikBackups): no Get, no List, no
#     Delete, no ACL. A stolen Pi can add objects; it cannot read, overwrite (versioning keeps every version) or delete one,
#   - the bucket policy below denies deletes, reads and every bucket-management call to everybody except the owner's admin role and
#     the account root (the same owner_role_arn_pattern pattern as the alert topic policy), and refuses plain HTTP,
#   - versioning plus a lifecycle that keeps noncurrent versions 90 days, so an overwrite or delete the owner did not intend is
#     recoverable for three months. S3 conditional writes (If-None-Match) would stop overwrites outright, but the high-level `aws s3 cp -`
#     stream has no documented option for the header (only s3api put-object and complete-multipart-upload do), so it is not enforced (ADR-015).
# Cost: an Authentik dump is a few MB; 400 nightly objects are well under 1 GB, a few US cents a month.
locals {
  backup_bucket_name = "home-lab-backup-${local.account_id}-af-south-1"
  backup_prefix      = "authentik/"
  apps_prefix        = "apps/"
  restore_prefix     = "restore/"
}

resource "aws_s3_bucket" "backup" {
  provider = aws.af_south_1

  bucket = local.backup_bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "backup" {
  provider = aws.af_south_1

  bucket                  = aws_s3_bucket.backup.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "backup" {
  provider = aws.af_south_1

  bucket = aws_s3_bucket.backup.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# SSE-S3. No KMS key means no KMS grant for the Pi role.
# Reviewed Trivy exception (ADR-015, owner decision 2026-11-09): AWS-0132 asks for a customer managed key on the bucket encryption. The payload
# is encrypted on the Pi with age before it is uploaded, and the Pi role has no read access, so SSE-S3 is enough here.
#trivy:ignore:AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  provider = aws.af_south_1

  bucket = aws_s3_bucket.backup.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "backup" {
  provider = aws.af_south_1

  bucket = aws_s3_bucket.backup.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Current objects under authentik/ expire after 400 days (one year of nightly dumps plus slack; S3 then adds a delete marker and the
# noncurrent version goes after 90 days). 90 days, not 35: a stolen Pi cert can overwrite a key (a new version; the good one becomes
# noncurrent), and a theft in a home lab can go unnoticed for weeks (SEC M-2). restore/ holds the short-lived re-encrypted copy of a dump
# that the owner puts there for a restore (authentik-backup.md section 4); it and its versions go after one day. Failed multipart uploads
# are removed after a day (the Pi role has no s3:AbortMultipartUpload). The three rules touch different prefixes or different actions, so
# none overlaps another. Lifecycle runs as the S3 service, so the delete denies in the bucket policy below do not stop it.
resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  provider = aws.af_south_1

  bucket = aws_s3_bucket.backup.id

  rule {
    id     = "expire-authentik-dumps"
    status = "Enabled"

    filter {
      prefix = local.backup_prefix
    }

    expiration {
      days = 400
    }
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }

  # R17 app backups (scripts/backup-apps.sh): the same retention as the Authentik dumps, for the same reasons.
  rule {
    id     = "expire-app-backups"
    status = "Enabled"

    filter {
      prefix = local.apps_prefix
    }

    expiration {
      days = 400
    }
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }

  rule {
    id     = "expire-restore-copies"
    status = "Enabled"

    filter {
      prefix = local.restore_prefix
    }

    expiration {
      days = 1
    }
    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }

  rule {
    id     = "housekeeping"
    status = "Enabled"

    filter {}

    expiration {
      expired_object_delete_marker = true
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  depends_on = [aws_s3_bucket_versioning.backup]
}

data "aws_iam_policy_document" "backup_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.backup.arn, "${aws_s3_bucket.backup.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # Nobody but the owner's admin role (and the account root, so a wrong pattern cannot lock the bucket away) may delete a backup or
  # change how the bucket protects them. The Pi host role is not listed: it has no such right in its identity policy either.
  statement {
    sid    = "DenyDeleteAndManagementExceptOwner"
    effect = "Deny"
    actions = [
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
      "s3:PutLifecycleConfiguration",
      "s3:PutBucketPolicy",
      "s3:DeleteBucketPolicy",
      "s3:PutBucketVersioning",
      "s3:PutEncryptionConfiguration",
      "s3:PutBucketPublicAccessBlock",
      "s3:PutBucketOwnershipControls",
      "s3:PutBucketAcl",
      "s3:PutObjectAcl",
      "s3:PutObjectVersionAcl",
      "s3:PutReplicationConfiguration",
      "s3:DeleteBucket",
    ]
    resources = [aws_s3_bucket.backup.arn, "${aws_s3_bucket.backup.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "ArnNotLike"
      variable = "aws:PrincipalArn"
      values   = [var.owner_role_arn_pattern, local.account_root]
    }
  }

  # SSE-C: an object uploaded with a customer-provided key the owner does not have is unreadable (a way to destroy the latest backup
  # without deleting it). Nobody needs it: the bucket default is SSE-S3.
  statement {
    sid       = "DenyCustomerProvidedKeyEncryption"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.backup.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption-customer-algorithm"
      values   = ["false"]
    }
  }

  # Reads and listing: the owner (to restore) and the account root only. The Pi host role has no read right in its identity
  # policy; this makes that a second, independent lock.
  statement {
    sid       = "DenyReadAndListExceptOwner"
    effect    = "Deny"
    actions   = ["s3:GetObject", "s3:GetObjectVersion", "s3:ListBucket", "s3:ListBucketVersions"]
    resources = [aws_s3_bucket.backup.arn, "${aws_s3_bucket.backup.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "ArnNotLike"
      variable = "aws:PrincipalArn"
      values   = [var.owner_role_arn_pattern, local.account_root]
    }
  }
}

resource "aws_s3_bucket_policy" "backup" {
  provider = aws.af_south_1

  bucket = aws_s3_bucket.backup.id
  policy = data.aws_iam_policy_document.backup_bucket.json

  # SEC L-1: apply the policy LAST. Its denies cover PutLifecycleConfiguration, PutBucketVersioning and PutEncryptionConfiguration, so a
  # wrong owner_role_arn_pattern would otherwise lock the apply out half way through (only the account root could repair it).
  depends_on = [
    aws_s3_bucket_public_access_block.backup,
    aws_s3_bucket_ownership_controls.backup,
    aws_s3_bucket_server_side_encryption_configuration.backup,
    aws_s3_bucket_versioning.backup,
    aws_s3_bucket_lifecycle_configuration.backup,
  ]
}

# SEC L-2: a stolen host certificate can write to authentik/ without a size limit (S3 has no object-size condition). The obvious alarm,
# CloudWatch on BucketSizeBytes to the alert topic, cannot work: the topic uses the AWS managed key alias/aws/sns (ADR-014), and
# CloudWatch alarms cannot publish to a topic encrypted with an AWS managed key (the key policy cannot be changed to allow
# cloudwatch.amazonaws.com; AWS re:Post, "How do I configure a CloudWatch alarm with an encrypted SNS topic?"). A second topic would
# need a customer managed key (about USD 1 a month, half this lab's bill). A cost budget on S3 needs neither: it mails the alert address
# directly. It is coarser (cost data lags by about a day, USD 1 is roughly 40 GB-months in af-south-1) but it is free and it catches the
# abuse this finding is about. The size and object count are also checked by the drill (authentik-backup.md).
resource "aws_budgets_budget" "backup_storage" {
  name         = "home-lab-s3-backup"
  budget_type  = "COST"
  limit_amount = "1"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "Service"
    values = ["Amazon Simple Storage Service"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}
