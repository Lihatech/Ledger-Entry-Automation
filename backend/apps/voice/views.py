import os
import time
import uuid
import logging
from pathlib import Path

from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework import status
from rest_framework.permissions import IsAuthenticated
from rest_framework.parsers import MultiPartParser, FormParser

from django.conf import settings

from .number_parser import parse_measurement
from .tasks import dispatch_transcription, get_job_result

logger = logging.getLogger(__name__)


class VoiceTranscribeView(APIView):
    """
    POST /api/voice/transcribe/

    Saves audio to disk, starts a background thread for Whisper transcription,
    and returns a job_id immediately (< 0.5 s). The client polls
    GET /api/voice/status/<job_id>/ every 2 seconds for the result.
    """
    permission_classes = [IsAuthenticated]
    parser_classes     = [MultiPartParser, FormParser]

    def post(self, request):
        t_req_start = time.perf_counter()
        audio_file = request.FILES.get('audio_file')
        if not audio_file:
            return Response(
                {'error': 'No audio file provided. Send as multipart with key "audio_file".'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        # Validate file extension
        allowed_extensions = {'.wav', '.mp3', '.m4a', '.webm', '.ogg', '.flac'}
        ext = Path(audio_file.name).suffix.lower()
        if ext not in allowed_extensions:
            return Response(
                {'error': f'Unsupported audio format: {ext}. Allowed: {allowed_extensions}'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        if audio_file.size <= 0 or audio_file.size > 20 * 1024 * 1024:
            return Response(
                {'error': 'Audio files must be larger than 0 bytes and no larger than 20 MB.'},
                status=status.HTTP_400_BAD_REQUEST,
            )

        file_size_kb = round(audio_file.size / 1024, 2)
        upload_dir = Path(settings.MEDIA_ROOT) / 'voice_uploads'
        upload_dir.mkdir(parents=True, exist_ok=True)

        filename  = f"{uuid.uuid4()}{ext}"
        file_path = upload_dir / filename

        t_save_start = time.perf_counter()
        with open(file_path, 'wb+') as dest:
            for chunk in audio_file.chunks():
                dest.write(chunk)
        save_duration_ms = (time.perf_counter() - t_save_start) * 1000

        # Start background thread : returns job_id immediately, no waiting
        t_dispatch_start = time.perf_counter()
        job_id = dispatch_transcription(str(file_path), request.user.id)
        dispatch_duration_ms = (time.perf_counter() - t_dispatch_start) * 1000

        total_post_ms = (time.perf_counter() - t_req_start) * 1000
        logger.info(
            "[PERF VIEW] POST /api/voice/transcribe/ | Size: %.2f KB | Disk Save: %.2f ms | Dispatch: %.2f ms | HTTP 202 Total: %.2f ms (job_id=%s)",
            file_size_kb, save_duration_ms, dispatch_duration_ms, total_post_ms, job_id
        )

        # S4 FIX: 'audio_path' removed : server-side file paths must never be
        # sent to clients (info disclosure). The client only needs job_id to poll.
        return Response(
            {
                'job_id':  job_id,
                'status':  'processing',
                'upload_meta': {
                    'file_size_kb':      file_size_kb,
                    'save_ms':           round(save_duration_ms, 2),
                    'post_response_ms':  round(total_post_ms, 2),
                }
            },
            status=status.HTTP_202_ACCEPTED,
        )


class VoiceStatusView(APIView):
    """
    GET /api/voice/status/<job_id>/

    Reads the transcription job's current state from Redis cache.
    The client calls this every 2 seconds after receiving a job_id.
    """
    permission_classes = [IsAuthenticated]

    def get(self, request, job_id):
        t_poll_start = time.perf_counter()
        result = get_job_result(job_id)
        lookup_ms = (time.perf_counter() - t_poll_start) * 1000

        logger.debug(
            "[PERF VIEW] GET /api/voice/status/%s | Status: %s | Redis Lookup: %.2f ms",
            job_id, result.get('status'), lookup_ms
        )

        if result.get('status') == 'failed':
            return Response(result, status=status.HTTP_500_INTERNAL_SERVER_ERROR)

        return Response(result)


class ParseTextView(APIView):
    """
    POST /api/voice/parse/
    Parse raw text to number without audio upload.
    Useful for testing the number parser directly.

    Request: { "text": "twenty five point zero one" }
    Response: { "raw_text": "...", "parsed_value": 25.01, "is_parseable": true }
    """
    permission_classes = [IsAuthenticated]

    def post(self, request):
        text = request.data.get('text', '').strip()
        if not text:
            return Response({'error': 'text field is required.'}, status=status.HTTP_400_BAD_REQUEST)

        parsed_value = parse_measurement(text)
        return Response({
            'raw_text':     text,
            'parsed_value': parsed_value,
            'is_parseable': parsed_value is not None,
        })
