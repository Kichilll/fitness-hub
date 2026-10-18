# Stage 2 Rules

## 4. Dues status

- Exempt dues have a zero balance.
- Paid dues have a zero balance; unpaid dues have no amount allocated; partial dues have some amount allocated and a remaining balance.
- Overdue wins over Partial when a dues record still has a balance and is past its due date plus the grace period.
- Show the amount paid separately from the status.

## 5. Corrections

- Corrections are separate records. Keep the original payment and its allocations; do not edit or delete them.
- A void or reversal correction excludes the payment and its allocations from balances and fund calculations.
- Refunds come only from unallocated payment credit. A payment with refunds cannot be reversed.

## Agreed Stage 2 decisions

1. A MoMo reference stays used even after a rejection.
2. Refunds come only from unallocated credit.
3. A payment with refunds cannot be reversed.
4. Any staff member can approve and pay expenses for now. This authorization is enforced in Firestore rules, not in domain logic.
