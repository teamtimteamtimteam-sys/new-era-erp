# Fresh install checklist

Standing up a new Evoltrya OS project from this repository.

> This file records the agreed order so it is not carried around in someone's head.
> Step 2 is verified by `python3 db/verify_rebuild.py`; step 4 is deliberately manual
> (see "Known gaps").

## The checklist

1. **Create the Supabase project.** Note two things you will need and cannot guess:
   - **The database connection string.** Dashboard → Project Settings → Database →
     *Connection string* → **Session pooler**. The pooler hostname is **per project**
     (`aws-0-…` and `aws-1-…` both occur) — copying it from another project fails to
     connect. The password is the one set at project creation; it is not recoverable
     later, so record it now.
   - **The API keys** (Project Settings → API): the `anon` key and the `service_role`
     key. Step 8 needs both.
2. **Run the rebuild** — `db/platform-prelude.sql`, then `db/functions/`, then
   `db/tables/` in dependency order, then `db/views/`. See the prelude's header for
   the exact procedure and the two caveats (the missing trailing semicolons, and the
   platform objects the mirrors do not contain).

   `python3 db/verify_rebuild.py --target "<dsn>" --skip-diff` does exactly this.
   Use `--skip-diff` here: there is nothing to compare a brand-new project against.

   **Do not run `db/platform-prelude.sql` against a real Supabase project.** The
   platform already provides the `auth` schema, `auth.users`, `auth.uid()`, the three
   roles and the default privileges, and the `auth` schema is owned by
   `supabase_auth_admin` — so the prelude fails with `permission denied for schema
   auth`. `verify_rebuild.py` detects this and skips the prelude automatically; the
   prelude exists for rebuilding onto bare PostgreSQL.

   **Expect this step to take about nine minutes** against a remote project — it
   replays 92 functions, 73 tables and 38 views over the network.
3. **Run any C0.5 scripts.** *Currently none* — every intended default is expressible
   as a bootstrap seed and is applied by step 2. If that ever stops being true, the
   script's invocation goes here.
4. **Grant the first admin.** Until this runs, `user_roles` is empty, every RLS
   policy denies, and nobody can read anything — including the person trying to fix
   it. There is deliberately **no script** for this: it runs exactly once per
   database, and a permanent artefact for a one-time event is the thing we removed
   when `grant_annual_leave` was deleted rather than kept as a spare part.

   **Prerequisite — the auth user must exist first.** The snippet below reads
   `auth.users`; if no user has been created it will grant nothing and the install
   will look finished while being unusable. Create the account before running it:

   * Dashboard → **Authentication** → **Users** → **Add user** → *Create new user*.
     Give it the real email address of whoever will administer the system, set a
     password, and tick *Auto Confirm User* (there is no mail configured yet).

   **Finding the UUID.** The snippet does not need you to type it — it reads every
   row of `auth.users` — but you should confirm exactly one row exists and that it
   is the right person before running it. Either:

   * Dashboard → Authentication → Users → click the user → the **UID** field; or
   * SQL editor:
     ```sql
     SELECT id, email, created_at FROM auth.users ORDER BY created_at;
     ```

   **Then run, in the SQL editor:**
   ```sql
   -- Grants every existing auth user the admin role. On a fresh install that is
   -- exactly one person. ON CONFLICT makes re-running harmless -- without it the
   -- second run fails on idx_user_roles_active (the data is safe either way, but a
   -- checklist you may have to restart should not throw a duplicate-key error).
   INSERT INTO user_roles (user_id, role_id)
   SELECT u.id, (SELECT id FROM roles WHERE code = 'admin')
   FROM auth.users u
   ON CONFLICT (user_id, role_id) WHERE revoked_at IS NULL DO NOTHING;

   -- Confirm. Zero rows here means the step silently did nothing — go back and
   -- create the auth user first.
   SELECT u.email, r.code
   FROM user_roles ur
   JOIN roles r ON r.id = ur.role_id
   JOIN auth.users u ON u.id = ur.user_id
   WHERE ur.revoked_at IS NULL;
   ```
   If the second query returns no rows, **stop** — the prerequisite was not met.
5. **Verify login.**
6. **Disable public signup** in Supabase Auth.
7. **Enter the per-install values** (these cannot be seeded — they are this company's
   data, not a design default).

   **How:** by SQL in the dashboard's SQL editor. The app's own pages for this
   (`/finance/company`, `/finance/settings`) are not reachable yet — the deployment is
   only configured in step 8 — so this step cannot be done through the UI in checklist
   order. Either run the SQL now, or do this step after step 8 through the app.
   The rows already exist (the bootstrap seeds one empty row of each); this is an
   `UPDATE`, not an `INSERT`.
   - `company_profile` — legal name, registration number, address, city, postal code,
     country, phone, email, website, logo, invoice footer text.
   - `company_profile` banking — bank name, account name, account number, SWIFT,
     bank address. These print on invoices.
   - `finance_settings` — GST registration number and rate, **once the company is GST
     registered**. The seeded default is "not registered, 0%", which is the correct
     starting state, not a placeholder to be overwritten immediately.
   - `hr_settings` — only if this company's figures differ from the seeded defaults
     (medical limit SGD 1,000, 5-day week, 12-month carry-forward).
