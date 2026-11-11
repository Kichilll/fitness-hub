// Emulator tests for firestore.rules. Run from the project root:
//   firebase emulators:exec --only firestore --project demo-fitness-hub "npm --prefix rules_tests test"
import { describe, it, before, after, beforeEach } from 'node:test';
import fs from 'node:fs';
import {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} from '@firebase/rules-unit-testing';
import {
  doc,
  getDoc,
  setDoc,
  updateDoc,
  deleteDoc,
  writeBatch,
  serverTimestamp,
  Timestamp,
} from 'firebase/firestore';

let env;
const ts = () => serverTimestamp();
const due = Timestamp.fromDate(new Date('2026-10-05T00:00:00Z'));

const as = (uid) => env.authenticatedContext(uid).firestore();

before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-fitness-hub',
    firestore: {
      rules: fs.readFileSync(new URL('../firestore.rules', import.meta.url), 'utf8'),
    },
  });
});

after(async () => {
  await env.cleanup();
});

// ------------------------------------------------------------ seed data
beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    const now = Timestamp.now();

    // people
    await setDoc(doc(db, 'users/org1'), { role: 'organizer', active: true, displayName: 'Org' });
    await setDoc(doc(db, 'users/tre1'), { role: 'treasurer', active: true, displayName: 'Tre' });
    await setDoc(doc(db, 'users/gone1'), { role: 'treasurer', active: false, displayName: 'Gone' });

    // members
    await setDoc(doc(db, 'members/ama'), { name: 'Ama', phone: '0241234567', status: 'active' });
    await setDoc(doc(db, 'members/kofi'), { name: 'Kofi', phone: '0551234567', status: 'paused' });
    await setDoc(doc(db, 'members/yaw'), { name: 'Yaw', phone: '0201234567', status: 'active' });

    // periods and dues
    await setDoc(doc(db, 'dues_periods/2026-10'), { period: '2026-10', fee: 5000, dueDate: due });
    await setDoc(doc(db, 'dues_periods/2026-11'), { period: '2026-11', fee: 5000, dueDate: due });
    await setDoc(doc(db, 'member_dues/2026-10_ama'), {
      memberId: 'ama', period: '2026-10', amount: 5000, dueDate: due,
    });
    await setDoc(doc(db, 'member_dues/2026-11_ama'), {
      memberId: 'ama', period: '2026-11', amount: 5000, dueDate: due,
    });

    // counter
    await setDoc(doc(db, 'counters/receipts'), { next: 1 });

    // a verified cash payment of 7000 (nothing allocated yet)
    await setDoc(doc(db, 'payments/pay1'), {
      memberId: 'ama', amount: 7000, method: 'cash', status: 'verified',
      recordedBy: 'org1', verifiedBy: 'org1', verifiedAt: now, createdAt: now,
      receiptSeq: 0, receiptNo: 'R-000000', allocatedTotal: 0, refundedTotal: 0,
    });
    // a pending MoMo claim with its reference
    await setDoc(doc(db, 'payments/momo1'), {
      memberId: 'ama', amount: 5000, method: 'momo', status: 'pending',
      recordedBy: 'org1', createdAt: now, reference: 'MOMO1111',
      allocatedTotal: 0, refundedTotal: 0,
    });
    await setDoc(doc(db, 'momo_references/MOMO1111'), { paymentId: 'momo1', createdAt: now });

    // expenses in each state
    const ex = (status, extra = {}) => ({
      title: 'Water', category: 'supplies', amount: 6000, status, refunded: 0,
      recordedBy: 'org1', createdAt: now, ...extra,
    });
    await setDoc(doc(db, 'expenses/exDraft'), ex('draft'));
    await setDoc(doc(db, 'expenses/exSubmitted'), ex('submitted'));
    await setDoc(doc(db, 'expenses/exApproved'), ex('approved'));
    await setDoc(doc(db, 'expenses/exPaid'), ex('paid'));
  });
});

