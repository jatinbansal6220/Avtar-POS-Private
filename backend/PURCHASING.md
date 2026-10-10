# Purchasing ledger

The new Purchasing screen uses three additive resources: `purchase_suppliers`,
`purchase_bills`, and `purchase_events`. Existing single-item `purchases` and the
physical kitchen-item Inventory module keep their existing contracts and data.

After pulling this commit on the VPS, run the normal Laravel deployment steps,
including `php artisan migrate --force`. The new migration only creates ledger
tables and adds a nullable `reorder_levels` JSON field to purchase items. Do not
run `migrate:fresh` or reset the production database. Deploy the API before
releasing clients that use the new resources.

Bills move from draft to ordered/received/cancelled. Receipt posts material stock;
received and cancelled bills are immutable. Purchase events record additional
payments, refunds, returns, opening stock, consumption, and wastage. No automatic
bank transfer or supplier notification occurs. Stock quantities use thousandths,
money uses paise, GST uses basis points, and dates follow Asia/Kolkata.

Returns reference original invoice lines. Cumulative rounding prevents repeated
partial returns from generating excess supplier credit. Freight is a separate,
non-taxed, non-returnable charge. Payment/refund limits are validated against
the authoritative ledger inside the existing tenant-locked idempotent mutation
transaction. Material stock remains nonnegative on the action date and on later
ledger dates. Only owners/managers can read, write, or sync these resources.

Older purchases remain in Legacy history; their untracked credit balances are
not silently imported into supplier accounts. Analytics combines their spend
with received ledger bills and subtracts return credits, without duplicating
purchase entries. Raw-material consumption must be recorded by staff with
manager access; selling a menu dish does not infer ingredient usage or recipes.

Verification:

* `php vendor/bin/phpunit tests/Feature/PurchaseLedgerTest.php` uses isolated
  in-memory SQLite and excludes the existing MySQL-only terminal-index migration.
* Flutter purchase-ledger tests cover arithmetic, stock, payment limits, offline
  outbox persistence, invoice duplication, posting, returns, mobile layout, and
  the draft → receive → payment → return screen flow.
