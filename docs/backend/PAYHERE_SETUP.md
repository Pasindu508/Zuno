# Zuno – PayHere setup

Zuno takes card / mobile-wallet payments through PayHere's Checkout API for three order
kinds: `ticket` (paid events), `wallet_topup` (LKR 100.00 – 50,000.00) and
`event_creation_fee` (LKR 1,000.00 per published event). Free-event fees beyond the monthly
allowance are paid from the Zuno wallet and never touch PayHere.

## 1. Flow

```
iOS app ──POST /functions/v1/payhere-checkout──▶ create_payment_order (DB prices, reserves stock,
   │                                              pending order, expires_at = now + 15 min)
   │◀── { order_id, summary, checkout: { action_url, method: "POST", fields{..., hash} } }
   │
   ├── WebView POSTs `fields` to action_url (PayHere hosted checkout)
   │
PayHere ──POST notify_url (form)──▶ payhere-notify ──verify md5sig──▶ apply_payhere_notification
   │                                   (idempotent; amount/currency must match; tickets issued,
   │                                    top-ups posted, creation fee marked ONLY here)
   └── browser ──GET return_url──▶ payhere-return ──302──▶ zuno://payments/return?order_id=…
                                   (informational only; the app reads the order status
                                    from `orders` / Realtime, never trusts the redirect)
```

## 2. Merchant account

1. Create a **sandbox** merchant at <https://sandbox.payhere.lk> and a live merchant at
   <https://www.payhere.lk> after business verification.
2. In each merchant portal: *Settings → Domains & Credentials* → add the app/domain and copy the
   **Merchant ID** and **Merchant Secret** (the secret is per domain/app).
3. Store them as Edge Function secrets (never in the repo or the iOS app):

   ```bash
   supabase secrets set PAYHERE_MERCHANT_ID=<id> PAYHERE_MERCHANT_SECRET=<secret> PAYHERE_MODE=sandbox
   ```

   `PAYHERE_MODE=live` switches `action_url` from `https://sandbox.payhere.lk/pay/checkout` to
   `https://www.payhere.lk/pay/checkout`. Sandbox and live use different merchant ids/secrets.

## 3. URLs

| Field | Default value | Override |
|---|---|---|
| `notify_url` | `<SUPABASE_URL>/functions/v1/payhere-notify` | `PAYHERE_NOTIFY_URL` |
| `return_url` | `<SUPABASE_URL>/functions/v1/payhere-return?order_id=<id>` | `PAYHERE_RETURN_URL` |
| `cancel_url` | `return_url` + `&cancelled=1` | – |

PayHere must reach `notify_url` over the public internet, so sandbox payments against a local
`supabase start` stack will not be confirmed unless you expose it (e.g. a tunnel) and set
`PAYHERE_NOTIFY_URL`. `payhere-notify` and `payhere-return` are deployed with
`verify_jwt = false` (PayHere sends no Supabase JWT).

## 4. Hash formulas

All amounts are formatted from integer minor units with integer arithmetic:
`150000` → `"1500.00"` (two decimals, no thousands separator).

**Checkout hash** (sent in the form as `hash`):

```
hash = UPPER( MD5( merchant_id + order_id + amount + currency + UPPER(MD5(merchant_secret)) ) )
```

**Notification signature** (`md5sig`, verified by `payhere-notify` in constant time):

```
md5sig = UPPER( MD5( merchant_id + order_id + payhere_amount + payhere_currency
                     + status_code + UPPER(MD5(merchant_secret)) ) )
```

`payhere_amount` is used exactly as received. Implementation:
`supabase/functions/_shared/payhere.ts`; MD5 comes from `jsr:@std/crypto`. Unit tests check
both formulas against vectors computed independently with Python's `hashlib`
(`_shared/payhere_test.ts`).

## 5. What `payhere-notify` verifies, in order

1. Form-encoded body with `merchant_id, order_id, payhere_amount, payhere_currency, status_code, md5sig`.
2. `merchant_id` equals `PAYHERE_MERCHANT_ID`, then `md5sig` (constant-time compare) — any
   failure → **400 `invalid_signature`**, nothing reaches the database.
3. `order_id` is a UUID, `payhere_amount` parses exactly into minor units, `status_code` is an integer.
4. `apply_payhere_notification` (service role only) locks the event then the order and:
   * **duplicate** `(payment_id, status_code)` → no-op, **200 `ok`** (PayHere stops retrying);
   * amount or currency ≠ the order total → payment row recorded with outcome
     `rejected_amount_mismatch`, order untouched, **400 `amount_mismatch`**;
   * `2` success: pending order → reservation converted to sales, paid registration + one
     ticket per unit, `payment_status` + `ticket_issued` notifications; top-up → pending ledger
     entry posted (balance credited); creation fee → `events.creation_fee_paid_at`;
   * `0` pending: recorded only;
   * `-1` cancelled / `-2` failed on a pending order → order closed, reservations released,
     pending top-up ledger entry marked `failed`, buyer notified;
   * `-3` chargeback on a paid ticket order → tickets `refunded`, inventory returned; other
     kinds are flagged `chargeback_manual_review`.
5. Stored notification payloads are allow-listed (`merchant_id, order_id, payment_id,
   payhere_amount, payhere_currency, status_code, status_message, method, captured_amount,
   recurring`) — card number, card holder name, expiry and `md5sig` are dropped both in the
   function and again in SQL.

Unknown order → 404; database errors → 500 (PayHere may retry; processing is idempotent).

## 6. Edge cases and refunds

| Situation | Behaviour |
|---|---|
| Payment succeeds after the 15-minute hold expired | Fulfilled if the tier/event still has stock; otherwise the full amount is credited to the buyer's Zuno wallet (`refund_credit`) and the order is `refunded`. |
| Payment succeeds for an event that was cancelled / has ended | Credited to the wallet (`refunded_event_unavailable`). |
| Second creation-fee payment for the same event | Credited to the wallet (`refunded_duplicate_fee`). |
| Organizer cancels an event (`cancel_event`) | Every paid ticket order is refunded to the buyer's wallet in full; pending checkouts are cancelled and their holds released. |
| Second *successful* payment on an already paid order (different payment id) | Recorded as `already_paid_manual_review`; refund it from the PayHere portal. |
| Buyer deleted their account before PayHere confirmed | Order marked paid with `status_reason = user_deleted`; refund manually. |

Refunds to the **original card** are not automated: PayHere's merchant (refund) API needs
separate API credentials that are out of scope for v1. Zuno refunds to the wallet; card refunds for the cases above
are an operator task in the PayHere portal. Organizer payouts (`event_settlements`) are tracked
with status `unsettled | scheduled | paid` and settled outside the app; commission is
`(subtotal × commission_bps + 5000) / 10000` (integer, half-up) per order.

## 7. Verified vs credential-dependent

Verified locally (see `VERIFICATION.md`):
* hash and md5sig formulas against independent vectors; amount formatting/parsing;
* notify handler: signature rejection, merchant mismatch, duplicate → 200, mismatch → 400,
  unknown order → 404, sanitising of card fields (with an injected fake database);
* checkout handler: request validation and the exact `fields` set + hash (fake database);
* all database behaviour (pricing, commission rounding, reservations, expiry, idempotency,
  fulfilment, refunds) on PostgreSQL 17.

Not verified (needs real credentials / network): a real sandbox payment end to end, PayHere
actually reaching `notify_url`, PayHere's handling of the `return_url` query string, the field
set accepted by the hosted checkout page for every payment method, and live mode.
Run one sandbox purchase of each order kind (sandbox test cards are listed in the PayHere
docs) before going live.
