import 'package:flutter_riverpod/flutter_riverpod.dart';

/// How prominently a global [AppNotice] should be presented. The root
/// [ScaffoldMessenger] uses this to tint the resulting `SnackBar`.
enum AppNoticeSeverity { info, success, warning, error }

/// A single non-modal notice surfaced through the root `ScaffoldMessenger`.
///
/// Per the app shell's design, this is reserved for things that aren't
/// local to a screen: a successful reconnection, an activity-write
/// warning, or an unexpected-but-safe failure (one that leaves the app in
/// a working state, just not the state the user asked for). Errors that
/// belong to a specific form — a rejected connection test, a library
/// fetch failure — stay local to that screen instead.
class AppNotice {
  AppNotice({
    required this.message,
    this.severity = AppNoticeSeverity.info,
    int? id,
  }) : id = id ?? _nextId++;

  static int _nextId = 0;

  final String message;
  final AppNoticeSeverity severity;

  /// Distinguishes one shown notice from the next so a listener can tell a
  /// repeated message apart from the notice it already displayed.
  final int id;
}

class NoticeController extends Notifier<AppNotice?> {
  @override
  AppNotice? build() => null;

  void show(AppNotice notice) => state = notice;
}

final globalNoticeProvider = NotifierProvider<NoticeController, AppNotice?>(
  NoticeController.new,
);
