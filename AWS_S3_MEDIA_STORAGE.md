# Private S3 media storage

This application stores uploaded media in a private S3 bucket. Static frontend
assets remain in the frontend image and PostgreSQL data remains unchanged.

## Safety rules

- Keep **Block Public Access** enabled for the bucket.
- Attach an IAM role to the EC2 instance; do not put AWS access keys in `.env`.
- Grant access only to this bucket and only to the `media/` prefix.
- Enable S3 only after the IAM role and bucket policy have been tested.
- Take a PostgreSQL backup before deploying the machine-logo field migration.

## Bucket

Create the bucket in `ap-south-1` with a globally unique name such as:

```text
ledgerautomation-media-<aws-account-id>
```

Keep public access blocked and use the default S3 server-side encryption.

Recommended CORS configuration for dashboard previews:

```json
[
  {
    "AllowedOrigins": ["https://ledgerautomation.duckdns.org"],
    "AllowedMethods": ["GET", "HEAD"],
    "AllowedHeaders": ["*"],
    "ExposeHeaders": ["ETag", "Content-Length"],
    "MaxAgeSeconds": 300
  }
]
```

## EC2 IAM role policy

Replace `BUCKET_NAME` before creating the policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadBucketMetadata",
      "Effect": "Allow",
      "Action": ["s3:GetBucketLocation", "s3:ListBucket"],
      "Resource": "arn:aws:s3:::BUCKET_NAME",
      "Condition": {
        "StringLike": {"s3:prefix": ["media", "media/*"]}
      }
    },
    {
      "Sid": "ManageApplicationMedia",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::BUCKET_NAME/media/*"
    }
  ]
}
```

Attach this policy to an EC2 role and attach the role to the production instance.

## Backend environment

Add only these non-secret settings to `backend/.env`:

```env
AWS_STORAGE_BUCKET_NAME=BUCKET_NAME
AWS_S3_REGION_NAME=ap-south-1
AWS_S3_PRESIGNED_EXPIRY=900
```

Do not add `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY`; boto3 obtains temporary
credentials from the EC2 IAM role.

## Storage paths

Objects are stored below the private `media/` prefix:

- `media/document_control/<year>/...`
- `media/messaging/images/...`
- `media/bug_reports/screenshots/...`
- `media/company_logos/...`
- `media/profiles/...`
- Existing Django file fields such as task attachments and drawings also use S3.

The API returns short-lived signed URLs. Existing client field names such as
`cloudinary_url` are temporarily retained for dashboard/mobile compatibility,
but no new file is uploaded to Cloudinary.

## Deployment verification

After deployment, test in this order:

1. Upload and view a profile photo.
2. Upload and remove a company logo.
3. Submit a bug report with a screenshot and open it from the dashboard.
4. Send and view a messaging image.
5. Upload, preview, download, revise, approve, reject, and obsolete a controlled document.
6. Confirm the new objects exist under `media/` in S3.
7. Confirm the bucket is still private by opening an unsigned object URL; it must return `AccessDenied`.

Do not remove the previous application image until all checks pass. If an
application check fails, roll back the application image while leaving the S3
bucket and IAM role intact so already uploaded objects remain available.
