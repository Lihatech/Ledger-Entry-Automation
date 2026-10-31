# Plant Acceptance Test Plan

Use this checklist with realistic users, machines, parts, shifts, templates, and inventory data before plant handover. Record the tester, date, environment, test data IDs, result, and evidence for every case.

## Test roles and data

- Admin, supervisor, quality engineer, calibrator, operator, inspector, and unauthorized user.
- At least two plants, two machines, two parts, two shifts, one JH checklist, one first-piece template, one PDI template, one calibration instrument, and one approved and one draft document.
- Use separate test accounts and never use production passwords in screenshots or test notes.

## Critical end-to-end scenarios

| ID | Scenario | Expected result |
| --- | --- | --- |
| E2E-01 | Submit a JH checklist, correct a rejected item, and resubmit | Corrected values are retained; approval history is preserved; duplicate rows are not created. |
| E2E-02 | Retry a first-piece inspection after a validation failure and after a network interruption | The user can resume safely; only one reading/report is stored per request key. |
| E2E-03 | Supervisor approves and rejects an inspection/report | Only authorized supervisors can act; status, remarks, timestamps, and notifications are correct. |
| E2E-04 | Create, submit, review, and finalize a PDI report | Required readings and unique sample/parameter constraints are enforced. |
| E2E-05 | Receive inventory, dispatch it, and link production output | Quantities reconcile; plant and part isolation prevents cross-plant access. |
| E2E-06 | Upload, preview, download, and reject a calibration certificate | File validation, permissions, audit entries, and download content are correct. |
| E2E-07 | Upload, approve, revise, and obsolete a controlled document | Draft/unapproved visibility and role permissions are respected at every step. |
| E2E-08 | Create a group, change membership, send/edit/delete messages, and transfer admin | Only permitted users can perform each action; all clients receive consistent updates. |
| E2E-09 | Operate with intermittent connectivity and reconnect | No silent data loss; retry-safe requests either return the original result or a clear conflict. |
| E2E-10 | Double-tap every submit/approve/dispatch action | Exactly one business record is created. |
| E2E-11 | Change shifts during active work | Existing records remain attributed correctly; new work follows the new shift. |
| E2E-12 | Access another plant's machine, report, inventory, and document IDs | The API returns 404/403 and does not disclose the other plant's data. |

## Evidence required

For each failed case, capture the request ID/idempotency key, user role, URL/API route, server log timestamp, database record count before/after, and a redacted screenshot. Do not attach JWTs, passwords, cloud tokens, or private URLs.

## Release gate

All E2E cases must pass for the target plant. Any failed case involving duplicate creation, cross-plant access, unauthorized approval, lost inspection data, or unsafe file upload blocks handover until corrected and retested.