8. **Update Vercel environment variables** — `NEXT_PUBLIC_SUPABASE_URL`
   (`https://<ref>.supabase.co`), `NEXT_PUBLIC_SUPABASE_ANON_KEY`, and
   `SUPABASE_SERVICE_ROLE_KEY`. These are the only three the application reads.
   Redeploy afterwards: Vercel does not rebuild on an environment-variable change.

## What step 2 already gives you

The bootstrap defaults are the *intended design*, not a snapshot of any particular
install. After step 2 a fresh database has:

| | |
|---|---|
| permission catalog | 33 codes (INSTALL SEED, row-compared) |
| chart of accounts | the 22 engine-referenced accounts (INSTALL SEED, row-compared) |
| currencies | SGD, USD (INSTALL SEED, row-compared) |
| roles | the nine working roles + the retained inert `employee` row |
| role grants | 159, separation of duties intact, `edit` always paired with `view` |
| leave types | the 13 handbook types |
| public holidays | 2026, 14 days |
| review rating scale | 4 levels |
| leave accrual rates | office 24 / shopfloor 18 days per year |
| HR settings | medical SGD 1,000, 5-day week, 12-month carry-forward |

Everything above is applied by plain `INSERT` during the replay, so **step ordering
inside step 2 is handled by the mirror toposort** — `permissions` (22) and `roles` (27)
both replay before `role_permissions` (51). No manual ordering is required.

## Verified

Walked end to end against a real throwaway Supabase project on 2026-08-02 (created,
walked, deleted). Steps 1–7 execute as written. The end state was:
10 role rows / 159 grants / 33 permission codes / 22 system accounts / office 24 and
shopfloor 18 accrual; the first admin logged in; `/hr/employees`,
`/settings/permissions`, `/finance` and `/me` all rendered for that session while an
unauthenticated request to `/hr/employees` redirected to `/login`; and after step 6 a
second signup was refused with *"Signups not allowed for this instance"*.

**Step 8 has not been executed against a real deployment** — no Vercel credentials were
available. It is the only step in this document that has never been run.

## Known gaps

- **There is deliberately no first-admin script.** Step 4 is a manual paste, by
  decision rather than by omission — it runs once per database. `db/tables/user_roles.sql`
  explains the trap in a comment and points here for the executable form, so the two
  cannot drift apart. `guard_last_admin` protects the *last* admin from removal;
  nothing creates the *first* one, and nothing should.

## 引导默认值里的"时点状态"—— 全量清点(2026-08-05)

**问题**:RUNTIME CONFIG 表的引导值是【新公司第一天】应有的样子,还是不小心把
本环境某一刻的状态固化进去了?后者会让全新安装继承一段与它无关的历史。

逐张核对的结果:

| 表 | 引导值 | 判断 |
|---|---|---|
| `finance_settings` | `locked_before = NULL` | ✅ **正确** —— 新公司没有已关的期间,不该继承任何锁位。(线上此刻是 2026-08-01,那是操作员推月结推出来的【实时状态】;`check_mirrors` 刻意不比对 RUNTIME CONFIG 的行,所以它进不了镜像。) |
| `public_holidays` | **只有 2026 年的 14 条** | ⚠️ **唯一一处真正的时点状态**,见下 |
| `company_profile` | `legal_name = ''` | ✅ 空占位,等操作员填 |
| `hr_settings` | 只有政策数字(医疗额度 1000、每周 5 天、结转 12 个月) | ✅ 政策默认,与时间无关 |
| `leave_accrual_rates` | office 24 / shopfloor 18,`effective_from = 2000-01-01` | ✅ 刻意取很早的生效日,意为"一直如此" |
| `leave_types` / `review_rating_scale` / `roles` / `role_permissions` | 定义类 | ✅ 稳定 |

**没有第三处。**

### `public_holidays` —— 以及一个比引导值更要紧的缺口

假日表只播了 2026 年。它是承重的:`calculate_leave_days` 用它算请假天数,
`fx_rate_asof` 用它判断哪天不发布牌价。

于是【在 2026 年之后做全新安装】会得到:2027 年的每一个公共假日都被当成工作日,
请假天数**静默算错**(FX 那边则会拒绝,吵但看得见)。

**而现有的 `holiday_calendar_missing` 告警补不上这个洞** —— 它只在
【10 月及以后】检查【下一年】。2027 年 3 月做的全新安装:当年缺假日,没有任何告警;
到 10 月它才开始提醒 2028 年,而 2027 全年的请假天数早已算错。

处置(尚未实施,需要自己的切次):
1. 全新安装的**第 N 步**加一条:进"假期 → 公共假日"录入**当年及次年**的假日;
2. 或把 `hr_alerts` 的 `holiday_calendar_missing` 改成同时检查【当年】(任何月份)
   与【次年】(10 月起)。第 2 条更稳,因为它不依赖有人照着清单做。

