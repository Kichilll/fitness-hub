/// Fitness Hub – Stage 2 workflows: MoMo, cash, expenses, corrections.
/// Pure Dart. Every action that touches money returns an [AuditEntry].
library workflows;

import 'money_logic.dart';

enum Role { organizer, treasurer }

void _requirePositiveAmount(int amount, String name) {
  if (amount <= 0) {
    throw ArgumentError.value(amount, name, 'Must be greater than zero');
  }
}

class AuditEntry {
  final String action;
  final String targetId;
  final String byUid;
  final String reason;
  final DateTime at;
  const AuditEntry({
    required this.action,
    required this.targetId,
    required this.byUid,
    required this.at,
    this.reason = '',
  });
}

// ------------------------------------------------------------------ MoMo

enum MomoStatus { pending, needInfo, verified, rejected }

/// "ab 123 " and "AB123" are the same reference.
String normalizeRef(String raw) =>
    raw.replaceAll(RegExp(r'\s+'), '').toUpperCase();

class MomoSubmission {
  final String id; // also the payment id
  final String memberId;
  final int amount;
  final String reference; // normalized
  final MomoStatus status;
  const MomoSubmission({
    required this.id,
    required this.memberId,
    required this.amount,
    required this.reference,
    required this.status,
  });

  MomoSubmission _with(MomoStatus s) => MomoSubmission(
    id: id,
    memberId: memberId,
    amount: amount,
    reference: reference,
    status: s,
  );

  /// Only `verified` becomes money. Pending / needInfo stay pending.
  Payment toPayment() => Payment(
    id: id,
    memberId: memberId,
    amount: amount,
    method: PaymentMethod.momo,
    status: switch (status) {
      MomoStatus.verified => PaymentStatus.verified,
      MomoStatus.rejected => PaymentStatus.rejected,
      _ => PaymentStatus.pending,
    },
  );
}

/// A reference stays reserved even if the claim is later rejected, so the
/// same reference can never be submitted twice.
MomoSubmission submitMomo({
  required String id,
  required String memberId,
  required int amount,
  required String reference,
  required Set<String> usedReferences, // normalized, from momo_references
}) {
  _requirePositiveAmount(amount, 'amount');
  final ref = normalizeRef(reference);
  if (ref.isEmpty) throw MoneyRuleError('MoMo reference is required');
  if (usedReferences.contains(ref)) {
    throw MoneyRuleError('This MoMo reference has already been used');
  }
  return MomoSubmission(
    id: id,
    memberId: memberId,
    amount: amount,
    reference: ref,
    status: MomoStatus.pending,
  );
}

const _momoFlow = <MomoStatus, Set<MomoStatus>>{
  MomoStatus.pending: {
    MomoStatus.verified,
    MomoStatus.rejected,
    MomoStatus.needInfo,
  },
  MomoStatus.needInfo: {
    MomoStatus.pending,
    MomoStatus.verified,
    MomoStatus.rejected,
  },
  MomoStatus.verified: {},
  MomoStatus.rejected: {},
};

class MomoDecision {
  final MomoSubmission submission;
  final AuditEntry audit;
  const MomoDecision(this.submission, this.audit);
}

/// Only the treasurer decides. Rejecting or asking for info needs a reason.
MomoDecision decideMomo({
  required MomoSubmission sub,
  required MomoStatus next,
  required Role role,
  required String byUid,
  required DateTime at,
  String reason = '',
}) {
  if (role != Role.treasurer) {
    throw MoneyRuleError(
      'Only the treasurer can verify or reject MoMo payments',
    );
  }
  if (!_momoFlow[sub.status]!.contains(next)) {
    throw MoneyRuleError(
      'Cannot move MoMo from ${sub.status.name} to ${next.name}',
    );
  }
  if ((next == MomoStatus.rejected || next == MomoStatus.needInfo) &&
      reason.trim().isEmpty) {
    throw MoneyRuleError('A reason is required');
  }
  return MomoDecision(
    sub._with(next),
    AuditEntry(
      action: 'momo_${next.name}',
      targetId: sub.id,
      byUid: byUid,
      at: at,
      reason: reason.trim(),
    ),
  );
}