// helpers to build documents the app would write
const momoPayment = (over = {}) => ({
  memberId: 'ama', amount: 5000, method: 'momo', status: 'pending',
  recordedBy: 'tre1', createdAt: ts(), reference: 'MOMO2222',
  allocatedTotal: 0, refundedTotal: 0, ...over,
});
const cashPayment = (seq, uid, over = {}) => ({
  memberId: 'ama', amount: 5000, method: 'cash', status: 'verified',
  recordedBy: uid, verifiedBy: uid, verifiedAt: ts(), createdAt: ts(),
  receiptSeq: seq, receiptNo: `R-${String(seq).padStart(6, '0')}`,
  allocatedTotal: 0, refundedTotal: 0, ...over,
});
const audit = (uid, action, targetId) => ({
  action, targetId, byUid: uid, reason: '', at: ts(),
});
const correction = (uid, type, paymentId, over = {}) => ({
  type, paymentId, amount: 0, reason: 'Entered by mistake', byUid: uid, at: ts(), ...over,
});

// ================================================================== tests
describe('1. Access control', () => {
  it('signed-out user cannot read members', async () => {
    const db = env.unauthenticatedContext().firestore();
    await assertFails(getDoc(doc(db, 'members/ama')));
  });
  it('signed-in user with no users document is denied', async () => {
    await assertFails(getDoc(doc(as('stranger'), 'members/ama')));
  });
  it('deactivated staff are denied', async () => {
    await assertFails(getDoc(doc(as('gone1'), 'members/ama')));
  });
  it('active staff can read members', async () => {
    await assertSucceeds(getDoc(doc(as('org1'), 'members/ama')));
    await assertSucceeds(getDoc(doc(as('tre1'), 'members/ama')));
  });
  it('a user can read their own role doc, and cannot change it', async () => {
    await assertSucceeds(getDoc(doc(as('org1'), 'users/org1')));
    await assertFails(setDoc(doc(as('org1'), 'users/org1'), { role: 'organizer', active: true }));
    await assertFails(setDoc(doc(as('stranger'), 'users/stranger'), { role: 'organizer', active: true }));
  });
  it('only the organizer can write settings', async () => {
    await assertSucceeds(setDoc(doc(as('org1'), 'settings/group'), { defaultFee: 5000 }));
    await assertFails(setDoc(doc(as('tre1'), 'settings/group'), { defaultFee: 5000 }));
    await assertFails(setDoc(doc(as('org1'), 'settings/group'), { defaultFee: 0 }));
  });
});

describe('2. Members', () => {
  it('valid member can be created', async () => {
    await assertSucceeds(setDoc(doc(as('org1'), 'members/esi'),
      { name: 'Esi', phone: '0551234567', status: 'active' }));
  });
  it('international Ghana format is accepted', async () => {
    await assertSucceeds(setDoc(doc(as('org1'), 'members/esi'),
      { name: 'Esi', phone: '+233551234567', status: 'active' }));
  });
  it('bad phone or status is refused', async () => {
    await assertFails(setDoc(doc(as('org1'), 'members/esi'),
      { name: 'Esi', phone: '12345', status: 'active' }));
    await assertFails(setDoc(doc(as('org1'), 'members/esi'),
      { name: 'Esi', phone: '0551234567', status: 'banned' }));
  });
  it('members can be paused but never deleted', async () => {
    await assertSucceeds(updateDoc(doc(as('org1'), 'members/ama'), { status: 'paused' }));
    await assertFails(deleteDoc(doc(as('org1'), 'members/ama')));
  });
});

