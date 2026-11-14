import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:file_saver/file_saver.dart';
import 'api_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// DATA MODELS
// ─────────────────────────────────────────────────────────────────────────────

class Document {
  final String id;
  final String documentNumber;
  final String title;
  final String description;
  final String status;
  final String revision;
  final String docLevel; // 'L1', 'L2', 'L3', 'L4'
  final String? cloudinaryUrl;
  final String? fileName;
  final int? fileSize;
  final String? uploadedByName;
  final String? approvedByName;
  final String? effectiveDate;
  final String? revisionDate;
  final String createdAt;

  Document({
    required this.id,
    required this.documentNumber,
    required this.title,
    required this.description,
    required this.status,
    required this.revision,
    this.docLevel = 'L2',
    this.cloudinaryUrl,
    this.fileName,
    this.fileSize,
    this.uploadedByName,
    this.approvedByName,
    this.effectiveDate,
    this.revisionDate,
    required this.createdAt,
  });

  factory Document.fromJson(Map<String, dynamic> json) => Document(
    id: json['id'] as String,
    documentNumber: json['document_number'] as String? ?? '',
    title: json['title'] as String? ?? '',
    description: json['description'] as String? ?? '',
    status: json['status'] as String? ?? 'draft',
    revision: json['revision'] as String? ?? '0',
    docLevel: json['doc_level'] as String? ?? 'L2',
    cloudinaryUrl:
        (json['delivery_url'] as String?) ??
        (json['cloudinary_url'] as String?),
    fileName: json['file_name'] as String?,
    fileSize: json['file_size'] as int?,
    uploadedByName: json['uploaded_by_name'] as String?,
    approvedByName: json['approved_by_name'] as String?,
    effectiveDate: json['effective_date'] as String?,
    revisionDate: json['revision_date'] as String?,
    createdAt: json['created_at'] as String? ?? '',
  );

  String get fileSizeDisplay {
    if (fileSize == null) return 'N/A';
    if (fileSize! < 1024) return '$fileSize B';
    if (fileSize! < 1024 * 1024)
      return '${(fileSize! / 1024).toStringAsFixed(1)} KB';
    return '${(fileSize! / 1024 / 1024).toStringAsFixed(2)} MB';
  }

  String get docLevelLabel {
    switch (docLevel) {
      case 'L1':
        return 'L1 Quality Manual';
      case 'L2':
        return 'L2 Procedures';
      case 'L3':
        return 'L3 Work Instructions';
      case 'L4':
        return 'L4 Forms & Formats';
      default:
        return 'L2 Procedures';
    }
  }
}

class DocumentChangeRequest {
  final int id;
  final String dcrNumber;
  final String documentId;
  final String documentNumber;
  final String documentTitle;
  final String docLevel;
  final String status;
  final String statusDisplay;
  final String changeType;
  final String changeTypeDisplay;
  final String reasonForChange;
  final String natureOfChange;
  final String existingRevision;
  final String proposedRevision;
  final String requestorName;
  final String? reviewerName;
  final String? reviewerRole;
  final String? calibratorName;
  final String? approverName;
  final String? rejectedReason;
  final String? rejectionStage;
  final String? reviewerComments;
  final String? approvalComments;
  final String? documentCloudinaryUrl;
  final String createdAt;

  DocumentChangeRequest({
    required this.id,
    required this.dcrNumber,
    required this.documentId,
    required this.documentNumber,
    required this.documentTitle,
    required this.docLevel,
    required this.status,
    required this.statusDisplay,
    required this.changeType,
    required this.changeTypeDisplay,
    required this.reasonForChange,
    required this.natureOfChange,
    required this.existingRevision,
    required this.proposedRevision,
    required this.requestorName,
    this.reviewerName,
    this.reviewerRole,
    this.calibratorName,
    this.approverName,
    this.rejectedReason,
    this.rejectionStage,
    this.reviewerComments,
    this.approvalComments,
    this.documentCloudinaryUrl,
    required this.createdAt,
  });

