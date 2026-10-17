import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../providers/company_provider.dart';
import '../providers/inspection_provider.dart';
import '../providers/notification_provider.dart';
import '../models/notification_item.dart';
import '../services/api_service.dart';
import '../services/app_update_service.dart';
import '../services/persistence_service.dart';
import 'account_screen.dart';
import 'machine_select_screen.dart';
import 'operation_select_screen.dart';
import 'daily_production_report_screen.dart';
import 'inspection_voice_screen.dart';
import 'report_sheet_screen.dart';
import 'tasks_screen.dart';
import 'messaging/messages_screen.dart';
import 'jh_inspection_screen.dart';
import 'document_control_screen.dart';
import 'bug_report_screen.dart';
import 'run_chart_screen.dart';

class AppHomeScreen extends StatefulWidget {
  const AppHomeScreen({super.key});

  @override
  State<AppHomeScreen> createState() => _AppHomeScreenState();
}

class _AppHomeScreenState extends State<AppHomeScreen> {
  int _currentIndex = 0;
  List<dynamic> _teamMembers = [];

  @override
  void initState() {
    super.initState();
    _loadDashboardData();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppUpdateService.checkAndPrompt(context);
    });
  }

  Future<void> _loadDashboardData() async {
    final notificationProvider = Provider.of<NotificationProvider>(
      context,
      listen: false,
    );
    final inspectionProvider = Provider.of<InspectionProvider>(
      context,
      listen: false,
    );
    try {
      final provider = inspectionProvider;
      final machineId = provider.selectedMachine?['id'];

      // 1. Fetch pending supervisor rejections
      await provider.fetchPendingRejections();

      // 2. Fetch machine setup approval status
      bool approved = false;
      String msg = '';
      if (machineId != null) {
        final res = await ApiService.checkSetupApproved(machineId);
        approved = res['is_setup_approved'] == true;
        msg = res['message'] ?? '';
        final hasReport =
            res['has_today_report'] == true || res['session_id'] != null;
        if (hasReport) {
          await provider.restoreActiveReportState(res);
        } else {
          await provider.resetSessionState();
        }
      }

      // 3. Build Notifications List from Supervisor Actions
      final List<Map<String, dynamic>> notifs = [];

      // Add Rejection / Corrective Trial Notifications from Supervisor
      for (var rej in provider.activeRejections) {
        final currentTrial = rej['trial_number'] ?? 1;
        final nextTrial = currentTrial + 1;
        final remark =
            rej['rejection_reason'] ??
            rej['supervisor_remark'] ??
            'Targeted parameter correction requested.';
        final List<dynamic> params = rej['rejected_parameters'] ?? [];

        notifs.add({
          'id': 'rej_${rej['id'] ?? rej['session_id']}',
          'type': 'rejection',
          'title': '🚨 Supervisor Rejection & Retrial Notice',
          'subtitle': 'Supervisor requested corrective trial #$nextTrial',
          'message': 'Remark: "$remark"',
          'details': params.isNotEmpty
              ? 'Targeted Params: ${params.join(", ")}'
              : 'All parameters require re-verification.',
          'time': 'Just now',
          'is_read': false,
          'raw_rej': rej,
          'next_trial': nextTrial,
        });
      }

      // Add Setup Approval Notification
      if (approved) {
        notifs.add({
          'id': 'setup_approved',
          'type': 'approval',
          'title': '✓ 1st Piece Setup Authorized',
          'subtitle': 'Supervisor / Quality Inspector',
          'message': msg.isNotEmpty
              ? msg
              : 'First Piece inspection finalized and PASSED. Hourly in-process inspections unlocked.',
          'time': 'Active Shift',
          'is_read': false,
        });
      }

      // Fetch dynamic station team operators from backend (100% dynamic from backend API)
      List<dynamic> operatorsOnly = _teamMembers;
      try {
        final dynamicUsers = await ApiService.getUsers(role: 'operator');
        operatorsOnly = dynamicUsers.where((u) {
          final role = (u['role'] ?? '').toString().toLowerCase();
          return role == 'operator';
        }).toList();
      } catch (_) {}

      if (mounted) {
        setState(() {
          _teamMembers = operatorsOnly;
        });

        notificationProvider.replaceCategory(
          NotificationCategory.supervisor,
          notifs.map(_toNotificationItem).toList(),
        );
      }
    } catch (_) {
      // Handle error silently
    }
  }

  Future<void> _selectWorkingShift(
    BuildContext context,
    AuthProvider auth,
    CompanyProvider company,
  ) async {
    if (!auth.isOperator && !auth.isInspector) return;

    final availableShifts = company.availableShifts;
    final currentShift = availableShifts.contains(auth.assignedShift)
        ? auth.assignedShift
        : availableShifts.first;
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 4, 24, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Select current shift',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            ...availableShifts.map(
              (shift) => RadioListTile<String>(
                value: shift,
                groupValue: currentShift,
                title: Text('Shift $shift'),
                subtitle: Text('${company.shiftHours}-hour schedule'),
                onChanged: (value) => Navigator.pop(sheetContext, value),
              ),
            ),
          ],
        ),
      ),
    );

    if (!mounted || selected == null || selected == auth.assignedShift) return;
    final result = await auth.changeAssignedShift(selected);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result['success'] == true
              ? 'Current shift changed to Shift $selected.'
              : (result['message'] ?? 'Unable to change shift.'),
        ),
        backgroundColor: result['success'] == true
            ? const Color(0xFF16A34A)
            : const Color(0xFFDC2626),
      ),
    );
  }

  void _showNotificationsModal(BuildContext context) {
    final provider = Provider.of<InspectionProvider>(context, listen: false);
    final notificationProvider = Provider.of<NotificationProvider>(
      context,
      listen: false,
    );
    var searchQuery = '';
    var selectedFilter = 'all';

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final liveNotificationProvider = Provider.of<NotificationProvider>(
              context,
            );
            final allNotifications = liveNotificationProvider.items;
            final unreadCount = liveNotificationProvider.unreadCount;
            final readCount = allNotifications.length - unreadCount;
            final normalizedQuery = searchQuery.trim().toLowerCase();
            final notifications = allNotifications.where((item) {
              final matchesFilter =
                  selectedFilter == 'all' ||
                  (selectedFilter == 'unread' && !item.isRead) ||
                  (selectedFilter == 'read' && item.isRead);
              if (!matchesFilter) return false;
              if (normalizedQuery.isEmpty) return true;
              return item.title.toLowerCase().contains(normalizedQuery) ||
                  item.message.toLowerCase().contains(normalizedQuery) ||
                  (item.dcrNumber ?? '').toLowerCase().contains(
                    normalizedQuery,
                  );
            }).toList();

            return Container(
              padding: const EdgeInsets.all(20),
              height: MediaQuery.of(context).size.height * 0.75,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Modal Header
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Wrap(
                        spacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: const Color(
                                0xFF0284C7,
                              ).withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(
                              Icons.notifications_active_rounded,
                              color: Color(0xFF0284C7),
                              size: 22,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Global Notifications',
                                style: TextStyle(
                                  color: Color(0xFF0F172A),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                              Text(
                                '$unreadCount Unread Notification${unreadCount == 1 ? '' : 's'}',
                                style: const TextStyle(
                                  color: Color(0xFF64748B),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      if (unreadCount > 0)
                        TextButton(
                          onPressed: () async {
                            await notificationProvider.markAllAsRead();
                            setModalState(() {});
                          },
                          child: const Text(
                            'Mark all read',
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xFF0284C7),
                            ),
                          ),
                        ),
                      IconButton(
                        icon: const Icon(
                          Icons.close_rounded,
                          color: Color(0xFF94A3B8),
                        ),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),
                  TextField(
                    onChanged: (value) {
                      setModalState(() => searchQuery = value);
                    },
                    decoration: InputDecoration(
                      hintText: 'Search notifications',
                      prefixIcon: const Icon(Icons.search_rounded, size: 20),
                      suffixIcon: searchQuery.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear_rounded, size: 18),
                              onPressed: () => setModalState(() {
                                searchQuery = '';
                              }),
                            ),
                      filled: true,
                      fillColor: const Color(0xFFF1F5F9),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _notificationFilterChip(
                          label: 'All (${allNotifications.length})',
                          value: 'all',
                          selected: selectedFilter,
                          onSelected: (value) =>
                              setModalState(() => selectedFilter = value),
                        ),
                        const SizedBox(width: 8),
                        _notificationFilterChip(
                          label: 'Unread ($unreadCount)',
                          value: 'unread',
                          selected: selectedFilter,
                          onSelected: (value) =>
                              setModalState(() => selectedFilter = value),
                        ),
                        const SizedBox(width: 8),
                        _notificationFilterChip(
                          label: 'Read ($readCount)',
                          value: 'read',
                          selected: selectedFilter,
                          onSelected: (value) =>
                              setModalState(() => selectedFilter = value),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Divider(color: Color(0xFF1E293B)),
                  const SizedBox(height: 10),

                  // Notifications List
                  Expanded(
                    child: notifications.isEmpty
                        ? const Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.notifications_none_rounded,
                                  color: Color(0xFF64748B),
                                  size: 48,
                                ),
                                SizedBox(height: 12),
                                Text(
                                  'No notifications yet',
                                  style: TextStyle(
                                    color: Color(0xFF94A3B8),
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : ListView.builder(
                            itemCount: notifications.length,
                            itemBuilder: (context, index) {
                              final item = notifications[index];
                              final isRead = item.isRead;
                              final type = item.category;
                              final rawRejection = item.metadata['raw_rej'];
                              final nextTrial = item.metadata['next_trial'];

                              Color cardBorder = const Color(0xFF1E293B);
                              Color iconColor = const Color(0xFF38BDF8);
                              if (type == NotificationCategory.supervisor &&
                                  rawRejection != null) {
                                cardBorder = const Color(0xFFEF4444);
                                iconColor = const Color(0xFFEF4444);
                              } else if (type ==
                                  NotificationCategory.supervisor) {
                                cardBorder = const Color(0xFF10B981);
                                iconColor = const Color(0xFF10B981);
                              } else if (type == NotificationCategory.dcr ||
                                  type == NotificationCategory.document) {
                                cardBorder = const Color(0xFF0284C7);
                                iconColor = const Color(0xFF0284C7);
                              }

                              return Container(
                                margin: const EdgeInsets.only(bottom: 12),
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: isRead
                                      ? const Color(0xFF161F32)
                                      : const Color(0xFF1E293B),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: cardBorder,
                                    width: isRead ? 1 : 1.5,
                                  ),
                                ),
                                child: InkWell(
                                  onTap: () async {
                                    await _openNotification(
                                      ctx,
                                      item,
                                      notificationProvider,
                                    );
                                    if (mounted) setModalState(() {});
                                  },
                                  borderRadius: BorderRadius.circular(16),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          Expanded(
                                            child: Text(
                                              item.title,
                                              style: TextStyle(
                                                color: isRead
                                                    ? Colors.white70
                                                    : Colors.white,
                                                fontWeight: FontWeight.bold,
                                                fontSize: 14,
                                              ),
                                            ),
                                          ),
                                          Text(
                                            _notificationTime(item),
                                            style: const TextStyle(
                                              color: Color(0xFF64748B),
                                              fontSize: 11,
                                            ),
                                          ),
                                          PopupMenuButton<String>(
                                            icon: const Icon(
                                              Icons.more_vert_rounded,
                                              color: Color(0xFF94A3B8),
                                              size: 18,
                                            ),
                                            padding: EdgeInsets.zero,
                                            onSelected: (value) async {
                                              if (value == 'read') {
                                                await notificationProvider
                                                    .markAsRead(item);
                                              } else if (value == 'unread') {
                                                await notificationProvider
                                                    .markAsUnread(item);
                                              }
                                              setModalState(() {});
                                            },
                                            itemBuilder: (context) => [
                                              PopupMenuItem<String>(
                                                value: isRead
                                                    ? 'unread'
                                                    : 'read',
                                                child: Text(
                                                  isRead
                                                      ? 'Mark unread'
                                                      : 'Mark read',
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        _notificationCategoryLabel(item),
                                        style: TextStyle(
                                          color: iconColor,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        item.message,
                                        style: const TextStyle(
                                          color: Color(0xFFCBD5E1),
                                          fontSize: 12.5,
                                        ),
                                      ),
                                      if (item.metadata['details'] != null) ...[
                                        const SizedBox(height: 4),
                                        Text(
                                          item.metadata['details'].toString(),
                                          style: const TextStyle(
                                            color: Color(0xFFFDE68A),
                                            fontSize: 11.5,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ],

                                      // Action Button for Rejection Notification
                                      if (type ==
                                              NotificationCategory.supervisor &&
                                          rawRejection != null) ...[
                                        const SizedBox(height: 12),
                                        ElevatedButton.icon(
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: const Color(
                                              0xFFEF4444,
                                            ),
                                            foregroundColor: Colors.white,
                                            minimumSize: const Size(
                                              double.infinity,
                                              38,
                                            ),
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(10),
                                            ),
                                          ),
                                          icon: const Icon(
                                            Icons.play_arrow_rounded,
                                            color: Colors.white,
                                            size: 18,
                                          ),
                                          label: Text(
                                            'START CORRECTIVE TRIAL (1ST PC #$nextTrial)',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 12,
                                            ),
                                          ),
                                          onPressed: () async {
                                            Navigator.pop(ctx);
                                            final rej = rawRejection;
                                            final List<dynamic> rejectedParams =
                                                rej['rejected_parameters'] ??
                                                [];
                                            final partNo =
                                                provider
                                                    .selectedPart?['part_number'] ??
                                                'FBT00222';
                                            final templates =
                                                await ApiService.getTemplatesByPart(
                                                  partNo,
                                                );

                                            if (templates.isNotEmpty) {
                                              final targetTemplate =
                                                  templates.first;
                                              await provider.loadParameters(
                                                targetTemplate,
                                                targetRejectedCodes:
                                                    rejectedParams,
                                              );
                                              final parentId =
                                                  rej['session_id'] ??
                                                  rej['id'];
                                              final started = await provider
                                                  .startSession(
                                                    trial: nextTrial,
                                                    parentId: parentId,
                                                    inspectionType:
                                                        'first_piece',
                                                  );
                                              if (started && context.mounted) {
                                                Navigator.push(
                                                  context,
                                                  MaterialPageRoute(
                                                    builder: (_) =>
                                                        const InspectionVoiceScreen(),
                                                  ),
                                                );
                                              }
                                            }
                                          },
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _notificationFilterChip({
    required String label,
    required String value,
    required String selected,
    required ValueChanged<String> onSelected,
  }) {
    return ChoiceChip(
      label: Text(label),
      selected: selected == value,
      onSelected: (_) => onSelected(value),
      selectedColor: const Color(0xFF0284C7),
      backgroundColor: const Color(0xFFF1F5F9),
      labelStyle: TextStyle(
        color: selected == value ? Colors.white : const Color(0xFF475569),
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
      side: BorderSide.none,
      showCheckmark: false,
    );
  }

  Future<void> _openNotification(
    BuildContext modalContext,
    NotificationItem item,
    NotificationProvider notificationProvider,
  ) async {
    await notificationProvider.markAsRead(item);
    if (!mounted) return;

    if (item.category != NotificationCategory.message &&
        item.category != NotificationCategory.dcr &&
        item.category != NotificationCategory.document) {
      return;
    }

    Navigator.of(modalContext).pop();
    if (item.category == NotificationCategory.message &&
        item.conversationId != null) {
      Navigator.of(
        context,
      ).pushNamed('/messages', arguments: item.conversationId);
    } else {
      Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const DocumentControlScreen()));
    }
  }

  NotificationItem _toNotificationItem(Map<String, dynamic> notification) {
    final type = notification['type']?.toString();
    final rawRejection = notification['raw_rej'];
    return NotificationItem(
      id: notification['id'].toString(),
      category: NotificationCategory.supervisor,
      title: notification['title']?.toString() ?? 'Global notification',
      message: notification['message']?.toString() ?? '',
      createdAt: DateTime.now(),
      isRead: notification['is_read'] == true,
      action: type,
      metadata: {
        if (notification['subtitle'] != null)
          'subtitle': notification['subtitle'],
        if (notification['details'] != null) 'details': notification['details'],
        if (rawRejection != null) 'raw_rej': rawRejection,
        if (notification['next_trial'] != null)
          'next_trial': notification['next_trial'],
      },
    );
  }

  String _notificationCategoryLabel(NotificationItem item) {
    final subtitle = item.metadata['subtitle']?.toString();
    if (subtitle != null && subtitle.isNotEmpty) return subtitle;
    switch (item.category) {
      case NotificationCategory.message:
        return 'New message';
      case NotificationCategory.dcr:
        return item.dcrNumber ?? 'Document change request';
      case NotificationCategory.document:
        return 'Document control';
      case NotificationCategory.supervisor:
        return 'Global notification';
      case NotificationCategory.system:
        return 'System notification';
    }
  }

  String _notificationTime(NotificationItem item) {
    final createdAt = item.createdAt;
    if (createdAt == null) return '';
    final difference = DateTime.now().difference(createdAt);
    if (difference.inMinutes < 1) return 'Just now';
    if (difference.inHours < 1) return '${difference.inMinutes}m ago';
    if (difference.inDays < 1) return '${difference.inHours}h ago';
    return '${difference.inDays}d ago';
  }

  String _getInitials(Map<String, dynamic> user) {
    final name =
        (user['full_name'] ?? user['first_name'] ?? user['username'] ?? 'U')
            .toString()
            .trim();
    if (name.isEmpty) return 'U';
    final parts = name.split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name.substring(0, name.length >= 2 ? 2 : 1).toUpperCase();
  }

  String _getShortName(Map<String, dynamic> user) {
    final name =
        (user['full_name'] ?? user['first_name'] ?? user['username'] ?? 'User')
            .toString()
            .trim();
    if (name.isEmpty) return 'User';
    final parts = name.split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.length >= 2) {
      return '${parts[0]} ${parts[1][0]}.';
    }
    return name;
  }

  Color _getRoleColor(String? role) {
    final r = (role ?? '').toLowerCase();
    if (r == 'operator') return const Color(0xFF059669);
    if (r == 'inspector' || r == 'quality_engineer')
      return const Color(0xFF4F46E5);
    if (r == 'supervisor' || r == 'admin') return const Color(0xFFD97706);
    return const Color(0xFF0284C7);
  }

  Color _getRoleBg(String? role) {
    final r = (role ?? '').toLowerCase();
    if (r == 'operator') return const Color(0xFFA7F3D0);
    if (r == 'inspector' || r == 'quality_engineer')
      return const Color(0xFFE0E7FF);
    if (r == 'supervisor' || r == 'admin') return const Color(0xFFFED7AA);
    return const Color(0xFFBAE6FD);
  }

  String _getRoleTitle(String? role) {
    final r = (role ?? '').toLowerCase();
    if (r == 'operator') return 'Machine Operator';
    if (r == 'inspector') return 'Quality Inspector';
    if (r == 'quality_engineer') return 'Quality Engineer';
    if (r == 'supervisor') return 'Quality Supervisor';
    if (r == 'admin') return 'System Administrator';
    return 'Station Operator';
  }

  void _showTeamMemberModal(BuildContext context, Map<String, dynamic> member) {
    final fullName =
        member['full_name'] ??
        member['first_name'] ??
        member['username'] ??
        'Station Operator';
    final username = member['username'] ?? 'operator';
    final empId = member['employee_id'] ?? 'EMP-OP-01';
    final roleStr = member['role'] ?? 'operator';
    final initials = _getInitials(member);
    final roleColor = _getRoleColor(roleStr);
    final roleTitle = _getRoleTitle(roleStr);

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFF334155),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 20),
              CircleAvatar(
                radius: 36,
                backgroundColor: roleColor.withValues(alpha: 0.2),
                child: Text(
                  initials,
                  style: TextStyle(
                    color: roleColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 24,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                fullName,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '@$username  •  ID: $empId',
                style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: roleColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: roleColor.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Text(
                      roleTitle,
                      style: TextStyle(
                        color: roleColor,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF10B981).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: const Color(0xFF10B981).withValues(alpha: 0.4),
                      ),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.wifi_tethering_rounded,
                          color: Color(0xFF10B981),
                          size: 12,
                        ),
                        SizedBox(width: 4),
                        Text(
                          'CONNECTED',
                          style: TextStyle(
                            color: Color(0xFF10B981),
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: roleColor,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 44),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: const Icon(Icons.check_circle_rounded, size: 18),
                label: const Text(
                  'STATION OPERATOR VERIFIED',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                onPressed: () => Navigator.pop(ctx),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showAddOperatorModal(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Connect Operator to Station',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.close_rounded,
                      color: Color(0xFF94A3B8),
                    ),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'All operators registered in system are automatically connected to active floor station.',
                style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4F46E5),
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 46),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: const Icon(Icons.swap_horiz_rounded),
                label: const Text(
                  'SWITCH ACTIVE STATION',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                onPressed: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const MachineSelectScreen(),
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = Provider.of<AuthProvider>(context);
    final provider = Provider.of<InspectionProvider>(context);
    final company = Provider.of<CompanyProvider>(context);

    final name = auth.fullName ?? auth.username ?? 'Operator';
    final firstName = name.split(' ').first;
    final roleTitle = auth.isInspector
        ? 'Quality Inspector'
        : (auth.isQualityEngineer
              ? 'Quality Engineer'
              : (auth.isOperator
                    ? 'Machine Operator'
                    : 'Mobile Access Restricted'));

    final selectedPart = provider.selectedPart;
    final partNumber = selectedPart?['part_number'] ?? 'FBT00222';

    final hasActiveSession =
        provider.sessionId != null || provider.recordedResults.isNotEmpty;
    final recordedCount = provider.recordedResults.length;
    final totalParams = provider.parameters.length;
    final sessionPart =
        provider.selectedPart?['part_number'] ??
        provider.selectedPart?['part_name'] ??
        partNumber;

    final notificationState = Provider.of<NotificationProvider>(context);
    final unreadNotifCount = notificationState.unreadCount;
    final unreadMessagesCount = notificationState.items
        .where(
          (item) =>
              item.category == NotificationCategory.message && !item.isRead,
        )
        .fold<int>(0, (total, item) {
          final count = item.metadata['unread_count'];
          return total + (count is int ? count : 1);
        });

    Widget homeTabContent = RefreshIndicator(
      color: const Color(0xFF4F46E5),
      onRefresh: _loadDashboardData,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. TOP GREETING HEADER & NOTIFICATION BELL
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Hi $firstName,',
                        style: const TextStyle(
                          fontSize: 15,
                          color: Color(0xFF64748B),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        roleTitle,
                        style: const TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF0F172A),
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 6),
                          InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: (auth.isOperator || auth.isInspector)
                                ? () => _selectWorkingShift(context, auth, company)
                                : null,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 3),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 8,
                                    height: 8,
                                    decoration: const BoxDecoration(
                                      color: Color(0xFF10B981),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Current Shift: Shift ${company.availableShifts.contains(auth.assignedShift) ? auth.assignedShift : company.availableShifts.first}',
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF64748B),
                                    ),
                                  ),
                                  if (auth.isOperator || auth.isInspector)
                                    const Icon(Icons.arrow_drop_down, size: 18, color: Color(0xFF64748B)),
                                ],
                              ),
                            ),
                          ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Align(
                    alignment: Alignment.topRight,
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 0,
                      runSpacing: 0,
                      children: [
                        IconButton(
                          icon: const Icon(
                            Icons.bug_report_outlined,
                            color: Color(0xFFEF4444),
                            size: 26,
                          ),
                          tooltip: 'Report Issue',
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const BugReportScreen(),
                              ),
                            );
                          },
                        ),
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            IconButton(
                              icon: const Icon(
                                Icons.notifications_none_rounded,
                                color: Color(0xFF0F172A),
                                size: 26,
                              ),
                              tooltip: 'Notifications',
                              onPressed: () => _showNotificationsModal(context),
                            ),
                            if (unreadNotifCount > 0)
                              Positioned(
                                top: 0,
                                right: 0,
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: const BoxDecoration(
                                    color: Color(0xFFEF4444),
                                    shape: BoxShape.circle,
                                  ),
                                  constraints: const BoxConstraints(
                                    minWidth: 16,
                                    minHeight: 16,
                                  ),
                                  child: Text(
                                    '$unreadNotifCount',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 24),

            // 2. FEATURE MODULES TITLE
            const Text(
              'Here are some things you can do',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Color(0xFF64748B),
              ),
            ),

            const SizedBox(height: 16),

            // 3. CORE MODULE CARDS GRID
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 2,
              crossAxisSpacing: 14,
              mainAxisSpacing: 14,
              childAspectRatio: MediaQuery.sizeOf(context).width < 380
                  ? 0.82
                  : 1.05,
              children: auth.isOperator
                  ? [
                      // Operator Card 1: Machine (with 1 to 8 hr entry)
                      _buildSoftPastelCard(
                        title: 'Machine',
                        description:
                            'Select machine & 1 to 8 hr in-process inspection entry',
                        icon: Icons.precision_manufacturing_rounded,
                        bgColor: const Color(0xFFF0F3FF),
                        borderColor: const Color(0xFFE0E7FF),
                        iconColor: const Color(0xFF4F46E5),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const MachineSelectScreen(),
                            ),
                          );
                        },
                      ),

                      // Operator Card 2: Resume Entry (resumes live session directly)
                      _buildSoftPastelCard(
                        title: 'Resume Entry',
                        description: hasActiveSession
                            ? 'Resume $sessionPart ($recordedCount of ${totalParams > 0 ? totalParams : "—"} params)'
                            : 'Resume active inspection data entry for operation',
                        icon: hasActiveSession
                            ? Icons.play_circle_fill_rounded
                            : Icons.play_circle_outline_rounded,
                        bgColor: hasActiveSession
                            ? const Color(0xFFECFDF5)
                            : const Color(0xFFF8FAFC),
                        borderColor: hasActiveSession
                            ? const Color(0xFFA7F3D0)
                            : const Color(0xFFE2E8F0),
                        iconColor: hasActiveSession
                            ? const Color(0xFF059669)
                            : const Color(0xFF64748B),
                        onTap: () => _resumeActiveSessionDirectly(context),
                      ),

                      // Operator Card 3: Daily Production Report (Form F19)
                      _buildSoftPastelCard(
                        title: 'Daily Production Report',
                        description:
                            'End of shift output, target & breakdown log (Form F19)',
                        icon: Icons.bar_chart_rounded,
                        bgColor: const Color(0xFFFFF7ED),
                        borderColor: const Color(0xFFFFEDD5),
                        iconColor: const Color(0xFFEA580C),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  const DailyProductionReportScreen(),
                            ),
                          );
                        },
                      ),

                      // Operator Card 4: JH-Inspection (Autonomous Maintenance Checklist)
                      _buildSoftPastelCard(
                        title: 'JH-Inspection',
                        description:
                            'Autonomous Maintenance & machine shift checklist (Form QF/MF-08)',
                        icon: Icons.fact_check_rounded,
                        bgColor: const Color(0xFFF0FDF4),
                        borderColor: const Color(0xFFBBF7D0),
                        iconColor: const Color(0xFF16A34A),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const JhInspectionScreen(),
                            ),
                          );
                        },
                      ),

                      // Operator Card 5: Document Control
                      _buildSoftPastelCard(
                        title: 'Document Control',
                        description:
                            'View & download approved SOPs, work instructions and quality documents',
                        icon: Icons.folder_open_rounded,
                        bgColor: const Color(0xFFF5F3FF),
                        borderColor: const Color(0xFFEDE9FE),
                        iconColor: const Color(0xFF7C3AED),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const DocumentControlScreen(),
                            ),
                          );
                        },
                      ),

                      // Operator Card 6: Task Manager
                      _buildSoftPastelCard(
                        title: 'Task Manager',
                        description:
                            'Review assigned tasks, accept work and mark tasks complete',
                        icon: Icons.task_alt_rounded,
                        bgColor: const Color(0xFFEFF6FF),
                        borderColor: const Color(0xFFBFDBFE),
                        iconColor: const Color(0xFF2563EB),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const TasksScreen(),
                            ),
                          );
                        },
                      ),

                      // Operator Card 7: 100% critical-parameter run chart
                      _buildSoftPastelCard(
                        title: 'Run Chart',
                        description:
                            'Record every job/piece and monitor critical parameters live',
                        icon: Icons.show_chart_rounded,
                        bgColor: const Color(0xFFECFEFF),
                        borderColor: const Color(0xFFA5F3FC),
                        iconColor: const Color(0xFF0891B2),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const RunChartScreen(),
                            ),
                          );
                        },
                      ),
                    ]
                  : [
                      // Inspector / Supervisor Card 1: Machine
                      _buildSoftPastelCard(
                        title: 'Machine',
                        description: 'Choose or switch active floor machine',
                        icon: Icons.precision_manufacturing_rounded,
                        bgColor: const Color(0xFFF0F3FF),
                        borderColor: const Color(0xFFE0E7FF),
                        iconColor: const Color(0xFF4F46E5),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const MachineSelectScreen(),
                            ),
                          );
                        },
                      ),

                      // Inspector / Supervisor Card 2: Live Daily Report (Form F02 Live Sheet)
                      _buildSoftPastelCard(
                        title: 'Live Daily Report',
                        description:
                            'View real-time Form F02 report filling (1PC & In-Process)',
                        icon: Icons.article_rounded,
                        bgColor: const Color(0xFFEFF6FF),
                        borderColor: const Color(0xFFBFDBFE),
                        iconColor: const Color(0xFF2563EB),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const ReportSheetScreen(),
                            ),
                          );
                        },
                      ),

                      // Inspector / Supervisor Card 4: Resume Entry
                      _buildSoftPastelCard(
                        title: 'Resume Entry',
                        description: hasActiveSession
                            ? 'Resume $sessionPart ($recordedCount of ${totalParams > 0 ? totalParams : "—"} params)'
                            : 'Resume active inspection data entry for operation',
                        icon: hasActiveSession
                            ? Icons.play_circle_fill_rounded
                            : Icons.play_circle_outline_rounded,
                        bgColor: hasActiveSession
                            ? const Color(0xFFECFDF5)
                            : const Color(0xFFF8FAFC),
                        borderColor: hasActiveSession
                            ? const Color(0xFFA7F3D0)
                            : const Color(0xFFE2E8F0),
                        iconColor: hasActiveSession
                            ? const Color(0xFF059669)
                            : const Color(0xFF64748B),
                        onTap: () => _resumeActiveSessionDirectly(context),
                      ),

                      // Inspector / Supervisor Card 5: Document Control
                      _buildSoftPastelCard(
                        title: 'Document Control',
                        description:
                            'View & download approved SOPs, work instructions and quality documents',
                        icon: Icons.folder_open_rounded,
                        bgColor: const Color(0xFFF5F3FF),
                        borderColor: const Color(0xFFEDE9FE),
                        iconColor: const Color(0xFF7C3AED),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const DocumentControlScreen(),
                            ),
                          );
                        },
                      ),

                      // Inspector / Supervisor Card 6: Task Manager
                      _buildSoftPastelCard(
                        title: 'Task Manager',
                        description:
                            'Review assigned tasks, accept work and mark tasks complete',
                        icon: Icons.task_alt_rounded,
                        bgColor: const Color(0xFFEFF6FF),
                        borderColor: const Color(0xFFBFDBFE),
                        iconColor: const Color(0xFF2563EB),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const TasksScreen(),
                            ),
                          );
                        },
                      ),
                    ],
            ),

            const SizedBox(height: 28),

            // 4. "YOUR TEAM & OPERATORS" ROW
            if (!auth.isOperator) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Your station team',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF64748B),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF10B981).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${_teamMembers.length} Operators Connected',
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF10B981),
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 14),

              SizedBox(
                height: 76,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    _buildAvatarItem(
                      isAdd: true,
                      label: 'Add',
                      onTap: () => _showAddOperatorModal(context),
                    ),

                    const SizedBox(width: 14),

                    ..._teamMembers.map((member) {
                      final initials = _getInitials(member);
                      final name = _getShortName(member);
                      final roleColor = _getRoleColor(member['role']);
                      final imageBg = _getRoleBg(member['role']);

                      return Padding(
                        padding: const EdgeInsets.only(right: 14.0),
                        child: GestureDetector(
                          onTap: () => _showTeamMemberModal(context, member),
                          child: _buildAvatarItem(
                            initials: initials,
                            name: name,
                            roleColor: roleColor,
                            imageBg: imageBg,
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),

              const SizedBox(height: 16),
            ],
          ],
        ),
      ),
    );

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: SafeArea(
        child: IndexedStack(
          index: _currentIndex,
          children: [
            homeTabContent,
            _currentIndex == 1
                ? const MessagesScreen()
                : const SizedBox.shrink(),
            const AccountScreen(),
          ],
        ),
      ),

      // FLOATING 2-TAB BOTTOM NAVIGATION BAR (Home & About)
      bottomNavigationBar: Container(
        margin: const EdgeInsets.only(left: 16, right: 16, bottom: 16),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(30),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 20,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            // Tab 1: Home
            Expanded(
              child: InkWell(
                onTap: () => setState(() => _currentIndex = 0),
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.home_rounded,
                        color: _currentIndex == 0
                            ? const Color(0xFF4F46E5)
                            : const Color(0xFF94A3B8),
                        size: 22,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Home',
                        style: TextStyle(
                          color: _currentIndex == 0
                              ? const Color(0xFF4F46E5)
                              : const Color(0xFF94A3B8),
                          fontWeight: _currentIndex == 0
                              ? FontWeight.bold
                              : FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Tab 2: Messages
            Expanded(
              child: InkWell(
                onTap: () => setState(() => _currentIndex = 1),
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Icon(
                            Icons.chat_bubble_outline_rounded,
                            color: _currentIndex == 1
                                ? const Color(0xFF4F46E5)
                                : const Color(0xFF94A3B8),
                            size: 22,
                          ),
                          if (unreadMessagesCount > 0)
                            Positioned(
                              top: -7,
                              right: -9,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 2,
                                ),
                                constraints: const BoxConstraints(
                                  minWidth: 16,
                                  minHeight: 16,
                                ),
                                decoration: const BoxDecoration(
                                  color: Color(0xFFEF4444),
                                  shape: BoxShape.circle,
                                ),
                                child: Text(
                                  unreadMessagesCount > 99
                                      ? '99+'
                                      : '$unreadMessagesCount',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Messages',
                        style: TextStyle(
                          color: _currentIndex == 1
                              ? const Color(0xFF4F46E5)
                              : const Color(0xFF94A3B8),
                          fontWeight: _currentIndex == 1
                              ? FontWeight.bold
                              : FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Tab 3: About (Profile & Station details)
            Expanded(
              child: InkWell(
                onTap: () => setState(() => _currentIndex = 2),
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.person_rounded,
                        color: _currentIndex == 2
                            ? const Color(0xFF4F46E5)
                            : const Color(0xFF94A3B8),
                        size: 22,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'About',
                        style: TextStyle(
                          color: _currentIndex == 2
                              ? const Color(0xFF4F46E5)
                              : const Color(0xFF94A3B8),
                          fontWeight: _currentIndex == 2
                              ? FontWeight.bold
                              : FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSoftPastelCard({
    required String title,
    required String description,
    required IconData icon,
    required Color bgColor,
    required Color borderColor,
    required Color iconColor,
    required VoidCallback onTap,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: borderColor, width: 1.2),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: iconColor.withValues(alpha: 0.15),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Icon(icon, color: iconColor, size: 22),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAvatarItem({
    bool isAdd = false,
    String? initials,
    String label = '',
    String name = '',
    Color roleColor = Colors.blueAccent,
    Color imageBg = Colors.white,
    VoidCallback? onTap,
  }) {
    if (isAdd) {
      return GestureDetector(
        onTap: onTap,
        child: Column(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: const Color(0xFFF1F5F9),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: const Icon(
                Icons.add_rounded,
                color: Color(0xFF64748B),
                size: 24,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                color: Color(0xFF64748B),
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        Stack(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: imageBg,
                shape: BoxShape.circle,
                border: Border.all(color: roleColor.withValues(alpha: 0.3)),
              ),
              child: Center(
                child: Text(
                  initials ?? 'U',
                  style: TextStyle(
                    color: roleColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
              ),
            ),
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: roleColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          name,
          style: const TextStyle(
            fontSize: 11,
            color: Color(0xFF0F172A),
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Future<void> _resumeActiveSessionDirectly(BuildContext context) async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final provider = Provider.of<InspectionProvider>(context, listen: false);
    final userId = auth.userId ?? auth.username ?? 'operator';

    // 1. If session is active in provider memory, open OperationSelectScreen
    if (provider.sessionId != null || provider.recordedResults.isNotEmpty) {
      if (context.mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const OperationSelectScreen()),
        );
      }
      return;
    }

    // 2. Check local storage for saved in-flight inspection state
    var hasSaved = await PersistenceService.hasSavedState(userId);
    var targetUserKey = userId;
    if (!hasSaved && auth.username != null) {
      hasSaved = await PersistenceService.hasSavedState(auth.username!);
      if (hasSaved) targetUserKey = auth.username!;
    }

    if (hasSaved) {
      final savedState = await PersistenceService.loadState(targetUserKey);
      if (savedState != null) {
        provider.restoreFromLocalState(savedState, targetUserKey);
        if (context.mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const OperationSelectScreen()),
          );
        }
        return;
      }
    }

    // 3. If no session exists, navigate to operation selection to start new
    if (context.mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const OperationSelectScreen()),
      );
    }
  }
}