describe('3. Dues generation and duplicates', () => {
  const newDues = (over = {}) => ({
    memberId: 'yaw', period: '2026-10', amount: 5000, dueDate: due, ...over,
  });
  it('creates a record with the fixed ID and the period fee', async () => {
    await assertSucceeds(setDoc(doc(as('org1'), 'member_dues/2026-10_yaw'), newDues()));
  });
  it('refuses a wrong ID', async () => {
    await assertFails(setDoc(doc(as('org1'), 'member_dues/random_yaw'), newDues()));
  });
  it('refuses an amount that is not the period fee', async () => {
    await assertFails(setDoc(doc(as('org1'), 'member_dues/2026-10_yaw'), newDues({ amount: 4000 })));
  });
  it('refuses dues for a paused member', async () => {
    await assertFails(setDoc(doc(as('org1'), 'member_dues/2026-10_kofi'), newDues({ memberId: 'kofi' })));
  });
  it('a second record for the same member and month is refused', async () => {
    await assertFails(setDoc(doc(as('org1'), 'member_dues/2026-10_ama'),
      { memberId: 'ama', period: '2026-10', amount: 5000, dueDate: due }));
  });
  it('exemption needs a reason and can be added once', async () => {
    await assertFails(updateDoc(doc(as('org1'), 'member_dues/2026-10_ama'), { exemptReason: '' }));
    await assertSucceeds(updateDoc(doc(as('org1'), 'member_dues/2026-10_ama'),
      { exemptReason: 'Approved by committee' }));
    await assertFails(updateDoc(doc(as('org1'), 'member_dues/2026-10_ama'),
      { exemptReason: 'Changed my mind' }));
  });
  it('the dues amount can never be edited, and dues are never deleted', async () => {
    await assertFails(updateDoc(doc(as('org1'), 'member_dues/2026-10_ama'), { amount: 1 }));
    await assertFails(deleteDoc(doc(as('org1'), 'member_dues/2026-10_ama')));
  });
});

describe('4. MoMo submission and verification', () => {
  it('payment + reference in one batch succeeds', async () => {
    const db = as('tre1');
    const b = writeBatch(db);
    b.set(doc(db, 'payments/p2'), momoPayment());
    b.set(doc(db, 'momo_references/MOMO2222'), { paymentId: 'p2', createdAt: ts() });
    await assertSucceeds(b.commit());
  });
  it('the same reference a second time is blocked', async () => {
    const db = as('tre1');
    const b = writeBatch(db);
    b.set(doc(db, 'payments/p3'), momoPayment({ reference: 'MOMO1111' }));
    b.set(doc(db, 'momo_references/MOMO1111'), { paymentId: 'p3', createdAt: ts() });
    await assertFails(b.commit());
  });
  it('a payment without its reference record is refused', async () => {
    await assertFails(setDoc(doc(as('tre1'), 'payments/p2'), momoPayment()));
  });
  it('lower-case or spaced references are refused', async () => {
    const db = as('tre1');
    const b = writeBatch(db);
    b.set(doc(db, 'payments/p2'), momoPayment({ reference: 'momo 2222' }));
    b.set(doc(db, 'momo_references/momo 2222'), { paymentId: 'p2', createdAt: ts() });
    await assertFails(b.commit());
  });
  it('zero, negative and decimal amounts are refused', async () => {
    for (const amount of [0, -5, 50.5]) {
      const db = as('tre1');
      const b = writeBatch(db);
      b.set(doc(db, 'payments/p2'), momoPayment({ amount }));
      b.set(doc(db, 'momo_references/MOMO2222'), { paymentId: 'p2', createdAt: ts() });
      await assertFails(b.commit());
    }
  });
  it('a new MoMo claim cannot start as verified', async () => {
    const db = as('tre1');
    const b = writeBatch(db);
    b.set(doc(db, 'payments/p2'), momoPayment({ status: 'verified', verifiedBy: 'tre1', verifiedAt: ts() }));
    b.set(doc(db, 'momo_references/MOMO2222'), { paymentId: 'p2', createdAt: ts() });
    await assertFails(b.commit());
  });
  it('the treasurer can verify; the organizer cannot', async () => {
    await assertFails(updateDoc(doc(as('org1'), 'payments/momo1'),
      { status: 'verified', verifiedBy: 'org1', verifiedAt: ts() }));
    await assertSucceeds(updateDoc(doc(as('tre1'), 'payments/momo1'),
      { status: 'verified', verifiedBy: 'tre1', verifiedAt: ts() }));
  });
  it('reject and need-info require a reason', async () => {
    await assertFails(updateDoc(doc(as('tre1'), 'payments/momo1'), { status: 'rejected' }));
    await assertFails(updateDoc(doc(as('tre1'), 'payments/momo1'), { status: 'needInfo' }));
    await assertSucceeds(updateDoc(doc(as('tre1'), 'payments/momo1'),
      { status: 'rejected', decisionReason: 'Transaction not found' }));
  });
  it('verified and rejected are final', async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await updateDoc(doc(ctx.firestore(), 'payments/momo1'),
        { status: 'rejected', decisionReason: 'No match' });
    });
    await assertFails(updateDoc(doc(as('tre1'), 'payments/momo1'),
      { status: 'verified', verifiedBy: 'tre1', verifiedAt: ts() }));
  });
  it('the amount can never change at verification', async () => {
    await assertFails(updateDoc(doc(as('tre1'), 'payments/momo1'),
      { status: 'verified', verifiedBy: 'tre1', verifiedAt: ts(), amount: 9000 }));
  });
  it('payments are never deleted', async () => {
    await assertFails(deleteDoc(doc(as('tre1'), 'payments/momo1')));
  });
  it('a reference record cannot be changed or deleted', async () => {
    await assertFails(updateDoc(doc(as('tre1'), 'momo_references/MOMO1111'), { paymentId: 'x' }));
    await assertFails(deleteDoc(doc(as('tre1'), 'momo_references/MOMO1111')));
  });
});

