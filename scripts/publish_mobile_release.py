import argparse
import hashlib
import json
import os
import re
from pathlib import Path

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

    client = boto3.client(
        's3',
        endpoint_url=os.environ['MOBILE_RELEASES_ENDPOINT'],
        region_name=os.environ.get('MOBILE_RELEASES_REGION', 'auto'),
        aws_access_key_id=os.environ['MOBILE_RELEASES_ACCESS_KEY_ID'],
        aws_secret_access_key=os.environ['MOBILE_RELEASES_SECRET_ACCESS_KEY'],
        config=Config(signature_version='s3v4', s3={'addressing_style': 'virtual'}),
    )
    bucket = os.environ['MOBILE_RELEASES_BUCKET']
    client.upload_file(
        str(args.apk),
        bucket,
        object_key,
        ExtraArgs={'ContentType': 'application/vnd.android.package-archive'},
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
