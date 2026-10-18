/// Fitness Hub – Stage 2 money logic.
///
/// Pure Dart: no Firebase, no Flutter. All amounts are integers in pesewas
/// (GH₵30.00 = 3000) so we never get floating-point rounding errors.
library money_logic;

enum PaymentMethod { momo, cash }

enum PaymentStatus { pending, verified, rejected }

enum DuesStatus { exempt, paid, partial, unpaid, overdue }

enum ExpenseStatus { draft, submitted, approved, paid, rejected }

class Member {
  final String id;
  final bool active; // false = paused
  const Member(this.id, {this.active = true});
}

class Dues {
  final String id;
  final String memberId;
  final String period; // 'YYYY-MM'
  final int amount; // frozen when generated
  final DateTime dueDate;
  final String? exemptReason; // non-null = exempt (reason is required)

  const Dues({
    required this.id,
    required this.memberId,
    required this.period,
    required this.amount,
    required this.dueDate,
    this.exemptReason,
  });

  bool get isExempt => exemptReason != null;
}

class Payment {
  final String id;
  final String memberId;
  final int amount;
  final PaymentMethod method;
  final PaymentStatus status;

  const Payment({
    required this.id,
    required this.memberId,
    required this.amount,
    required this.method,
    required this.status,
  });
}

class Allocation {
  final String id;
  final String paymentId;
  final String duesId;
  final int amount;

  const Allocation({
    required this.id,
    required this.paymentId,
    required this.duesId,
    required this.amount,
  });
}

class Expense {
  final String id;
  final int amount;
  final ExpenseStatus status;
  final int refunded; // money a seller gave back (its own record in Firestore)

  const Expense({
    required this.id,
    required this.amount,
    required this.status,
    this.refunded = 0,
  });
}

class AllocationResult {
  final List<Allocation> allocations;

  /// Money left over when no unpaid month remains. Held as credit.
  final int credit;
  const AllocationResult(this.allocations, this.credit);
}

class MoneyRuleError implements Exception {
  final String message;
  MoneyRuleError(this.message);
  @override
  String toString() => 'MoneyRuleError: $message';
}

void _requirePositiveAmount(int amount, String name) {
  if (amount <= 0) {
    throw ArgumentError.value(amount, name, 'Must be greater than zero');
  }
}

// ---------------------------------------------------------------- 1. Dues

/// One dues record per member per month, with a fixed ID so duplicates
/// can't exist.
String duesId(String period, String memberId) => '${period}_$memberId';

/// Creates dues for every active member who doesn't have a record yet.
/// Pressing "Generate dues" twice returns an empty list the second time.
List<Dues> generateDues({
  required String period,
  required List<Member> members,
  required Set<String> existingDuesIds,
  required int feeAmount,
  required DateTime dueDate,
}) {
  if (feeAmount <= 0) throw MoneyRuleError('Fee must be greater than zero');
  final created = <Dues>[];
  for (final m in members) {
    if (!m.active) continue; // paused members are skipped
    final id = duesId(period, m.id);
    if (existingDuesIds.contains(id)) continue; // already generated
    created.add(
      Dues(
        id: id,
        memberId: m.id,
        period: period,
        amount: feeAmount, // frozen: later fee changes don't touch this
        dueDate: dueDate,
      ),
    );
  }
  return created;
}

/// Marks dues exempt. A reason is mandatory.
Dues exempt(Dues d, String reason) {
  if (reason.trim().isEmpty) {
    throw MoneyRuleError('An exemption needs a recorded reason');
  }
  return Dues(
    id: d.id,
    memberId: d.memberId,
    period: d.period,
    amount: d.amount,
    dueDate: d.dueDate,
    exemptReason: reason.trim(),
  );
}

// ------------------------------------------------- 2–4. Payments & balance

/// Only verified payments that have not been reversed count as money.
bool _counts(Payment p, Set<String> reversedPaymentIds) =>
    p.status == PaymentStatus.verified && !reversedPaymentIds.contains(p.id);