describe('5. Cash receipts and the counter', () => {
  it('payment + counter step in one batch succeeds', async () => {
    const db = as('org1');
    const b = writeBatch(db);
    b.set(doc(db, 'payments/cash1'), cashPayment(1, 'org1'));
    b.update(doc(db, 'counters/receipts'), { next: 2 });
    await assertSucceeds(b.commit());
  });
  it('a receipt number that does not match the counter is refused', async () => {
    const db = as('org1');
    const b = writeBatch(db);
    b.set(doc(db, 'payments/cash1'), cashPayment(2, 'org1'));
    b.update(doc(db, 'counters/receipts'), { next: 3 });
    await assertFails(b.commit());
  });
  it('a payment without moving the counter is refused', async () => {
    await assertFails(setDoc(doc(as('org1'), 'payments/cash1'), cashPayment(1, 'org1')));
  });
  it('the counter cannot jump or go back', async () => {
    await assertFails(updateDoc(doc(as('org1'), 'counters/receipts'), { next: 3 }));
    await assertFails(updateDoc(doc(as('org1'), 'counters/receipts'), { next: 0 }));
  });
  it('the same receipt number cannot be used twice', async () => {
    const db = as('org1');
    const first = writeBatch(db);
    first.set(doc(db, 'payments/cash1'), cashPayment(1, 'org1'));
    first.update(doc(db, 'counters/receipts'), { next: 2 });
    await assertSucceeds(first.commit());
    const again = writeBatch(db);
    again.set(doc(db, 'payments/cash2'), cashPayment(1, 'org1'));
    again.update(doc(db, 'counters/receipts'), { next: 3 });
    await assertFails(again.commit());
  });
  it('cash recorded under someone else\'s name is refused', async () => {
    const db = as('org1');
    const b = writeBatch(db);
    b.set(doc(db, 'payments/cash1'), cashPayment(1, 'org1', { recordedBy: 'tre1' }));
    b.update(doc(db, 'counters/receipts'), { next: 2 });
    await assertFails(b.commit());
  });
});

