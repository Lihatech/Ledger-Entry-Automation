"""Helpers for delivering controlled documents from private media storage."""

from common.file_storage import stored_file_url


def _to_https(url):
    if url and url.startswith('http://'):
        return 'https://' + url[7:]
    return url


def document_delivery_url(document):
    """Return a browser-readable URL for a stored document file."""
    return _to_https(stored_file_url(document.cloudinary_public_id, document.cloudinary_url))

