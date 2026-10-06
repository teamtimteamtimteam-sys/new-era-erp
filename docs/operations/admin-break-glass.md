# Admin break-glass recovery

**Kept by:** Tim. **Written by:** U1-B (`v1.4.36`, 2026-10-05), UNBLOCK-1 Q18.

## When this procedure applies

Only the `admin` role holds `action.manage_permissions`, the one code that grants roles in the application. One person holds
it: `admin@` and `tim@` are the same person. This procedure does not add a second holder; it is the recovery path when that
person cannot reach the application as an administrator.

It applies when every one of the following is true:

- no confirmed, enabled account holds an unrevoked `admin` grant that its owner can sign in with; and
- the cause is not a forgotten password alone. A forgotten password is recovered by a password-recovery email sent from the
  Supabase dashboard (Authentication → Users → the account → Send password recovery); the login page has no reset link.
  That path changes no role and needs nothing below.

It does not apply to granting any other role. Every other grant is made in the application by the administrator, at
`/settings/accounts`, and is recorded there.

## What is needed

- The database credential in `~/.pgpass` on the operator's machine (host `aws-1-ap-southeast-1.pooler.supabase.com`, port 5432,
  user `postgres.wvywpohbwkiinmipmuku`). It is held outside the repository and only by the keeper of this procedure.
- `psql` on the operator's machine.
- The email address of the account that is to hold `admin` again. The account must already exist and its email must be
  confirmed. This procedure never creates an account.

The connection runs as `postgres`, which bypasses row-level security. Every statement below is therefore unchecked by the
application's permission rules; each one is written so that it changes exactly one thing and can be read back.

## Procedure

Connect:

```
psql "host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 dbname=postgres user=postgres.wvywpohbwkiinmipmuku sslmode=require"
```

### 1 · Read the state

```sql
SELECT u.id, u.email, u.confirmed_at IS NOT NULL AS confirmed,
       u.banned_until, u.deleted_at
  FROM auth.users u
 WHERE u.email = '<email>';

SELECT * FROM real_role_grants('admin');
```

`real_role_grants('admin')` lists the grants that count as a real administrator (unrevoked, confirmed, not banned, not deleted).
If it returns a row whose owner can sign in, stop: this procedure does not apply.

### 2 · If the account is disabled, enable it

```sql
BEGIN;
UPDATE auth.users SET banned_until = NULL WHERE email = '<email>' AND banned_until IS NOT NULL;
-- exactly one row: UPDATE 1
COMMIT;
```

### 3 · Grant `admin` to the account

```sql
BEGIN;
INSERT INTO user_roles (user_id, role_id, granted_by)
SELECT u.id, r.id, NULL
  FROM auth.users u, roles r
 WHERE u.email = '<email>' AND r.code = 'admin'
   AND NOT EXISTS (SELECT 1 FROM user_roles ur
                    WHERE ur.user_id = u.id AND ur.role_id = r.id AND ur.revoked_at IS NULL);
-- exactly one row: INSERT 0 1
SELECT * FROM real_role_grants('admin');
-- the account appears
COMMIT;
```

A grant is never made by un-revoking an old row: revocations are records (`revoked_at / revoked_by / revoke_reason`) and stay
as they are.

### 4 · Read back in the application

The account's owner signs in, opens `/settings/accounts`, and sees the account with the role `admin`. The grant also appears
in the change log as a `user_roles` insert by **System (automatic)**, because a write with no login has no person.

### 5 · Record

Add one line to `docs/known-issues.md` under a heading naming the date, the account, which steps (2 and/or 3) were run and why.
A break-glass grant that is not written down is indistinguishable from a ghost grant (`GHOST-GRANTS`).

## What this procedure never does

- It never creates, deletes or renames an account, and never sets a password.
- It never grants any role other than `admin`, and never changes `role_permissions`.
- It never deletes a `user_roles` row and never clears `revoked_at`.
- It never runs while another grant of `admin` still counts as real (step 1).