describe('6. Allocations', () => {
  const alloc = (paymentId, duesId, amount) => ({ paymentId, duesId, amount });

  it('allocation + payment counter in one batch succeeds', async () => {
    const db = as('org1');
    const b = writeBatch(db);
    b.set(doc(db, 'payment_allocations/pay1_2026-10_ama'), alloc('pay1', '2026-10_ama', 5000));
    b.update(doc(db, 'payments/pay1'), { allocatedTotal: 5000 });
    await assertSucceeds(b.commit());
  });
  it('an allocation without the counter update is refused', async () => {
    await assertFails(setDoc(doc(as('org1'), 'payment_allocations/pay1_2026-10_ama'),
      alloc('pay1', '2026-10_ama', 5000)));
  });
  it('allocating more than the payment is refused', async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await updateDoc(doc(ctx.firestore(), 'payments/pay1'), { allocatedTotal: 5000 });
    });
    const db = as('org1');
    const tooMuch = writeBatch(db);
    tooMuch.set(doc(db, 'payment_allocations/pay1_2026-11_ama'), alloc('pay1', '2026-11_ama', 3000));
    tooMuch.update(doc(db, 'payments/pay1'), { allocatedTotal: 8000 });
    await assertFails(tooMuch.commit());
    const fits = writeBatch(db);
    fits.set(doc(db, 'payment_allocations/pay1_2026-11_ama'), alloc('pay1', '2026-11_ama', 2000));
    fits.update(doc(db, 'payments/pay1'), { allocatedTotal: 7000 });
    await assertSucceeds(fits.commit());
  });
  it('a pending MoMo claim cannot be allocated', async () => {
    const db = as('org1');
    const b = writeBatch(db);
    b.set(doc(db, 'payment_allocations/momo1_2026-10_ama'), alloc('momo1', '2026-10_ama', 5000));
    b.update(doc(db, 'payments/momo1'), { allocatedTotal: 5000 });
    await assertFails(b.commit());
  });
  it('one allocation cannot exceed the dues amount', async () => {
    const db = as('org1');
    const b = writeBatch(db);
    b.set(doc(db, 'payment_allocations/pay1_2026-10_ama'), alloc('pay1', '2026-10_ama', 6000));
    b.update(doc(db, 'payments/pay1'), { allocatedTotal: 6000 });
    await assertFails(b.commit());
  });
  it('allocating to another member\'s dues is refused', async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'member_dues/2026-10_yaw'),
        { memberId: 'yaw', period: '2026-10', amount: 5000, dueDate: due });
    });
    const db = as('org1');
    const b = writeBatch(db);
    b.set(doc(db, 'payment_allocations/pay1_2026-10_yaw'), alloc('pay1', '2026-10_yaw', 1000));
    b.update(doc(db, 'payments/pay1'), { allocatedTotal: 1000 });
    await assertFails(b.commit());
  });
  it('allocations cannot be edited or deleted', async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'payment_allocations/pay1_2026-10_ama'),
        alloc('pay1', '2026-10_ama', 5000));
    });
    await assertFails(updateDoc(doc(as('org1'), 'payment_allocations/pay1_2026-10_ama'), { amount: 1 }));
    await assertFails(deleteDoc(doc(as('org1'), 'payment_allocations/pay1_2026-10_ama')));
  });
});

