import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import '../services/api_service.dart';

class BugReportScreen extends StatefulWidget {
  const BugReportScreen({super.key});

  @override
  State<BugReportScreen> createState() => _BugReportScreenState();
}

class _BugReportScreenState extends State<BugReportScreen> {
  final _messageController = TextEditingController();
  File? _screenshot;
  bool _isSubmitting = false;

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);
    if (pickedFile != null) {
      setState(() {
        _screenshot = File(pickedFile.path);
      });
    }
  }

  Future<void> _submitReport() async {
    if (_messageController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a description of the issue.')),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      var response = await _sendReport();
      if (response.statusCode == 401) {
        await response.stream.drain<void>();
        final refreshed = await ApiService.refreshToken();
        if (refreshed == true) {
          response = await _sendReport();
        } else if (refreshed == false) {
          await ApiService.clearTokens();
          ApiService.onUnauthenticated?.call();
          throw Exception('Your session has expired. Please sign in again.');
        } else {
          throw Exception('Unable to refresh your session. Please check your connection and try again.');
        }
      }

      final responseBody = await response.stream.bytesToString();

      if (response.statusCode == 201 || response.statusCode == 200) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Thank you! Your issue has been reported successfully.')),
          );
          Navigator.pop(context);
        }
      } else {
        throw Exception(_serverError(responseBody, response.statusCode));
      }
    } catch (e) {
      if (mounted) {
        final message = e.toString().replaceFirst(RegExp(r'^Exception: '), '');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  Future<http.StreamedResponse> _sendReport() async {
    final token = await ApiService.getToken();
    if (token == null || token.isEmpty) {
      throw Exception('Your session has expired. Please sign in again.');
    }

    final request = http.MultipartRequest(
      'POST',
      Uri.parse('${ApiService.baseUrl}/support/bug-reports/'),
    );
    request.headers['Authorization'] = 'Bearer $token';
    request.fields['message'] = _messageController.text.trim();

    if (_screenshot != null) {
      request.files.add(
        await http.MultipartFile.fromPath('screenshot', _screenshot!.path),
      );
    }

    return request.send().timeout(const Duration(seconds: 35));
  }

  String _serverError(String responseBody, int statusCode) {
    try {
      final data = jsonDecode(responseBody);
      if (data is Map<String, dynamic>) {
        final message = data['detail'] ?? data['error'] ?? data['message'];
        if (message is String && message.isNotEmpty) return message;
      }
    } catch (_) {}
    return 'Failed to submit bug report (HTTP $statusCode).';
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Report an Issue', style: TextStyle(color: Colors.white)),
        backgroundColor: const Color(0xFF0F172A),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Describe the issue or bug',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _messageController,
              maxLines: 5,
              decoration: InputDecoration(
                hintText: 'What went wrong? Please provide details...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              enabled: !_isSubmitting,
            ),
            const SizedBox(height: 24),
            const Text(
              'Screenshot (Optional)',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            if (_screenshot != null) ...[
              Stack(
                children: [
                  Image.file(_screenshot!, height: 150, fit: BoxFit.cover),
                  Positioned(
                    right: 0,
                    top: 0,
                    child: IconButton(
                      icon: const Icon(Icons.close, color: Colors.red),
                      onPressed: () => setState(() => _screenshot = null),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            ElevatedButton.icon(
              onPressed: _isSubmitting ? null : _pickImage,
              icon: const Icon(Icons.image),
              label: const Text('Attach Screenshot'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFF1F5F9),
                foregroundColor: const Color(0xFF0F172A),
              ),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: _isSubmitting ? null : _submitReport,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4F46E5),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: _isSubmitting
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Text('Submit Report', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
