import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'api_service.dart';

class AppUpdateService {
  static bool _checking = false;

  static Future<void> checkAndPrompt(BuildContext context) async {
    if (_checking || !Platform.isAndroid) return;
    _checking = true;

    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final versionCode = int.tryParse(packageInfo.buildNumber) ?? 0;
      final response = await ApiService.authenticatedRequest(
        (headers) => http
            .get(
              Uri.parse(
                '${ApiService.baseUrl}/support/mobile-update/?version_code=$versionCode',
              ),
              headers: headers,
            )
            .timeout(const Duration(seconds: 20)),
      );

      if (response.statusCode != 200 || !context.mounted) return;
      final update = jsonDecode(response.body) as Map<String, dynamic>;
      if (update['updateAvailable'] != true) return;

      final mandatory = update['mandatory'] == true;
      final accepted = await showDialog<bool>(
        context: context,
        barrierDismissible: !mandatory,
        builder: (dialogContext) => PopScope(
          canPop: !mandatory,
          child: AlertDialog(
            title: Text('Update ${update['versionName']} available'),
            content: Text(
              (update['releaseNotes'] as String?)?.trim().isNotEmpty == true
                  ? update['releaseNotes'] as String
                  : 'A new version of Inspection Hub is ready.',
            ),
            actions: [
              if (!mandatory)
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Later'),
                ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Update now'),
              ),
            ],
          ),
        ),
      );

      if (accepted == true && context.mounted) {
        await _downloadAndInstall(context, update);
      }
    } catch (_) {
      // Update checks are best-effort and must never block normal app use.
    } finally {
      _checking = false;
    }
  }

  static Future<void> _downloadAndInstall(
    BuildContext context,
    Map<String, dynamic> update,
  ) async {
    final downloadUri = Uri.parse(update['downloadUrl'] as String);
    if (downloadUri.scheme != 'https') {
      _showError(context, 'The update download link is not secure.');
      return;
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text('Downloading update'),
          content: LinearProgressIndicator(),
        ),
      ),
    );

    File? apk;
    var progressIsOpen = true;
    try {
      final directory =
          await getExternalStorageDirectory() ?? await getTemporaryDirectory();
      apk = File('${directory.path}/Inspection_Hub_update.apk');

      final client = http.Client();
      try {
        final streamed = await client
            .send(http.Request('GET', downloadUri))
            .timeout(const Duration(minutes: 2));
        if (streamed.statusCode != 200) {
          throw HttpException('Download failed (${streamed.statusCode})');
        }
        await streamed.stream.pipe(apk.openWrite());
      } finally {
        client.close();
      }

      final actualHash = (await sha256.bind(apk.openRead()).first).toString();
      final expectedHash = (update['sha256'] as String).toLowerCase();
      if (actualHash != expectedHash) {
        await apk.delete();
        throw const FormatException('Update verification failed');
      }

      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
      progressIsOpen = false;

      final permission = await Permission.requestInstallPackages.request();
      if (!permission.isGranted) {
        throw const FileSystemException(
          'Allow Inspection Hub to install unknown apps, then try again.',
        );
      }

      final result = await OpenFilex.open(
        apk.path,
        type: 'application/vnd.android.package-archive',
      );
      if (result.type != ResultType.done) {
        throw FileSystemException(result.message);
      }
    } catch (error) {
      if (context.mounted) {
        if (progressIsOpen) {
          Navigator.of(context, rootNavigator: true).pop();
        }
        _showError(context, error.toString().replaceFirst('Exception: ', ''));
      }
    }
  }

  static void _showError(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Update failed: $message')),
    );
  }
}
