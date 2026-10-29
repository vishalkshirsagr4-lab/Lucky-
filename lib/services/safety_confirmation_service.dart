import 'dart:async';
import 'package:flutter/foundation.dart';
import 'ai_service.dart';

/// Categories of actions that require explicit user confirmation.
enum HighImpactCategory {
  sendMessage,
  sendEmail,
  makeCall,
  financial,
  deleteData,
  securityChange,
  externalPublish,
}

/// A prepared high-impact action awaiting explicit user confirmation.
class PendingActionConfirmation {
  PendingActionConfirmation({
    required this.id,
    required this.category,
    required this.title,
    required this.description,
    required this.details,
    required this.action,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  final HighImpactCategory category;
  final String title;
  final String description;
  final Map<String, String> details;
  final AgentAction action;
  final DateTime createdAt;
}

/// Service that enforces that high-impact actions must have explicit user confirmation.
class SafetyConfirmationService extends ChangeNotifier {
  PendingActionConfirmation? _pendingConfirmation;
  Completer<bool>? _confirmationCompleter;

  PendingActionConfirmation? get pendingConfirmation => _pendingConfirmation;
  bool get hasPendingConfirmation => _pendingConfirmation != null;

  /// Determines whether an [AgentAction] requires user confirmation before execution.
  bool requiresConfirmation(AgentAction action, {String? focusedFieldHint}) {
    final type = action.type.toLowerCase();
    final params = action.params;

    // Direct destructive or critical action types
    if (type == 'send_message' || type == 'send_email' || type == 'make_call') {
      return true;
    }
    if (type == 'delete_data' || type == 'delete_file' || type == 'clear_all') {
      return true;
    }
    if (type == 'transfer_money' || type == 'purchase' || type == 'pay') {
      return true;
    }

    // Check typing into sensitive or destructive fields
    if (type == 'type') {
      final text = (params['text'] as String? ?? '').toLowerCase();
      final fieldHint = (focusedFieldHint ?? '').toLowerCase();
      const sensitiveKeywords = [
        'password',
        'pin',
        'cvv',
        'card number',
        'transfer',
        'otp',
        'pay',
        'delete',
      ];
      if (sensitiveKeywords.any((kw) => fieldHint.contains(kw) || text.contains(kw))) {
        return true;
      }
    }

    // Check opening payment/financial apps with pending transactions
    if (type == 'open_app') {
      final package = (params['package'] as String? ?? '').toLowerCase();
      const financialPackages = [
        'com.google.android.apps.n2p.m2p.ui', // Google Pay
        'com.phonepe.app',
        'net.one97.paytm',
        'com.bhim',
      ];
      if (financialPackages.any((pkg) => package.contains(pkg))) {
        return true;
      }
    }

    // Explicit flag in parameters from the model
    if (params['requires_confirmation'] == true) {
      return true;
    }

    return false;
  }

  /// Categorize an action into a [HighImpactCategory] and extract details for display.
  PendingActionConfirmation createConfirmation(AgentAction action, {String? focusedFieldHint}) {
    final type = action.type.toLowerCase();
    final params = action.params;
    final id = 'confirm_${DateTime.now().millisecondsSinceEpoch}';

    HighImpactCategory category;
    String title;
    String description;
    final details = <String, String>{};

    if (type == 'send_message' || (type == 'type' && (params['package']?.toString().contains('messaging') ?? false))) {
      category = HighImpactCategory.sendMessage;
      title = 'Send Message?';
      description = 'Lucy is about to send a message.';
      if (params.containsKey('recipient')) details['Recipient'] = params['recipient'].toString();
      if (params.containsKey('text')) details['Message'] = params['text'].toString();
    } else if (type == 'send_email') {
      category = HighImpactCategory.sendEmail;
      title = 'Send Email?';
      description = 'Lucy is about to send an email.';
      if (params.containsKey('to')) details['To'] = params['to'].toString();
      if (params.containsKey('subject')) details['Subject'] = params['subject'].toString();
    } else if (type == 'make_call') {
      category = HighImpactCategory.makeCall;
      title = 'Make Phone Call?';
      description = 'Lucy is about to place a phone call.';
      if (params.containsKey('phone')) details['Phone'] = params['phone'].toString();
    } else if (type == 'delete_data' || type == 'clear_all') {
      category = HighImpactCategory.deleteData;
      title = 'Delete Data?';
      description = 'This operation may permanently delete data.';
      if (params.containsKey('target')) details['Target'] = params['target'].toString();
    } else if (type == 'open_app' && (params['package']?.toString().contains('pay') ?? false)) {
      category = HighImpactCategory.financial;
      title = 'Open Payment App?';
      description = 'Lucy is about to open a financial application.';
      details['App'] = params['package'].toString();
    } else {
      category = HighImpactCategory.securityChange;
      title = 'Confirm Action?';
      description = 'Lucy needs your permission to proceed with this action.';
      details['Action'] = type;
      if (params.isNotEmpty) details['Parameters'] = params.toString();
    }

    return PendingActionConfirmation(
      id: id,
      category: category,
      title: title,
      description: description,
      details: details,
      action: action,
    );
  }

  /// Request confirmation from the user. Returns a Future that completes with true if approved, false otherwise.
  Future<bool> requestConfirmation(PendingActionConfirmation confirmation) {
    if (_confirmationCompleter != null && !_confirmationCompleter!.isCompleted) {
      _confirmationCompleter!.complete(false);
    }
    _pendingConfirmation = confirmation;
    final completer = Completer<bool>();
    _confirmationCompleter = completer;
    notifyListeners();
    return completer.future;
  }

  /// Submit the user's decision (called from the UI).
  void resolveConfirmation(bool approved) {
    if (_confirmationCompleter != null && !_confirmationCompleter!.isCompleted) {
      _confirmationCompleter!.complete(approved);
    }
    _pendingConfirmation = null;
    _confirmationCompleter = null;
    notifyListeners();
  }

  void cancelPending() {
    resolveConfirmation(false);
  }
}
