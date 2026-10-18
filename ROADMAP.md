# Fitness Hub — Build Roadmap

Flutter Web + Firebase. Dues, MoMo/cash verification, expenses, reports for the fitness group.
**This file is the source of truth. If a task isn't here, it doesn't get built yet.**

Source documents: the 16-frame flow diagram (Eraser export), the screen designs (Dashboard done; Members next), this roadmap.

---

## 1. Golden rules (never break these)

Taken straight from the flow diagram. Every feature is checked against them.

1. **Claimed money is not money.** A pending MoMo submission, a screenshot, or a rejected payment never reduces a balance and never counts as collected.
2. **Only verified payments reduce balances.** Balance = amount due + arrears − allocated *verified* payments.
3. **A payment and its allocation are different records.** A payment is money received; an allocation says which month it covers. One payment can cover several months.
4. **No double counting.** One MoMo reference can be used once only (`momo_references`).
5. **Nothing financial is deleted or silently edited.** Fix mistakes with void / reversal / correction records, and write an audit entry.
6. **Proposed expenses don't reduce funds.** Only a *paid* expense does.
7. **Unpaid dues are never added to money held.** Outstanding dues, pending claims and real funds are always shown separately.
8. **Attendance and payment status are independent.**
9. **Hiding a button is not security.** Firestore rules enforce every permission.
10. **Never collect MoMo PINs or OTPs.** Secret keys never go in Flutter code.
11. **A failed notification never reverses a financial action.**
12. **Past dues don't change when settings change.** Changes apply from now on.
13. **Recorded balance ≠ real balance** until a cash count or MoMo statement reconciliation is done.

---

## 2. Scope

### Version 1 (must ship)
- Staff login (Organizer, Treasurer) and group setup
- Members: add, edit, search, pause/deactivate, CSV import/export
- Monthly dues generation (no duplicates) and automatic Paid / Partial / Unpaid / Overdue
- MoMo submission → pending → treasurer verifies or rejects
- Cash receipts with receipt numbers
- Expenses and purchases (draft → approved → paid)
- Dashboard with fund position
- Monthly income and unpaid-members reports
- Audit trail and basic export

### Phase 2 (after v1 works with real money)
- Member self-service portal (own balance, own history, submit payment, dispute)
- Notifications and reminders (start with copyable WhatsApp text)
- Workout calendar and attendance
- Receipt/evidence uploads (Firebase Storage)

### Future (dashed lines in the diagram, not built until configured)
- Automatic MoMo confirmation via an approved provider (Paystack / Hubtel / MTN MoMo)
- QR check-in, charts, multi-group support

---

## 3. Frame-to-stage map

| Diagram frame | Built in stage |
|---|---|
| 1 Overview, 2 Auth & Setup | 1 and 4 |
| 16 Database & Backend Data Flow | 1 |
| 4 Monthly Dues, 5 MoMo Verification, 6 Cash, 7 Expenses | 2 (logic), 4 (screens) |
| 8 Ledger & Reconciliation, 14 Audit, 15 Exceptions | 2–3 |
| 3 Members | 4 |
| 12 Reports & Exports, 13 Settings | 5 |
| 9 Workouts, 10 Notifications, 11 Member Portal | Phase 2 |

---

## 4. Stages

Each stage has an **exit check**. Don't start the next stage until you've confirmed the exit check on your own device or browser.

### Stage 1 — Backend foundation
- [ ] Two Firebase projects: `fitness-hub-dev` and `fitness-hub-prod`
- [ ] Email/Password auth enabled (dev)
- [ ] Firestore created, `firestore.rules` deployed
- [ ] `flutterfire configure` done, app connects
- [ ] First `users/{uid}` doc added by hand with `role: organizer`
- [ ] Collections agreed: `users, settings, counters, members, dues_periods, member_dues, payments, momo_references, payment_allocations, expenses, audit_logs`
- [ ] Flutter bootstrap: `main.dart`, auth gate, role provider

**Exit check:** app runs in Chrome, you can sign in, you can read your own role, and a signed-in user with no `users` doc *cannot* read `members`.

### Stage 2 — Business logic
Write and agree the rules *before* any screen uses them.
- [ ] Dues generation: one record per member per period, skip existing, skip paused/exempt
- [ ] Balance calculation (verified allocations only) and status rules (Paid / Partial / Unpaid / Overdue)
- [ ] MoMo flow: submit → duplicate check → pending → verify / reject / need info
- [ ] Cash flow: record → receipt number → allocate
- [ ] Allocation rules: advance payment, multi-month, overpayment
- [ ] Expense lifecycle: draft → submitted → approved → paid (and rejected)
- [ ] Corrections: void, reversal, refund (always with audit entry)
- [ ] Fund position formula: opening + verified income − paid expenses ± adjustments

**Exit check:** every rule written as plain-language test cases (see Stage 3 list) that you've read and agreed with.

### Stage 3 — Security and testing
- [ ] Tighten expense and allocation rules (allocation can't exceed payment)
- [ ] Input validation (amounts > 0, required fields, phone format)
- [ ] Duplicate-prevention tested for MoMo references and dues records
- [ ] Rules tested with the Firebase emulator
- [ ] Test cases pass:
  - Full MoMo payment, verified → balance 0
  - MoMo claim never verified → balance unchanged
  - Partial payment → correct remaining balance
  - Same MoMo reference twice → blocked
  - Cash split across two months → both updated
  - New month → no duplicate dues
  - Wrong entry → corrected, history preserved
  - Non-staff user → denied

**Exit check:** all test cases pass in the emulator.

### Stage 4 — Connect the UI screens
Build in this order, one at a time, confirm each on device before the next:
1. [ ] Login + group setup
2. [ ] Dashboard shell (design done)
3. [ ] Members (list, profile, add/edit, status change, CSV)
4. [ ] Monthly Dues
5. [ ] Verify Payments (MoMo queue)
6. [ ] Cash Register
7. [ ] Expenses & Purchases
8. [ ] Dashboard wired to real data

**Exit check:** you run a full fake month with a few test members: dues generated, MoMo and cash payments recorded, one rejection, one expense, and the dashboard matches hand-calculated totals.

### Stage 5 — Reports and advanced features
- [ ] Monthly financial statement and unpaid-members report
- [ ] CSV/PDF export
- [ ] Cash count reconciliation and MoMo statement reconciliation
- [ ] Settings screen (dues amount, categories, approval limits)
- [ ] Then Phase 2 items, in the order of the group's real needs

**Exit check:** treasurer can produce a monthly statement the committee accepts.

---

## 5. Roles (v1)

| Role | Can do |
|---|---|
| Organizer | Settings, members, create dues, record expenses |
| Treasurer | Everything above **plus verify or reject MoMo payments** |
| Member | Phase 2 only |

The first organizer is created by hand in the console. The app never lets users assign their own roles.

---

## 6. Before you start any new task, ask

- Which stage and frame is this from? If none, park it in "Parking lot".
- Does it break any golden rule above?
- Does it touch money? Then it needs an audit entry and no delete.
- Did I confirm the previous step works on my device?

---

## 7. Parking lot (ideas that are NOT in v1)

- AI chat, screenshot reading, workout streaks and badges
- Multi-group support, sponsorship/donation tracking
- Automatic WhatsApp/SMS sending

---

## 8. Status log

| Date | Stage | Note |
|---|---|---|
| 2026-10-18 | Pre-1 | Flows and Dashboard design done. Firestore rules drafted. Starting Stage 1. |