/// Total verified allocated to one dues record.
int allocatedTo(
  String duesId,
  List<Allocation> allocations,
  List<Payment> payments, {
  Set<String> reversedPaymentIds = const {},
}) {
  for (final payment in payments) {
    _requirePositiveAmount(payment.amount, 'payment.amount');
  }
  for (final allocation in allocations) {
    _requirePositiveAmount(allocation.amount, 'allocation.amount');
  }
  final byId = {for (final p in payments) p.id: p};
  var total = 0;
  for (final a in allocations) {
    if (a.duesId != duesId) continue;
    final p = byId[a.paymentId];
    if (p != null && _counts(p, reversedPaymentIds)) total += a.amount;
  }
  return total;
}

/// balance = amount due − allocated verified payments (never below zero).
/// Older unpaid dues remain separate dues records.
int balance(Dues d, int allocated) {
  if (allocated < 0) {
    throw ArgumentError.value(allocated, 'allocated', 'Must not be negative');
  }
  if (d.isExempt) return 0;
  final b = d.amount - allocated;
  return b < 0 ? 0 : b;
}

/// Total unpaid balance on a member's dues records before [period].
int arrearsBefore({
  required String period,
  required String memberId,
  required List<Dues> allDues,
  required List<Allocation> allocations,
  required List<Payment> payments,
  Set<String> reversedPaymentIds = const {},
}) {
  var total = 0;
  for (final d in allDues) {
    if (d.memberId != memberId || d.period.compareTo(period) >= 0) continue;
    total += balance(
      d,
      allocatedTo(
        d.id,
        allocations,
        payments,
        reversedPaymentIds: reversedPaymentIds,
      ),
    );
  }
  return total;
}

DuesStatus statusFor(Dues d, int allocated, DateTime now, {int graceDays = 0}) {
  if (d.isExempt) return DuesStatus.exempt;
  if (balance(d, allocated) == 0) return DuesStatus.paid;
  final overdueAfter = d.dueDate.add(Duration(days: graceDays));
  if (now.isAfter(overdueAfter)) return DuesStatus.overdue;
  return allocated > 0 ? DuesStatus.partial : DuesStatus.unpaid;
}

// -------------------------------------------------------- 3. Allocation

/// Checks the two protection rules for a set of allocations of one payment.
void validateAllocations(Payment p, List<Allocation> allocs) {
  _requirePositiveAmount(p.amount, 'payment.amount');
  if (p.status != PaymentStatus.verified) {
    throw MoneyRuleError('Only verified payments can be allocated');
  }
  for (final allocation in allocs) {
    _requirePositiveAmount(allocation.amount, 'allocation.amount');
  }
  final sum = allocs.fold<int>(0, (s, a) => s + a.amount);
  if (sum > p.amount) {
    throw MoneyRuleError('Allocations exceed the payment amount');
  }
}