// ------------------------------------------------------------------ Cash

String receiptNumber(int n) => 'R-${n.toString().padLeft(6, '0')}';

class CashReceipt {
  final String receiptNo;
  final Payment payment;
  final AuditEntry audit;
  const CashReceipt(this.receiptNo, this.payment, this.audit);
}

/// [counterValue] is the next number from the `counters` document. In
/// Firestore, read and increment it inside one transaction so two receipts
/// never get the same number.
CashReceipt recordCash({
  required String id,
  required String memberId,
  required int amount,
  required int counterValue,
  required String byUid,
  required DateTime at,
}) {
  _requirePositiveAmount(amount, 'amount');
  final no = receiptNumber(counterValue);
  return CashReceipt(
    no,
    Payment(
      id: id,
      memberId: memberId,
      amount: amount,
      method: PaymentMethod.cash,
      status: PaymentStatus.verified,
    ), // cash is verified on entry
    AuditEntry(
      action: 'cash_recorded',
      targetId: id,
      byUid: byUid,
      at: at,
      reason: no,
    ),
  );
}

// -------------------------------------------------------------- Expenses

Expense newExpense({required String id, required int amount}) {
  if (amount <= 0) throw MoneyRuleError('Amount must be greater than zero');
  return Expense(id: id, amount: amount, status: ExpenseStatus.draft);
}

const _expenseFlow = <ExpenseStatus, Set<ExpenseStatus>>{
  ExpenseStatus.draft: {ExpenseStatus.submitted},
  ExpenseStatus.submitted: {ExpenseStatus.approved, ExpenseStatus.rejected},
  ExpenseStatus.approved: {ExpenseStatus.paid, ExpenseStatus.rejected},
  ExpenseStatus.paid: {},
  ExpenseStatus.rejected: {},
};

class ExpenseDecision {
  final Expense expense;
  final AuditEntry audit;
  const ExpenseDecision(this.expense, this.audit);
}

ExpenseDecision advanceExpense(
  Expense e,
  ExpenseStatus next, {
  required String byUid,
  required DateTime at,
  String reason = '',
}) {
  if (!_expenseFlow[e.status]!.contains(next)) {
    throw MoneyRuleError(
      'Cannot move expense from ${e.status.name} to ${next.name}',
    );
  }
  if (next == ExpenseStatus.rejected && reason.trim().isEmpty) {
    throw MoneyRuleError('A reason is required to reject an expense');
  }
  return ExpenseDecision(
    Expense(id: e.id, amount: e.amount, status: next, refunded: e.refunded),
    AuditEntry(
      action: 'expense_${next.name}',
      targetId: e.id,
      byUid: byUid,
      at: at,
      reason: reason.trim(),
    ),
  );
}

// ----------------------------------------------------------- Corrections

enum CorrectionType { voidEntry, reversal, refund }

class Correction {
  final String id;
  final CorrectionType type;
  final String paymentId;
  final int amount; // refund only
  final String reason;
  final String byUid;
  final DateTime at;
  const Correction({
    required this.id,
    required this.type,
    required this.paymentId,
    required this.reason,
    required this.byUid,
    required this.at,
    this.amount = 0,
  });
}

class CorrectionResult {
  final Correction correction;
  final AuditEntry audit;
  const CorrectionResult(this.correction, this.audit);
}

CorrectionResult _result(Correction c) => CorrectionResult(
  c,
  AuditEntry(
    action: 'correction_${c.type.name}',
    targetId: c.paymentId,
    byUid: c.byUid,
    at: c.at,
    reason: c.reason,
  ),
);

void _needReason(String reason) {
  if (reason.trim().isEmpty) throw MoneyRuleError('A reason is required');
}

/// Void: the entry was recorded by mistake, treat it as never counted.
CorrectionResult voidPayment({
  required String id,
  required Payment payment,
  required String reason,
  required String byUid,
  required DateTime at,
  required Set<String> alreadyReversed,
  int alreadyRefunded = 0,
}) => _undo(
  CorrectionType.voidEntry,
  id,
  payment,
  reason,
  byUid,
  at,
  alreadyReversed,
  alreadyRefunded,
);

