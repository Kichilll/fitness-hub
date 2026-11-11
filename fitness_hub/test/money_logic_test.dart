import 'package:fitness_hub/domain/money_logic.dart';
import 'package:test/test.dart';

Dues d(String period, {int amount = 3000, String? exemptReason}) => Dues(
  id: duesId(period, 'm1'),
  memberId: 'm1',
  period: period,
  amount: amount,
  dueDate: DateTime(
    int.parse(period.substring(0, 4)),
    int.parse(period.substring(5, 7)),
    28,
  ),
  exemptReason: exemptReason,
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

void main() {
  group('Dues generation', () {
    final members = [
      const Member('a'),
      const Member('b'),
      const Member('c', active: false),
    ];

    test('creates dues for active members only', () {
      final r = generateDues(
        period: '2026-10',
        members: members,
        existingDuesIds: {},
        feeAmount: 3000,
        dueDate: DateTime(2026, 10, 31),
      );
      expect(r.map((x) => x.id), ['2026-10_a', '2026-10_b']);
    });

    test('pressing Generate twice creates nothing new', () {
      final r = generateDues(
        period: '2026-10',
        members: members,
        existingDuesIds: {'2026-10_a', '2026-10_b'},
        feeAmount: 3000,
        dueDate: DateTime(2026, 10, 31),
      );
      expect(r, isEmpty);
    });

    test('exemption without a reason is refused', () {
      expect(() => exempt(d('2026-10'), '  '), throwsA(isA<MoneyRuleError>()));
    });
  });

  group('Balance and status', () {
    final now = DateTime(2026, 10, 10);

    test('unpaid before due date', () {
      expect(statusFor(d('2026-10'), 0, now), DuesStatus.unpaid);
    });
    test('partial', () {
      expect(statusFor(d('2026-10'), 1000, now), DuesStatus.partial);
      expect(balance(d('2026-10'), 1000), 2000);
    });
    test('paid', () {
      expect(statusFor(d('2026-10'), 3000, now), DuesStatus.paid);
    });
    test('overdue after due date plus grace', () {
      final late = DateTime(2026, 11, 5);
      expect(
        statusFor(d('2026-10'), 0, late, graceDays: 3),
        DuesStatus.overdue,
      );
      expect(
        statusFor(d('2026-10'), 0, DateTime(2026, 10, 30), graceDays: 3),
        DuesStatus.unpaid,
      );
    });
    test('exempt owes nothing', () {
      final e = d('2026-10', exemptReason: 'Injured');
      expect(balance(e, 0), 0);
      expect(statusFor(e, 0, now), DuesStatus.exempt);
    });
    test('pending and rejected payments do not touch balance', () {
      final payments = [
        pay('p1', 3000, status: PaymentStatus.pending),
        pay('p2', 3000, status: PaymentStatus.rejected),
      ];
      final allocs = [
        Allocation(
          id: 'x',
          paymentId: 'p1',
          duesId: '2026-10_m1',
          amount: 3000,
        ),
        Allocation(
          id: 'y',
          paymentId: 'p2',
          duesId: '2026-10_m1',
          amount: 3000,
        ),
      ];
      expect(allocatedTo('2026-10_m1', allocs, payments), 0);
    });
  });

  group('Allocation', () {
    test('exact payment clears the month', () {
      final p = pay('p1', 3000);
      final r = autoAllocate(
        payment: p,
        memberDues: [d('2026-10')],
        existingAllocations: [],
        allPayments: [p],
      );
      expect(r.allocations.single.amount, 3000);
      expect(r.credit, 0);
    });

    test('overpayment goes to next unpaid month, oldest first', () {
      final p = pay('p1', 7000);
      final r = autoAllocate(
        payment: p,
        memberDues: [d('2026-11'), d('2026-10'), d('2026-12')],
        existingAllocations: [],
        allPayments: [p],
      );
      expect(r.allocations.map((a) => a.duesId), [
        '2026-10_m1',
        '2026-11_m1',
        '2026-12_m1',
      ]);
      expect(r.allocations.map((a) => a.amount), [3000, 3000, 1000]);
      expect(r.credit, 0);
    });

    test('skips already-paid and exempt months', () {
      final old = pay('old', 3000);
      final p = pay('p2', 3000);
      final r = autoAllocate(
        payment: p,
        memberDues: [
          d('2026-09'),
          d('2026-10', exemptReason: 'Away'),
          d('2026-11'),
        ],
        existingAllocations: [
          Allocation(
            id: 'old_2026-09_m1',
            paymentId: 'old',
            duesId: '2026-09_m1',
            amount: 3000,
          ),
        ],
        allPayments: [old, p],
      );
      expect(r.allocations.single.duesId, '2026-11_m1');
    });

    test('leftover becomes credit when no unpaid month remains', () {
      final p = pay('p1', 5000);
      final r = autoAllocate(
        payment: p,
        memberDues: [d('2026-10')],
        existingAllocations: [],
        allPayments: [p],
      );
      expect(r.allocations.single.amount, 3000);
      expect(r.credit, 2000);
    });

    test('unverified payment cannot be allocated', () {
      final p = pay('p1', 3000, status: PaymentStatus.pending);
      expect(
        () => autoAllocate(
          payment: p,
          memberDues: [d('2026-10')],
          existingAllocations: [],
          allPayments: [p],
        ),
        throwsA(isA<MoneyRuleError>()),
      );
    });

    test('allocations can never exceed the payment', () {
      final p = pay('p1', 3000);
      expect(
        () => validateAllocations(p, [
          Allocation(
            id: 'a',
            paymentId: 'p1',
            duesId: '2026-10_m1',
            amount: 2000,
          ),
          Allocation(
            id: 'b',
            paymentId: 'p1',
            duesId: '2026-11_m1',
            amount: 2000,
          ),
        ]),
        throwsA(isA<MoneyRuleError>()),
      );
    });

    test('re-running allocation does not double allocate', () {
      final p = pay('p1', 3000);
      final first = autoAllocate(
        payment: p,
        memberDues: [d('2026-10')],
        existingAllocations: [],
        allPayments: [p],
      );
      final second = autoAllocate(
        payment: p,
        memberDues: [d('2026-10')],
        existingAllocations: first.allocations,
        allPayments: [p],
      );
      expect(second.allocations, isEmpty);
    });

    test('intended month is paid first before newer dues', () {
      final p = pay('p1', 7000);
      final r = autoAllocate(
        payment: p,
        memberDues: [d('2026-10', amount: 5000), d('2026-11', amount: 5000)],
        existingAllocations: [],
        allPayments: [p],
        intendedPeriodId: '2026-10',
      );
      expect(r.allocations.map((a) => a.duesId), ['2026-10_m1', '2026-11_m1']);
      expect(r.allocations.map((a) => a.amount), [5000, 2000]);
    });

    test('intended month is paid first before older unpaid dues', () {
      final p = pay('p1', 7000);
      final r = autoAllocate(
        payment: p,
        memberDues: [d('2026-09', amount: 5000), d('2026-10', amount: 5000)],
        existingAllocations: [],
        allPayments: [p],
        intendedPeriodId: '2026-10',
      );
      expect(r.allocations.map((a) => a.duesId), ['2026-10_m1', '2026-09_m1']);
      expect(r.allocations.map((a) => a.amount), [5000, 2000]);
    });

    test('fully paid intended month is skipped', () {
      final old = pay('old', 5000);
      final p = pay('p1', 7000);
      final r = autoAllocate(
        payment: p,
        memberDues: [d('2026-10', amount: 5000), d('2026-11', amount: 5000)],
        existingAllocations: [
          Allocation(
            id: 'old_oct',
            paymentId: 'old',
            duesId: '2026-10_m1',
            amount: 5000,
          ),
        ],
        allPayments: [old, p],
        intendedPeriodId: '2026-10',
      );
      expect(r.allocations.single.duesId, '2026-11_m1');
      expect(r.allocations.single.amount, 5000);
      expect(r.credit, 2000);
    });

    test('remainder is unallocated when intended month is the only due', () {
      final p = pay('p1', 8000);
      final r = autoAllocate(
        payment: p,
        memberDues: [d('2026-10', amount: 5000)],
        existingAllocations: [],
        allPayments: [p],
        intendedPeriodId: '2026-10',
      );
      expect(r.allocations.single.amount, 5000);
      expect(r.credit, 3000);
    });

    test('non-positive payment amounts are rejected with ArgumentError', () {
      for (final amount in [0, -1]) {
        final p = pay('p$amount', amount);
        expect(
          () => autoAllocate(
            payment: p,
            memberDues: [d('2026-10')],
            existingAllocations: [],
            allPayments: [p],
          ),
          throwsArgumentError,
        );
      }
    });

    test('non-positive refunded totals are rejected with ArgumentError', () {
      final p = pay('p1', 3000);
      expect(
        () => autoAllocate(
          payment: p,
          memberDues: [d('2026-10')],
          existingAllocations: [],
          allPayments: [p],
          refunded: -1,
        ),
        throwsArgumentError,
      );
    });

    test('non-positive allocation amounts are rejected with ArgumentError', () {
      final p = pay('p1', 3000);
      for (final amount in [0, -1]) {
        expect(
          () => validateAllocations(p, [
            Allocation(
              id: 'bad',
              paymentId: 'p1',
              duesId: '2026-10_m1',
              amount: amount,
            ),
          ]),
          throwsArgumentError,
        );
      }
    });

    test(
      'non-positive payment amounts are rejected by allocation validation',
      () {
        for (final amount in [0, -1]) {
          expect(
            () => validateAllocations(pay('p$amount', amount), []),
            throwsArgumentError,
          );
        }
      },
    );
  });

  group('Corrections and fund position', () {
    test('reversed payment no longer counts toward balance', () {
      final p = pay('p1', 3000);
      final a = Allocation(
        id: 'a',
        paymentId: 'p1',
        duesId: '2026-10_m1',
        amount: 3000,
      );
      expect(allocatedTo('2026-10_m1', [a], [p]), 3000);
      expect(
        allocatedTo('2026-10_m1', [a], [p], reversedPaymentIds: {'p1'}),
        0,
      );
    });

    test('fund = opening + verified income − paid expenses', () {
      final payments = [
        pay('p1', 3000),
        pay('p2', 3000, status: PaymentStatus.pending), // ignored
        pay('p3', 3000, status: PaymentStatus.rejected), // ignored
      ];
      final expenses = [
        const Expense(id: 'e1', amount: 1000, status: ExpenseStatus.paid),
        const Expense(
          id: 'e2',
          amount: 5000,
          status: ExpenseStatus.approved,
        ), // not paid yet
        const Expense(id: 'e3', amount: 2000, status: ExpenseStatus.draft),
      ];
      expect(
        fundPosition(opening: 10000, payments: payments, expenses: expenses),
        12000,
      );
    });

    test('refund reduces net spend; reversed payment reduces income', () {
      final payments = [pay('p1', 3000), pay('p2', 3000)];
      final expenses = [
        const Expense(
          id: 'e1',
          amount: 2000,
          status: ExpenseStatus.paid,
          refunded: 500,
        ),
      ];
      expect(
        fundPosition(
          opening: 0,
          payments: payments,
          expenses: expenses,
          reversedPaymentIds: {'p2'},
        ),
        1500,
      );
    });
  });
}