/// Automatic allocation: the payment goes to the member's oldest unpaid
/// month first, unless [intendedPeriodId] has a balance. Leftover becomes credit.
AllocationResult autoAllocate({
  required Payment payment,
  required List<Dues> memberDues,
  required List<Allocation> existingAllocations,
  required List<Payment> allPayments,
  String? intendedPeriodId,
  Set<String> reversedPaymentIds = const {},
  int refunded = 0, // credit from this payment already given back
}) {
  _requirePositiveAmount(payment.amount, 'payment.amount');
  if (refunded < 0) {
    throw ArgumentError.value(refunded, 'refunded', 'Must not be negative');
  }
  if (payment.status != PaymentStatus.verified) {
    throw MoneyRuleError('Only verified payments can be allocated');
  }
  final alreadyFromThis = existingAllocations
      .where((a) => a.paymentId == payment.id)
      .fold<int>(0, (s, a) => s + a.amount);
  if (alreadyFromThis + refunded > payment.amount) {
    throw MoneyRuleError('Allocations and refunds exceed the payment amount');
  }
  var remaining = payment.amount - alreadyFromThis - refunded;

  final ordered = [...memberDues.where((d) => d.memberId == payment.memberId)]
    ..sort((a, b) => a.period.compareTo(b.period)); // oldest first
  if (intendedPeriodId != null) {
    final intendedIndex = ordered.indexWhere((d) {
      if (d.period != intendedPeriodId) return false;
      final paidSoFar = allocatedTo(
        d.id,
        existingAllocations,
        allPayments,
        reversedPaymentIds: reversedPaymentIds,
      );
      return balance(d, paidSoFar) > 0;
    });
    if (intendedIndex > 0) {
      ordered.insert(0, ordered.removeAt(intendedIndex));
    }
  }

  final result = <Allocation>[];
  for (final d in ordered) {
    if (remaining <= 0) break;
    final paidSoFar = allocatedTo(
      d.id,
      existingAllocations,
      allPayments,
      reversedPaymentIds: reversedPaymentIds,
    );
    final owed = balance(d, paidSoFar);
    if (owed <= 0) continue; // paid or exempt
    final give = remaining < owed ? remaining : owed;
    result.add(
      Allocation(
        id: '${payment.id}_${d.id}', // fixed ID: can't allocate twice
        paymentId: payment.id,
        duesId: d.id,
        amount: give,
      ),
    );
    remaining -= give;
  }
  validateAllocations(payment, [
    ...existingAllocations.where((a) => a.paymentId == payment.id),
    ...result,
  ]);
  return AllocationResult(result, remaining);
}

/// Run this after new dues are generated. Any leftover credit on a member's
/// verified payments is applied to their oldest unpaid months. Pass
/// [payments] oldest first. Reversed payments are skipped.
List<Allocation> applyCredits({
  required String memberId,
  required List<Dues> allDues,
  required List<Payment> payments,
  required List<Allocation> allocations,
  Set<String> reversedPaymentIds = const {},
  Map<String, int> refunded = const {},
}) {
  for (final payment in payments) {
    _requirePositiveAmount(payment.amount, 'payment.amount');
  }
  for (final allocation in allocations) {
    _requirePositiveAmount(allocation.amount, 'allocation.amount');
  }
  for (final amount in refunded.values) {
    if (amount < 0) {
      throw ArgumentError.value(amount, 'refunded', 'Must not be negative');
    }
  }
  final running = [...allocations];
  final created = <Allocation>[];
  for (final p in payments) {
    if (p.memberId != memberId || !_counts(p, reversedPaymentIds)) continue;
    final r = autoAllocate(
      payment: p,
      memberDues: allDues,
      existingAllocations: running,
      allPayments: payments,
      reversedPaymentIds: reversedPaymentIds,
      refunded: refunded[p.id] ?? 0,
    );
    running.addAll(r.allocations);
    created.addAll(r.allocations);
  }
  return created;
}

// ------------------------------------------------- 5. Corrections / fund

/// Fund position = opening + verified income − paid expenses ± adjustments.
/// Reversed payments are excluded; unpaid dues and pending claims never count.
/// [adjustments] is signed (e.g. refunds to members are negative).
int fundPosition({
  required int opening,
  required List<Payment> payments,
  required List<Expense> expenses,
  Set<String> reversedPaymentIds = const {},
  int adjustments = 0,
}) {
  for (final payment in payments) {
    _requirePositiveAmount(payment.amount, 'payment.amount');
  }
  final income = payments
      .where((p) => _counts(p, reversedPaymentIds))
      .fold<int>(0, (s, p) => s + p.amount);
  final spent = expenses
      .where((e) => e.status == ExpenseStatus.paid)
      .fold<int>(0, (s, e) => s + e.amount - e.refunded);
  return opening + income - spent + adjustments;
}