  factory DocumentChangeRequest.fromJson(Map<String, dynamic> json) =>
      DocumentChangeRequest(
        id: json['id'] as int,
        dcrNumber: json['dcr_number'] as String? ?? '',
        documentId: json['document'] is Map
            ? json['document']['id'] as String? ?? ''
            : (json['document']?.toString() ?? ''),
        documentNumber: json['document_number'] as String? ?? '',
        documentTitle: json['document_title'] as String? ?? '',
        docLevel: json['doc_level'] as String? ?? 'L2',
        status: json['status'] as String? ?? 'submitted',
        statusDisplay: json['status_display'] as String? ?? 'Submitted',
        changeType: json['change_type'] as String? ?? 'modification',
        changeTypeDisplay:
            json['change_type_display'] as String? ?? 'Modification',
        reasonForChange: json['reason_for_change'] as String? ?? '',
        natureOfChange: json['nature_of_change'] as String? ?? '',
        existingRevision: json['existing_revision'] as String? ?? 'Rev A',
        proposedRevision: json['proposed_revision'] as String? ?? 'Rev B',
        requestorName: json['requestor_name'] as String? ?? '',
        reviewerName: json['reviewer_name'] as String?,
        reviewerRole: json['reviewer_role'] as String?,
        calibratorName: json['calibrator_name'] as String?,
        approverName: json['approver_name'] as String?,
        rejectedReason: json['rejected_reason'] as String?,
        rejectionStage: json['rejection_stage'] as String?,
        reviewerComments: json['reviewer_comments'] as String?,
        approvalComments: json['approval_comments'] as String?,
        documentCloudinaryUrl: json['document_cloudinary_url'] as String?,
        createdAt: json['created_at'] as String? ?? '',
      );
}

class DCRNotification {
  final int id;
  final String title;
  final String message;
  final String notificationType;
  final String? actionUrl;
  final int? dcrId;
  final String? dcrNumber;
  final bool isRead;
  final String createdAt;

  DCRNotification({
    required this.id,
    required this.title,
    required this.message,
    required this.notificationType,
    this.actionUrl,
    this.dcrId,
    this.dcrNumber,
    required this.isRead,
    required this.createdAt,
  });

  factory DCRNotification.fromJson(Map<String, dynamic> json) =>
      DCRNotification(
        id: json['id'] as int,
        title: json['title'] as String? ?? '',
        message: json['message'] as String? ?? '',
        notificationType:
            (json['notification_type'] ?? json['action_type']) as String? ??
            'system',
        actionUrl: json['action_url'] as String?,
        dcrId: json['dcr'] as int?,
        dcrNumber: json['dcr_number'] as String?,
        isRead: json['is_read'] as bool? ?? false,
        createdAt: json['created_at'] as String? ?? '',
      );
}

class DCRUser {
  final int id;
  final String username;
  final String fullName;
  final String role;

  DCRUser({
    required this.id,
    required this.username,
    required this.fullName,
    required this.role,
  });

  factory DCRUser.fromJson(Map<String, dynamic> json) => DCRUser(
    id: json['id'] as int,
    username: json['username'] as String? ?? '',
    fullName: json['full_name'] as String? ?? '',
    role: json['role'] as String? ?? '',
  );
}

class DocumentActivity {
  final String action;
  final String performedByName;
  final String comment;
  final String timestamp;

  DocumentActivity({
    required this.action,
    required this.performedByName,
    required this.comment,
    required this.timestamp,
  });

