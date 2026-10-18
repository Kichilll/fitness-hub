import 'package:test/test.dart';
import 'package:fitness_hub/domain/money_logic.dart';
import 'package:fitness_hub/domain/workflows.dart';

final at = DateTime(2026, 10, 18);

Dues d(String period, {int amount = 3000}) => Dues(
  id: duesId(period, 'm1'),
  memberId: 'm1',
  period: period,
  amount: amount,
  dueDate: DateTime(
    int.parse(period.substring(0, 4)),
    int.parse(period.substring(5, 7)),
    28,
  ),
);

Payment pay(
  String id,
  int amount, {
  PaymentStatus status = PaymentStatus.verified,
}) => Payment(
  id: id,
  memberId: 'm1',
  amount: amount,
  method: PaymentMethod.momo,
  status: status,
);

MomoSubmission sub() => submitMomo(
  id: 'p1',
  memberId: 'm1',
  amount: 3000,
  reference: 'ab 123',
  usedReferences: {},
);

void main() {
  group('MoMo', () {
    test('submission is pending and the reference is normalized', () {
      final s = sub();
      expect(s.status, MomoStatus.pending);
      expect(s.reference, 'AB123');
    });

    test(
      'same reference twice is blocked, even with different case/spaces',
      () {
        expect(
          () => submitMomo(
            id: 'p2',
            memberId: 'm2',
            amount: 3000,
            reference: ' ab123',
            usedReferences: {'AB123'},
          ),
          throwsA(isA<MoneyRuleError>()),
        );
      },
    );

    test('non-positive amounts and empty reference are refused', () {
      for (final amount in [0, -1]) {
        expect(
          () => submitMomo(
            id: 'p',
            memberId: 'm',
            amount: amount,
            reference: 'X',
            usedReferences: {},
          ),
          throwsArgumentError,
        );
      }
      expect(
        () => submitMomo(
          id: 'p',
          memberId: 'm',
          amount: 100,
          reference: '  ',
          usedReferences: {},
        ),
        throwsA(isA<MoneyRuleError>()),
      );
    });

    test('only the treasurer can verify', () {
      expect(
        () => decideMomo(
          sub: sub(),
          next: MomoStatus.verified,
          role: Role.organizer,
          byUid: 'o1',
          at: at,
        ),
        throwsA(isA<MoneyRuleError>()),
      );
    });

    test('verify creates an audit entry and a verified payment', () {
      final r = decideMomo(
        sub: sub(),
        next: MomoStatus.verified,
        role: Role.treasurer,
        byUid: 't1',
        at: at,
      );
      expect(r.audit.action, 'momo_verified');
      expect(r.submission.toPayment().status, PaymentStatus.verified);
    });

    test('a pending claim never reduces a balance', () {
      final p = sub().toPayment();
      final a = Allocation(
        id: 'a',
        paymentId: 'p1',
        duesId: '2026-10_m1',
        amount: 3000,
      );
      expect(allocatedTo('2026-10_m1', [a], [p]), 0);
    });

    test('reject and need-info require a reason', () {
      expect(
        () => decideMomo(
          sub: sub(),
          next: MomoStatus.rejected,
          role: Role.treasurer,
          byUid: 't1',
          at: at,
        ),
        throwsA(isA<MoneyRuleError>()),
      );
      expect(
        () => decideMomo(
          sub: sub(),
          next: MomoStatus.needInfo,
          role: Role.treasurer,
          byUid: 't1',
          at: at,
        ),
        throwsA(isA<MoneyRuleError>()),
      );
    });

    test(
      'need-info can later be verified; verified and rejected are final',
      () {
        final ni = decideMomo(
          sub: sub(),
          next: MomoStatus.needInfo,
          role: Role.treasurer,
          byUid: 't1',
          at: at,
          reason: 'Name does not match',
        ).submission;
        final v = decideMomo(
          sub: ni,
          next: MomoStatus.verified,
          role: Role.treasurer,
          byUid: 't1',
          at: at,
        ).submission;
        expect(v.status, MomoStatus.verified);
        expect(
          () => decideMomo(
            sub: v,
            next: MomoStatus.rejected,
            role: Role.treasurer,
            byUid: 't1',
            at: at,
            reason: 'x',
          ),
          throwsA(isA<MoneyRuleError>()),
        );
      },
    );
  });

  group('Cash', () {
    test('receipt is numbered, verified and audited', () {
      final r = recordCash(
        id: 'c1',
        memberId: 'm1',
        amount: 3000,
        counterValue: 12,
        byUid: 'o1',
        at: at,
      );
      expect(r.receiptNo, 'R-000012');
      expect(r.payment.status, PaymentStatus.verified);
      expect(r.audit.action, 'cash_recorded');
    });

    test('non-positive amount refused', () {
      for (final amount in [0, -1]) {
        expect(
          () => recordCash(
            id: 'c1',
            memberId: 'm1',
            amount: amount,
            counterValue: 1,
            byUid: 'o1',
            at: at,
          ),
          throwsArgumentError,
        );
      }
    });

    test('cash split across two months updates both', () {
      final r = recordCash(
        id: 'c1',
        memberId: 'm1',
        amount: 6000,
        counterValue: 1,
        byUid: 'o1',
        at: at,
      );
      final res = autoAllocate(
        payment: r.payment,
        memberDues: [d('2026-10'), d('2026-11')],
        existingAllocations: [],
        allPayments: [r.payment],
      );
      expect(res.allocations.map((a) => a.amount), [3000, 3000]);
    });
  });

  group('Expenses', () {
    final at0 = at;
    test('full lifecycle with audit entries', () {
      var e = newExpense(id: 'e1', amount: 2000);
      for (final s in [
        ExpenseStatus.submitted,
        ExpenseStatus.approved,
        ExpenseStatus.paid,
      ]) {
        final r = advanceExpense(e, s, byUid: 'o1', at: at0);
        expect(r.audit.action, 'expense_${s.name}');
        e = r.expense;
      }
      expect(e.status, ExpenseStatus.paid);
    });

    test('cannot skip steps or leave a final state', () {
      final e = newExpense(id: 'e1', amount: 2000);
      expect(
        () => advanceExpense(e, ExpenseStatus.paid, byUid: 'o1', at: at0),
        throwsA(isA<MoneyRuleError>()),
      );
    });

    test('rejection needs a reason and is final', () {
      var e = advanceExpense(
        newExpense(id: 'e1', amount: 2000),
        ExpenseStatus.submitted,
        byUid: 'o1',
        at: at0,
      ).expense;
      expect(
        () => advanceExpense(e, ExpenseStatus.rejected, byUid: 'o1', at: at0),
        throwsA(isA<MoneyRuleError>()),
      );
      e = advanceExpense(
        e,
        ExpenseStatus.rejected,
        byUid: 'o1',
        at: at0,
        reason: 'Too costly',
      ).expense;
      expect(
        () => advanceExpense(e, ExpenseStatus.approved, byUid: 'o1', at: at0),
        throwsA(isA<MoneyRuleError>()),
      );
    });

    test('only paid expenses reduce the fund', () {
      final list = [
        const Expense(id: '1', amount: 1000, status: ExpenseStatus.submitted),
        const Expense(id: '2', amount: 1000, status: ExpenseStatus.approved),
        const Expense(id: '3', amount: 1000, status: ExpenseStatus.rejected),
        const Expense(id: '4', amount: 500, status: ExpenseStatus.paid),
      ];
      expect(fundPosition(opening: 5000, payments: [], expenses: list), 4500);
    });
  });

  group('Corrections', () {
    Correction reversal() => reversePayment(
      id: 'k1',
      payment: pay('p1', 3000),
      reason: 'Bounced',
      byUid: 't1',
      at: at,
      alreadyReversed: {},
    ).correction;

    test('reason is required', () {
      expect(
        () => voidPayment(
          id: 'k1',
          payment: pay('p1', 3000),
          reason: ' ',
          byUid: 't1',
          at: at,
          alreadyReversed: {},
        ),
        throwsA(isA<MoneyRuleError>()),
      );
    });

    test('void rejects non-positive payment amounts', () {
      for (final amount in [0, -1]) {
        expect(
          () => voidPayment(
            id: 'v1',
            payment: pay('p1', amount),
            reason: 'Recorded in error',
            byUid: 't1',
            at: at,
            alreadyReversed: {},
          ),
          throwsArgumentError,
        );
      }
    });

    test('reversal is audited and the payment stops counting', () {
      final r = reversePayment(
        id: 'k1',
        payment: pay('p1', 3000),
        reason: 'Bounced',
        byUid: 't1',
        at: at,
        alreadyReversed: {},
      );
      expect(r.audit.action, 'correction_reversal');
      final reversed = reversedPaymentIds([r.correction]);
      final a = Allocation(
        id: 'a',
        paymentId: 'p1',
        duesId: '2026-10_m1',
        amount: 3000,
      );
      expect(
        allocatedTo(
          '2026-10_m1',
          [a],
          [pay('p1', 3000)],
          reversedPaymentIds: reversed,
        ),
        0,
      );
    });

    test(
      'void keeps original payment and allocation while restoring balance',
      () {
        final payment = pay('p1', 3000);
        final dues = d('2026-10');
        final allocation = Allocation(
          id: 'a',
          paymentId: payment.id,
          duesId: dues.id,
          amount: 3000,
        );
        final payments = [payment];
        final allocations = [allocation];
        final correction = voidPayment(
          id: 'v1',
          payment: payment,
          reason: 'Recorded in error',
          byUid: 't1',
          at: at,
          alreadyReversed: {},
        );
        final excluded = reversedPaymentIds([correction.correction]);
        final allocated = allocatedTo(
          dues.id,
          allocations,
          payments,
          reversedPaymentIds: excluded,
        );

        expect(payments, contains(same(payment)));
        expect(allocations, contains(same(allocation)));
        expect(allocated, 0);
        expect(balance(dues, allocated), 3000);
      },
    );

    test('pending payment cannot be reversed (void it instead)', () {
      expect(
        () => reversePayment(
          id: 'k1',
          payment: pay('p1', 3000, status: PaymentStatus.pending),
          reason: 'x',
          byUid: 't1',
          at: at,
          alreadyReversed: {},
        ),
        throwsA(isA<MoneyRuleError>()),
      );
      final v = voidPayment(
        id: 'k2',
        payment: pay('p1', 3000, status: PaymentStatus.pending),
        reason: 'Entered twice',
        byUid: 't1',
        at: at,
        alreadyReversed: {},
      );
      expect(v.correction.type, CorrectionType.voidEntry);
    });

    test('cannot reverse twice', () {
      expect(
        () => reversePayment(
          id: 'k2',
          payment: pay('p1', 3000),
          reason: 'again',
          byUid: 't1',
          at: at,
          alreadyReversed: reversedPaymentIds([reversal()]),
        ),
        throwsA(isA<MoneyRuleError>()),
      );
    });

    test('refund only from unallocated credit', () {
      final p = pay('p1', 5000);
      final allocs = [
        Allocation(
          id: 'a',
          paymentId: 'p1',
          duesId: '2026-10_m1',
          amount: 3000,
        ),
      ];
      CorrectionResult refund(int amt, {int already = 0}) => refundCredit(
        id: 'r1',
        payment: p,
        allocations: allocs,
        amount: amt,
        alreadyRefunded: already,
        reversedPaymentIds: {},
        reason: 'Member left',
        byUid: 't1',
        at: at,
      );
      expect(refund(2000).correction.amount, 2000);
      for (final amount in [0, -1]) {
        expect(() => refund(amount), throwsArgumentError);
      }
      expect(() => refund(2500), throwsA(isA<MoneyRuleError>()));
      expect(() => refund(1000, already: 1500), throwsA(isA<MoneyRuleError>()));
    });

    test('refund reduces the fund through adjustments', () {
      final refund = Correction(
        id: 'r1',
        type: CorrectionType.refund,
        paymentId: 'p1',
        amount: 2000,
        reason: 'Left',
        byUid: 't1',
        at: at,
      );
      expect(
        fundPosition(
          opening: 0,
          payments: [pay('p1', 5000)],
          expenses: [],
          adjustments: refundAdjustments([refund]),
        ),
        3000,
      );
    });

    test('reversal blocked once a refund exists', () {
      expect(
        () => reversePayment(
          id: 'k1',
          payment: pay('p1', 3000),
          reason: 'x',
          byUid: 't1',
          at: at,
          alreadyReversed: {},
          alreadyRefunded: 500,
        ),
        throwsA(isA<MoneyRuleError>()),
      );
    });
  });

  group('Credit and arrears', () {
    test('leftover credit is applied when next month dues are generated', () {
      final p = pay('p1', 5000);
      final first = autoAllocate(
        payment: p,
        memberDues: [d('2026-10')],
        existingAllocations: [],
        allPayments: [p],
      );
      expect(first.credit, 2000);
      final next = applyCredits(
        memberId: 'm1',
        allDues: [d('2026-10'), d('2026-11')],
        payments: [p],
        allocations: first.allocations,
      );
      expect(next.single.duesId, '2026-11_m1');
      expect(next.single.amount, 2000);
    });

    test('refunded credit is not applied again', () {
      final p = pay('p1', 5000);
      final next = applyCredits(
        memberId: 'm1',
        allDues: [d('2026-10'), d('2026-11')],
        payments: [p],
        allocations: [
          Allocation(
            id: 'a',
            paymentId: 'p1',
            duesId: '2026-10_m1',
            amount: 3000,
          ),
        ],
        refunded: {'p1': 2000},
      );
      expect(next, isEmpty);
    });

    test('reversed payment gives no credit', () {
      final p = pay('p1', 5000);
      final next = applyCredits(
        memberId: 'm1',
        allDues: [d('2026-10')],
        payments: [p],
        allocations: [],
        reversedPaymentIds: {'p1'},
      );
      expect(next, isEmpty);
    });

    test(
      'older unpaid dues remain separate from the current month balance',
      () {
        final arrears = arrearsBefore(
          period: '2026-10',
          memberId: 'm1',
          allDues: [d('2026-09'), d('2026-10')],
          allocations: [],
          payments: [],
        );
        expect(arrears, 3000);
        expect(balance(d('2026-10'), 0), 3000);
        expect(balance(d('2026-10'), 1000), 2000);
      },
    );
  });
}