describe('7. Corrections', () => {
  const undoBatch = (uid, type, paymentId) => {
    const db = as(uid);
    const b = writeBatch(db);
    b.set(doc(db, `corrections/undo_${paymentId}`), correction(uid, type, paymentId));
    b.set(doc(db, `audit_logs/corr_undo_${paymentId}`), audit(uid, `correction_${type}`, paymentId));
    return b;
  };

  it('the treasurer can void a payment with its audit entry', async () => {
    await assertSucceeds(undoBatch('tre1', 'voidEntry', 'pay1').commit());
  });
  it('the organizer cannot make corrections', async () => {
    await assertFails(undoBatch('org1', 'voidEntry', 'pay1').commit());
  });
  it('a correction without an audit entry is refused', async () => {
    await assertFails(setDoc(doc(as('tre1'), 'corrections/undo_pay1'),
      correction('tre1', 'voidEntry', 'pay1')));
  });
  it('a correction needs a reason', async () => {
    const db = as('tre1');
    const b = writeBatch(db);
    b.set(doc(db, 'corrections/undo_pay1'), correction('tre1', 'voidEntry', 'pay1', { reason: '  ' }));
    b.set(doc(db, 'audit_logs/corr_undo_pay1'), audit('tre1', 'correction_voidEntry', 'pay1'));
    await assertFails(b.commit());
  });
  it('a payment cannot be voided or reversed twice', async () => {
    await assertSucceeds(undoBatch('tre1', 'voidEntry', 'pay1').commit());
    await assertFails(undoBatch('tre1', 'reversal', 'pay1').commit());
  });
  it('a pending claim can be voided but not reversed', async () => {
    await assertFails(undoBatch('tre1', 'reversal', 'momo1').commit());
    await assertSucceeds(undoBatch('tre1', 'voidEntry', 'momo1').commit());
  });
  it('once voided, nothing can be allocated to the payment', async () => {
    await assertSucceeds(undoBatch('tre1', 'voidEntry', 'pay1').commit());
    const db = as('org1');
    const b = writeBatch(db);
    b.set(doc(db, 'payment_allocations/pay1_2026-10_ama'),
      { paymentId: 'pay1', duesId: '2026-10_ama', amount: 5000 });
    b.update(doc(db, 'payments/pay1'), { allocatedTotal: 5000 });
    await assertFails(b.commit());
  });
  it('a payment with refunds cannot be reversed', async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await updateDoc(doc(ctx.firestore(), 'payments/pay1'), { refundedTotal: 1000 });
    });
    await assertFails(undoBatch('tre1', 'reversal', 'pay1').commit());
  });

  const refundBatch = (paymentId, id, amount, newTotal) => {
    const db = as('tre1');
    const b = writeBatch(db);
    b.set(doc(db, `corrections/${id}`), correction('tre1', 'refund', paymentId, { amount }));
    b.update(doc(db, `payments/${paymentId}`), { refundedTotal: newTotal });
    b.set(doc(db, `audit_logs/corr_${id}`), audit('tre1', 'correction_refund', paymentId));
    return b;
  };
  it('a refund within the unallocated credit succeeds', async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await updateDoc(doc(ctx.firestore(), 'payments/pay1'), { allocatedTotal: 5000 });
    });
    await assertSucceeds(refundBatch('pay1', 'ref1', 2000, 2000).commit());
  });
  it('a refund above the unallocated credit is refused', async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await updateDoc(doc(ctx.firestore(), 'payments/pay1'), { allocatedTotal: 5000 });
    });
    await assertFails(refundBatch('pay1', 'ref1', 2500, 2500).commit());
  });
  it('a refund id cannot imitate the undo id', async () => {
    await assertFails(refundBatch('pay1', 'undo_pay1', 1000, 1000).commit());
  });
  it('corrections are never edited or deleted', async () => {
    await assertSucceeds(undoBatch('tre1', 'voidEntry', 'pay1').commit());
    await assertFails(updateDoc(doc(as('tre1'), 'corrections/undo_pay1'), { reason: 'x' }));
    await assertFails(deleteDoc(doc(as('tre1'), 'corrections/undo_pay1')));
  });
});

