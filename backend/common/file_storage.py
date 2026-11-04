"""Shared helpers for private uploaded-file storage.

The default Django storage is S3 in production and the local filesystem in
development/tests. Database records store stable object keys; clients receive
short-lived URLs generated at response time.
"""

from dataclasses import dataclass
from pathlib import Path
import uuid

from django.core.files.storage import default_storage
from django.utils.text import get_valid_filename


@dataclass(frozen=True)
class StoredUpload:
    key: str
    url: str


def _safe_filename(filename: str) -> str:
    original = Path(filename or 'upload')
    stem = get_valid_filename(original.stem)[:80] or 'upload'
    suffix = original.suffix.lower()[:16]
    return f'{stem}-{uuid.uuid4().hex}{suffix}'


def save_uploaded_file(file_obj, prefix: str) -> StoredUpload:
    """Save an uploaded file and return its stable key and current URL."""
    clean_prefix = prefix.strip('/')
    key = default_storage.save(f'{clean_prefix}/{_safe_filename(file_obj.name)}', file_obj)
    return StoredUpload(key=key, url=default_storage.url(key))


def stored_file_url(
    key: str | None,
    fallback_url: str | None = None,
    *,
    expires: int | None = None,
) -> str | None:
    """Generate a fresh private URL for a stored key, with legacy fallback."""
    if key:
        try:
            if expires is not None:
                try:
                    return default_storage.url(key, expire=expires)
                except TypeError:
                    pass
            return default_storage.url(key)
        except Exception:
            pass
    return fallback_url or None


def delete_stored_file(key: str | None) -> None:
    if not key:
        return
    try:
        default_storage.delete(key)
    except Exception:
        # File deletion is best-effort; database cleanup must still succeed.
        return
