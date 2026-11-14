import argparse
import hashlib
import json
import os
import re
from pathlib import Path
from urllib.parse import urlparse

import boto3
from botocore.config import Config


def mobile_version(pubspec: Path) -> tuple[str, int]:
    match = re.search(r'^version:\s*([^+\s]+)\+(\d+)\s*$', pubspec.read_text(), re.MULTILINE)
    if not match:
        raise ValueError('Could not read version from mobile/pubspec.yaml')
    return match.group(1), int(match.group(2))


def main() -> None:
    parser = argparse.ArgumentParser(description='Publish a signed Android APK')
    parser.add_argument('apk', type=Path)
    parser.add_argument('--pubspec', type=Path, default=Path('mobile/pubspec.yaml'))
    parser.add_argument('--release-notes', default='Bug fixes and improvements.')
    parser.add_argument('--mandatory', action='store_true')
    args = parser.parse_args()

    version_name, version_code = mobile_version(args.pubspec)
    digest = hashlib.sha256(args.apk.read_bytes()).hexdigest()
    object_key = f'android/{version_name}+{version_code}/Inspection_Hub.apk'
    manifest = {
        'versionCode': version_code,
        'versionName': version_name,
        'objectKey': object_key,
        'sha256': digest,
        'releaseNotes': args.release_notes,
        'mandatory': args.mandatory,
    }

    endpoint = os.environ['MOBILE_RELEASES_ENDPOINT'].strip()
    endpoint_host = urlparse(endpoint).hostname or ''
    is_aws_s3 = endpoint_host.endswith('.amazonaws.com')
    addressing_style = os.environ.get('MOBILE_RELEASES_ADDRESSING_STYLE', 'path').strip()
    region = os.environ.get('MOBILE_RELEASES_REGION', '').strip()
    if is_aws_s3:
        region = region if region and region != 'auto' else 'ap-south-1'
        endpoint_url = None
    else:
        region = region or 'auto'
        endpoint_url = endpoint
    client = boto3.client(
        's3',
        endpoint_url=endpoint_url,
        region_name=region,
        aws_access_key_id=os.environ['MOBILE_RELEASES_ACCESS_KEY_ID'],
        aws_secret_access_key=os.environ['MOBILE_RELEASES_SECRET_ACCESS_KEY'],
        config=Config(signature_version='s3v4', s3={'addressing_style': addressing_style}),
    )
    bucket = os.environ['MOBILE_RELEASES_BUCKET']
    # A release APK is well below S3's 5 GB single-PUT limit. Using one PUT
    # avoids multipart-signature incompatibilities with S3-compatible stores.
    with args.apk.open('rb') as apk_stream:
        client.put_object(
            Bucket=bucket,
            Key=object_key,
            Body=apk_stream,
            ContentType='application/vnd.android.package-archive',
        )
    client.put_object(
        Bucket=bucket,
        Key='android/latest.json',
        Body=json.dumps(manifest).encode(),
        ContentType='application/json',
    )
    print(f'Published Inspection Hub {version_name}+{version_code}')


if __name__ == '__main__':
    main()