  factory DocumentActivity.fromJson(Map<String, dynamic> json) =>
      DocumentActivity(
        action: json['action'] as String? ?? '',
        performedByName: json['performed_by_name'] as String? ?? 'Unknown',
        comment: json['comment'] as String? ?? '',
        timestamp: json['timestamp'] as String? ?? '',
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// SERVICE CLASS
// ─────────────────────────────────────────────────────────────────────────────

class DocumentControlService {
  String get _baseUrl => '${ApiService.baseUrl}/document-control';

  Future<Map<String, String>> _headers() async {
    final token = await ApiService.getToken();
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  // ── Documents ──────────────────────────────────────────────────────────────

  /// Fetch list of documents. Optionally filter by [search], [category], [status], [level].
  Future<List<Document>> getDocuments({
    String? search,
    String? status,
    String? level,
  }) async {
    final queryParams = <String, String>{};
    if (search != null && search.isNotEmpty) queryParams['search'] = search;
    if (status != null && status.isNotEmpty) queryParams['status'] = status;
    if (level != null && level.isNotEmpty) queryParams['level'] = level;

    final uri = Uri.parse(
      '$_baseUrl/documents/',
    ).replace(queryParameters: queryParams.isNotEmpty ? queryParams : null);

    final response = await http.get(uri, headers: await _headers());
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      final list = data is List ? data : (data['results'] ?? []) as List;
      return list
          .map((e) => Document.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    throw Exception('Failed to load documents: ${response.statusCode}');
  }

  /// Fetch a single document by [id].
  Future<Document> getDocumentById(String id) async {
    final uri = Uri.parse('$_baseUrl/documents/$id/');
    final response = await http.get(uri, headers: await _headers());
    if (response.statusCode == 200) {
      return Document.fromJson(
        json.decode(response.body) as Map<String, dynamic>,
      );
    }
    throw Exception('Failed to load document: ${response.statusCode}');
  }

  /// Fetch activity log for a document.
  Future<List<DocumentActivity>> getDocumentHistory(String id) async {
    final uri = Uri.parse('$_baseUrl/documents/$id/history/');
    final response = await http.get(uri, headers: await _headers());
    if (response.statusCode == 200) {
      final list = json.decode(response.body) as List;
      return list
          .map((e) => DocumentActivity.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    throw Exception('Failed to load history: ${response.statusCode}');
  }

  /// Download a document file directly to device storage
  Future<String?> downloadDocumentFile(Document doc) async {
    final url = doc.cloudinaryUrl;
    if (url == null || url.isEmpty) return null;

    try {
      final uri = Uri.parse(url);
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        if (kIsWeb) {
          String name = doc.fileName ?? '${doc.documentNumber}_document.pdf';
          String ext = name.contains('.') ? name.split('.').last : '';
          name = name.replaceAll(RegExp(r'\.[^.]+$'), ''); // remove extension

          await FileSaver.instance.saveFile(
            name: name,
            bytes: response.bodyBytes,
            ext: ext,
            mimeType: MimeType.other,
          );
          return 'web_downloaded';
        } else {
          Directory dir;
          try {
            dir =
                (await getDownloadsDirectory()) ??
                (await getApplicationDocumentsDirectory());
          } catch (_) {
            dir = await getApplicationDocumentsDirectory();
          }

          String name = doc.fileName ?? '${doc.documentNumber}_document.pdf';
          name = name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');

          final filePath = '${dir.path}/$name';
          final file = File(filePath);
          await file.writeAsBytes(response.bodyBytes);
          debugPrint('[DocumentControlService] Document saved to: $filePath');
          return filePath;
        }
      }
    } catch (e) {
      debugPrint('[DocumentControlService] Download error: $e');
    }
    return null;
  }

  // ── Document Change Requests (Form DKI/MR/F/05) ────────────────────────────

  /// Fetch list of change requests.
  Future<List<DocumentChangeRequest>> getDCRs({
    String? status,
    String? tab,
    String? search,
  }) async {
    final queryParams = <String, String>{};
    if (status != null && status.isNotEmpty) queryParams['status'] = status;
    if (tab != null && tab.isNotEmpty) queryParams['tab'] = tab;
    if (search != null && search.isNotEmpty) queryParams['search'] = search;

    final uri = Uri.parse(
      '$_baseUrl/change-requests/',
    ).replace(queryParameters: queryParams.isNotEmpty ? queryParams : null);

    final response = await http.get(uri, headers: await _headers());
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      final list = data is List ? data : (data['results'] ?? []) as List;
      return list
          .map((e) => DocumentChangeRequest.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    throw Exception('Failed to load change requests: ${response.statusCode}');
  }

  /// Fetch a single DCR by [id].
  Future<DocumentChangeRequest> getDCRById(int id) async {
    final uri = Uri.parse('$_baseUrl/change-requests/$id/');
    final response = await http.get(uri, headers: await _headers());
    if (response.statusCode == 200) {
      return DocumentChangeRequest.fromJson(
        json.decode(response.body) as Map<String, dynamic>,
      );
    }
    throw Exception('Failed to load DCR: ${response.statusCode}');
  }

  /// Fetch assignable users (reviewers, approvers).
  Future<Map<String, List<DCRUser>>> getAssignableUsers() async {
    final uri = Uri.parse('$_baseUrl/change-requests/assignable_users/');
    final response = await http.get(uri, headers: await _headers());
    if (response.statusCode == 200) {
      final data = json.decode(response.body) as List<dynamic>;
      final allUsers = data
          .map((e) => DCRUser.fromJson(e as Map<String, dynamic>))
          .toList();
      return {'reviewers': allUsers, 'approvers': allUsers};
    }
    throw Exception('Failed to load assignable users: ${response.statusCode}');
  }

  /// Submit a new DCR (Form DKI/MR/F/05).
  Future<DocumentChangeRequest> submitDCR({
    required String documentId,
    required String changeType,
    required String reasonForChange,
    required String existingRevision,
    required String proposedRevision,
    String? natureOfChange,
    String? formDocNo,
    String? issueNoDate,
    String? revNoDate,
    required int reviewerId,
    int? calibratorId,
    required int approverId,
  }) async {
    final uri = Uri.parse('$_baseUrl/change-requests/submit/');
    final body = {
      'document_id': documentId,
      'change_type': changeType,
      'reason_for_change': reasonForChange,
      'nature_of_change': natureOfChange ?? '',
      'form_doc_no': formDocNo ?? 'DKI/MR/F/05',
      'issue_no_date': issueNoDate ?? '01/01.04.2018',
      'rev_no_date': revNoDate ?? '01/01.04.2018',
      'existing_revision': existingRevision,
      'proposed_revision': proposedRevision,
      'reviewer_id': reviewerId,
      if (calibratorId != null) 'calibrator_id': calibratorId,
      'approver_id': approverId,
    };

    final response = await http.post(
      uri,
      headers: await _headers(),
      body: json.encode(body),
    );
    if (response.statusCode == 201) {
      return DocumentChangeRequest.fromJson(
        json.decode(response.body) as Map<String, dynamic>,
      );
    }
    final err = json.decode(response.body);
    throw Exception(
      err['error'] ?? 'Failed to submit DCR: ${response.statusCode}',
    );
  }

  /// Submit review (CFT Reviewer action).
  Future<void> submitReview(
    int dcrId, {
    required String action, // 'approve' or 'reject'
    String? comments,
    String? rejectedReason,
  }) async {
    final endpoint = action == 'reject'
        ? '$_baseUrl/change-requests/$dcrId/reject_review/'
        : '$_baseUrl/change-requests/$dcrId/submit_review/';
    final uri = Uri.parse(endpoint);
    final body = action == 'reject'
        ? {'rejected_reason': rejectedReason ?? ''}
        : {'comments': comments ?? ''};

    final response = await http.post(
      uri,
      headers: await _headers(),
      body: json.encode(body),
    );
    if (response.statusCode != 200) {
      final err = json.decode(response.body);
      throw Exception(
        err['error'] ?? 'Review action failed: ${response.statusCode}',
      );
    }
  }

  /// Submit approval (Management Representative / Admin action).
  Future<void> submitApproval(
    int dcrId, {
    required String action, // 'approve' or 'reject'
    String? comments,
    String? rejectedReason,
  }) async {
    final endpoint = action == 'reject'
        ? '$_baseUrl/change-requests/$dcrId/reject_approval/'
        : '$_baseUrl/change-requests/$dcrId/approve/';
    final uri = Uri.parse(endpoint);
    final body = action == 'reject'
        ? {'rejected_reason': rejectedReason ?? ''}
        : {'comments': comments ?? ''};

    final response = await http.post(
      uri,
      headers: await _headers(),
      body: json.encode(body),
    );
    if (response.statusCode != 200) {
      final err = json.decode(response.body);
      throw Exception(
        err['error'] ?? 'Approval action failed: ${response.statusCode}',
      );
    }
  }

  // ── Notifications ──────────────────────────────────────────────────────────

  /// Get list of notifications for current user.
  Future<List<DCRNotification>> getNotifications() async {
    final uri = Uri.parse('$_baseUrl/notifications/');
    final response = await http.get(uri, headers: await _headers());
    if (response.statusCode == 200) {
      final list = json.decode(response.body) as List;
      return list
          .map((e) => DCRNotification.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    throw Exception('Failed to load notifications: ${response.statusCode}');
  }

  /// Get count of unread notifications.
  Future<int> getUnreadNotificationCount() async {
    try {
      final uri = Uri.parse('$_baseUrl/notifications/unread_count/');
      final response = await http.get(uri, headers: await _headers());
      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        return data['unread_count'] as int? ?? 0;
      }
    } catch (_) {}
    return 0;
  }

  /// Mark single notification as read.
  Future<void> markNotificationAsRead(int id) async {
    final uri = Uri.parse('$_baseUrl/notifications/$id/mark_read/');
    await http.post(uri, headers: await _headers());
  }

  /// Mark a single notification as unread.
  Future<void> markNotificationAsUnread(int id) async {
    final uri = Uri.parse('$_baseUrl/notifications/$id/mark_unread/');
    await http.post(uri, headers: await _headers());
  }

  /// Mark all notifications as read.
  Future<void> markAllNotificationsAsRead() async {
    final uri = Uri.parse('$_baseUrl/notifications/mark_all_read/');
    await http.post(uri, headers: await _headers());
  }
}