describe('8. Expenses', () => {
  const step = (status, extra = {}) => ({
    status, lastActionBy: 'org1', lastActionAt: ts(), ...extra,
  });
  it('a new expense must be a draft with a positive amount', async () => {
    const base = {
      title: 'Water', category: 'supplies', amount: 6000, status: 'draft',
      refunded: 0, recordedBy: 'org1', createdAt: ts(),
    };
    await assertSucceeds(setDoc(doc(as('org1'), 'expenses/new1'), base));
    await assertFails(setDoc(doc(as('org1'), 'expenses/new2'), { ...base, status: 'paid' }));
    await assertFails(setDoc(doc(as('org1'), 'expenses/new3'), { ...base, amount: 0 }));
    await assertFails(setDoc(doc(as('org1'), 'expenses/new4'), { ...base, amount: 12.5 }));
  });
  it('follows draft -> submitted -> approved -> paid', async () => {
    await assertSucceeds(updateDoc(doc(as('org1'), 'expenses/exDraft'), step('submitted')));
    await assertSucceeds(updateDoc(doc(as('org1'), 'expenses/exSubmitted'), step('approved')));
    await assertSucceeds(updateDoc(doc(as('tre1'), 'expenses/exApproved'),
      { ...step('paid'), lastActionBy: 'tre1' }));
  });
  it('steps cannot be skipped', async () => {
    await assertFails(updateDoc(doc(as('org1'), 'expenses/exDraft'), step('paid')));
    await assertFails(updateDoc(doc(as('org1'), 'expenses/exDraft'), step('approved')));
  });
  it('paid and rejected are final', async () => {
    await assertFails(updateDoc(doc(as('org1'), 'expenses/exPaid'), step('approved')));
  });
  it('rejection needs a reason', async () => {
    await assertFails(updateDoc(doc(as('org1'), 'expenses/exSubmitted'), step('rejected')));
    await assertSucceeds(updateDoc(doc(as('org1'), 'expenses/exSubmitted'),
      step('rejected', { decisionReason: 'Not budgeted' })));
  });
  it('expense financial fields are immutable after creation', async () => {
    await assertFails(updateDoc(doc(as('org1'), 'expenses/exSubmitted'), { amount: 1 }));
    await assertFails(updateDoc(doc(as('org1'), 'expenses/exDraft'), { amount: 7000 }));
    await assertFails(updateDoc(doc(as('org1'), 'expenses/exPaid'), { refunded: 1000 }));
    await assertFails(updateDoc(doc(as('org1'), 'expenses/exPaid'), { refunded: 9000 }));
    await assertFails(updateDoc(doc(as('org1'), 'expenses/exApproved'), { refunded: 1000 }));
  });
  it('expenses are never deleted', async () => {
    await assertFails(deleteDoc(doc(as('org1'), 'expenses/exDraft')));
  });
  it('non-staff cannot touch expenses', async () => {
    await assertFails(getDoc(doc(as('stranger'), 'expenses/exDraft')));
    await assertFails(updateDoc(doc(as('stranger'), 'expenses/exDraft'), { amount: 1 }));
  });
});

describe('9. Audit log', () => {
  it('staff can append an entry under their own uid', async () => {
    await assertSucceeds(setDoc(doc(as('org1'), 'audit_logs/a1'), audit('org1', 'cash_recorded', 'pay1')));
  });
  it('an entry under someone else\'s uid is refused', async () => {
    await assertFails(setDoc(doc(as('org1'), 'audit_logs/a1'), audit('tre1', 'cash_recorded', 'pay1')));
  });
  it('entries cannot be edited or deleted', async () => {
    await assertSucceeds(setDoc(doc(as('org1'), 'audit_logs/a1'), audit('org1', 'cash_recorded', 'pay1')));
    await assertFails(updateDoc(doc(as('org1'), 'audit_logs/a1'), { reason: 'edited' }));
    await assertFails(deleteDoc(doc(as('org1'), 'audit_logs/a1')));
  });
});

describe('10. No deletes anywhere', () => {
  it('staff cannot delete any financial or member record', async () => {
    const targets = [
      'members/ama', 'dues_periods/2026-10', 'member_dues/2026-10_ama', 'payments/pay1',
      'momo_references/MOMO1111', 'counters/receipts', 'expenses/exDraft',
    ];
    for (const path of targets) {
      await assertFails(deleteDoc(doc(as('tre1'), path)));
    }
  });
});