/// Reversal: a verified payment turned out to be invalid (e.g. bounced).
CorrectionResult reversePayment({
  required String id,
  required Payment payment,
  required String reason,
  required String byUid,
  required DateTime at,
  required Set<String> alreadyReversed,
  int alreadyRefunded = 0,
}) {
  _requirePositiveAmount(payment.amount, 'payment.amount');
  if (payment.status != PaymentStatus.verified) {
    throw MoneyRuleError(
      'Only a verified payment can be reversed; void it instead',
    );
  }
  return _undo(
    CorrectionType.reversal,
    id,
    payment,
    reason,
    byUid,
    at,
    alreadyReversed,
    alreadyRefunded,
  );
}

CorrectionResult _undo(
  CorrectionType t,
  String id,
  Payment p,
  String reason,
  String byUid,
  DateTime at,
  Set<String> reversed,
  int refunded,
) {
  _requirePositiveAmount(p.amount, 'payment.amount');
  if (refunded < 0) {
    throw ArgumentError.value(refunded, 'refunded', 'Must not be negative');
  }
  _needReason(reason);
  if (reversed.contains(p.id)) {
    throw MoneyRuleError('This payment is already voided or reversed');
  }
  if (refunded > 0) {
    throw MoneyRuleError('Payment has refunds; resolve them before reversing');
  }
  return _result(
    Correction(
      id: id,
      type: t,
      paymentId: p.id,
      reason: reason.trim(),
      byUid: byUid,
      at: at,
    ),
  );
}

/// Money given back to a member. Only unallocated credit can be refunded,
/// so no month's balance changes.
CorrectionResult refundCredit({
  required String id,
  required Payment payment,
  required List<Allocation> allocations,
  required int amount,
  required int alreadyRefunded,
  required Set<String> reversedPaymentIds,
  required String reason,
  required String byUid,
  required DateTime at,
}) {
  _requirePositiveAmount(payment.amount, 'payment.amount');
  _requirePositiveAmount(amount, 'amount');
  if (alreadyRefunded < 0) {
    throw ArgumentError.value(
      alreadyRefunded,
      'alreadyRefunded',
      'Must not be negative',
    );
  }
  _needReason(reason);
  if (payment.status != PaymentStatus.verified ||
      reversedPaymentIds.contains(payment.id)) {
    throw MoneyRuleError('Only a valid verified payment can be refunded');
  }
  for (final allocation in allocations) {
    _requirePositiveAmount(allocation.amount, 'allocation.amount');
  }
  final allocated = allocations
      .where((a) => a.paymentId == payment.id)
      .fold<int>(0, (s, a) => s + a.amount);
  final credit = payment.amount - allocated - alreadyRefunded;
  if (amount > credit) {
    throw MoneyRuleError('Refund exceeds the unallocated credit ($credit)');
  }
  return _result(
    Correction(
      id: id,
      type: CorrectionType.refund,
      paymentId: payment.id,
      amount: amount,
      reason: reason.trim(),
      byUid: byUid,
      at: at,
    ),
  );
}

/// Payments excluded from every balance and from the fund.
Set<String> reversedPaymentIds(List<Correction> cs) => {
  for (final c in cs)
    if (c.type != CorrectionType.refund) c.paymentId,
};

/// Refunded credit per payment, for [applyCredits].
Map<String, int> refundsByPayment(List<Correction> cs) {
  final m = <String, int>{};
  for (final c in cs) {
    if (c.type == CorrectionType.refund) {
      _requirePositiveAmount(c.amount, 'refund.amount');
      m[c.paymentId] = (m[c.paymentId] ?? 0) + c.amount;
    }
  }
  return m;
}

/// Signed fund adjustment from refunds (negative: money left the fund).
int refundAdjustments(List<Correction> cs) =>
    -refundsByPayment(cs).values.fold<int>(0, (s, v) => s + v);
