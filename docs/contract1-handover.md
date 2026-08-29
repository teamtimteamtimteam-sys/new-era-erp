# CONTRACT-1 交接:库已经改了,代码还没提交 —— 从这份文件就能把它做完

**写于 2026-08-30。写它的那次会话在这一步停住了**(工具侧的安全分类器持续不可用,
跑不了 types:gen / gate / build / smoke)。**这份文件的目标:一个全新的会话
只读它就能把这一刀收尾,不必回头翻对话。**

---

## 一 · 最要紧的一句:破窗从 **2026-08-30 00:11:20 CST** 起,至今未闭

**线上库已经是新的,而代码一行都没提交、没推送。**

### 它为什么【功能上无害】

本刀的迁移**只加不删**:

* 新表:`contracts`、`contract_grade_specs`、`contract_insurance_obligations`、
  `contract_volume_commitments`、`contract_document_terms`
* 新列:`purchase_orders.contract_id`、`sales_orders.contract_id`(**都可空**)
* `purchase_orders_masked` **在末尾追加**一列(`CREATE OR REPLACE`,列序未变)
* `certificate_types` 插入一行 `insurance`(`ON CONFLICT DO NOTHING`)
* 新函数:`link_document_to_contract`、`assign_contract_code`
* 新视图:`contract_grade_breaches`、`contract_coverage`

**没有 DROP、没有 RENAME**。线上跑着的旧代码不认识 `contracts`,
而多出来的一列对"按列名 select"的旧查询无影响 —— 所以**生产此刻没有任何东西是坏的**。

### 它为什么【仍然必须闭上】

这是 AGENTS.md 记着的那条:**库是共享的,应用不是**。窗口开着的时候
"线上库"与"仓库"是两个不同的事实,而下一个人无从知道哪一个是准的。
**闭窗的动作就是把代码推上去。**

---

## 二 · 已经落到线上的四支迁移(全部 committed atomically)

| 时刻(CST) | 文件 | 内容 |
|---|---|---|
| 00:11:20 | `db/migrations/2026-08-30-contract1-the-contract-register.sql` | 主迁移(上面那一整套) |
| 00:24:31 | `db/migrations/2026-08-30-contract1-fu1-null-material-needs-its-own-unique.sql` | 修一处**本刀 fixture 自己抓到的缺陷**,见第五节 |

> 备份在动库【之前】跑完并验过:`BACKUP_EXIT=0`,
> `evoltrya-backup-2026-08-29-2028.dump`,`pg_restore --list` 退 0、**4624 条 TOC**。

---

## 三 · 仓库里【写了但没提交】的东西(`git status` 约 21 项)

**新增**

* 表镜像:`db/tables/contracts.sql`、`contract_grade_specs.sql`、
  `contract_insurance_obligations.sql`、`contract_volume_commitments.sql`、
  `contract_document_terms.sql`
* 函数镜像:`db/functions/link_document_to_contract.sql`
* 视图镜像:`db/views/contract_grade_breaches.sql`、`db/views/contract_coverage.sql`
* 迁移:上面那两支
* fixture:`db/fixtures/147-a-document-copies-the-terms-in-force-and-the-contract-can-change-after.sql`
* 拼装脚本:`db/scripts/build_contract_migration.py`
* 页面:`app/contracts/page.tsx`

**修改**

* `db/tables/purchase_orders.sql` / `db/tables/sales_orders.sql` —— 末尾加 `contract_id` 列;
  采购单那张的列授权清单里也加了它
* `db/views/purchase_orders_masked.sql` —— 末尾加 `contract_id`
* `db/tables/certificate_types.sql` —— 引导种子多一行 `insurance`
* `messages/en.ts` / `messages/zh.ts` —— 新增 `contracts.*` 一整段(含 `errors.*` 九条)
* `lib/modules.ts` —— `/contracts` 挂进 suppliers 模块的 `alsoCovers`

---

## 四 · ★ 构建【现在会红】,红在哪 ★

```
app/contracts/page.tsx(44,29): error TS2769  Argument of type '"contracts"' is not assignable…
app/contracts/page.tsx(48,45): error TS2769  Argument of type '"contract_coverage"' is not assignable…
```

**原因:迁移落地之后 `lib/database.types.ts` 没有重新生成。** 那份类型文件是
schema 的另一份镜像(OPS-10),库里有了新表而它不知道。

**修法就是第六节第 1 步。** 注意 AGENTS.md 那条:`types:gen` 读的是 PostgREST 的
schema 缓存,不是 `pg_catalog` —— 所以**先 `NOTIFY pgrst, 'reload schema';` 再等十几秒**。

---

## 五 · ★ 两条【注入没跑过】的臂 —— 不要把 fixture 147 的绿当成已证明 ★

**fixture 147 本身是绿的**(在线上以回滚事务跑过,七个臂 A–G 全过,
外加一处内嵌注入)。**但下面这两处外部注入【写好了却一次都没运行】**,
所以那两条臂目前只是"安静",不是"管用"。

### 注入 C —— 把【抄】退化成【引用】

装一个"改合同就同步到抄件"的触发器(引用式实现的等价效果),
**C 臂应当当场红**。构造:在 fixture 的 `def_link := pg_get_functiondef` 那一行【之前】插入:

```sql
    EXECUTE $inj$
      CREATE OR REPLACE FUNCTION zz147_leak() RETURNS trigger LANGUAGE plpgsql AS $f$
      BEGIN
        UPDATE contract_document_terms SET contract_title = NEW.title, incoterm = NEW.incoterm,
               currency = NEW.currency, payment_terms_days = NEW.payment_terms_days
         WHERE contract_id = NEW.id;
        RETURN NEW;
      END $f$;
    $inj$;
    EXECUTE 'CREATE TRIGGER zz147_leak_trg AFTER UPDATE ON contracts
             FOR EACH ROW EXECUTE FUNCTION zz147_leak()';
```

期望:`FIXTURE 147C 失败:★ 改了合同之后,已挂单据抄下的条款变了 ★`

### 注入 B —— 把"合同必须 active"那条拒绝短路掉

同一位置插入:

```sql
    EXECUTE replace(pg_get_functiondef('public.link_document_to_contract(text,uuid,uuid)'::regprocedure),
        'IF v_con.status <> ''active'' THEN', 'IF false THEN');
```

期望:`FIXTURE 147B 失败:草稿合同应当按名拒`

> **两处都要先断言"注入真的改了东西"** —— 一个什么都没删的注入,
> 长得和一个通过了的注入一模一样(fixture 77 为此红过一次)。

### 顺带:fu1 修的是什么(它是 fixture 自己抓到的)

`UNIQUE (contract_id, material_id, metal)` 在 `material_id` 为 NULL 时**不咬** ——
唯一索引里 NULL ≠ NULL。而"不指料号、只写 Ni ≥ 18%"恰恰是合同里**最常见**的写法。
于是同一份合同可以同时存在 Ni≥18 与 Ni≥20 两行,"哪一条说了算"变成按写入顺序破平局 ——
**正是该表注释声称躲开的那个坑(AGING-1)**。fu1 拆成两个部分唯一索引。

---

## 六 · 剩下的步骤,**按这个顺序**

1. **重生成类型**(第四节的红就是它)
   ```
   psql "<DSN>" -X -q -c "NOTIFY pgrst, 'reload schema';"   # 然后等 ~25 秒
   npm run types:gen
   npx tsc --noEmit -p tsconfig.json      # 期望:无输出
   ```
2. **跑上面两处注入**(第五节),确认两条臂各自红在该红的地方,然后**把注入文件删掉**。
3. **`python3 db/gate.py`**(经 `db/run_detached.sh`,上限从实测推:gate 区间 130–483s,取 2700s)。
   期望 `GATE_EXIT=0`,三判词全绿,fixture 数 **146**。
   > **【这一行原本写错了,2026-08-30 实测更正】** 原文写「147(146 + 本刀新增 1)」,
   > 把 fixture 的**编号**当成了**个数**:本刀之前 `git ls-files db/fixtures/*.sql`
   > 是 **145** 支,加本刀这一支 = **146**。实测 gate 跑了 146 支、全绿,
   > 其中包括 `147-a-document-copies-the-terms-in-force-...`。
   > 若镜像判词红:先看 `purchase_orders` / `sales_orders` / `purchase_orders_masked` /
   > `certificate_types` 四份镜像是否与线上一致 —— 本刀改的就是它们。
4. **`npm run build`** —— 期望 `BUILD_EXIT=0`,九道检查全绿。
   > `check-masked-reads` 可能会咬:`/contracts` 页读的是 `contracts` 与
   > `contract_coverage`(都不是遮蔽表),但如果将来加了读 `purchase_orders` 的查询,
   > 要改成 `purchase_orders_masked`。
5. **冒烟** `node scripts/smoke-routes.mjs`(上限 3000s;实测 ~17 分)。
   期望 `SMOKE_EXIT=0`,路由数比上一次多 1(新增 `/contracts`)。
6. **补完没做的部分**(第七节),然后**一次提交、一次推送**,
   等 `scripts/wait-for-deploy.sh` 给出 `DEPLOY_EXIT=0` —— **窗口在那一刻闭合**,
   把"00:11:20 → 部署 success"的时长写进切次报告。

---

## 七 · 【没做完】的部分,按重要性排

1. ★ **`/contracts` 没有任何导航入口。** 页面写好了、也挂进了 `lib/modules.ts` 的
   `alsoCovers`,但**没有一条链接指向它** —— 本仓库为「页面上线却走不到」付过两次账
   (SAL-B6、FIX-1)。建议照 PARTY-1 的做法:在供应商列表页页头加一条链接,
   **并同时加一条冒烟可达性探针**(在 `/suppliers` 的 HTML 里找 `/contracts`),
   把"我记得加了链接"换成机制。
2. ★ **冒烟内容断言一条都没加。** 两句最值得守的话都是服务端渲染的:
   `contracts.coverageWhy`(「没有合同被违反」也可能只是「没有人挂过东西」)与
   `contracts.breachNothingComparable`。针要**从 `messages/en.ts` 现读**,
   并在会被 HTML 转义的字符之前收尾(`&`、引号、撇号)—— 这一条本仓库付过两次账。
3. **合同的录入界面没有做。** 今天只有一张只读的登记簿页;建合同、加条款、
   挂单据都还只能走 SQL。`link_document_to_contract` 是现成的写入口。
4. **`docs/known-issues.md` 三条没写**:
   * 保单与合同义务之间**刻意没有连接** —— "policy P 满不满足 contract C"是一次判断
     (险种/保额/保障区间/被保险人),没有人裁过,而一条猜出来的连接会把
     **一份没有保障的合同报成已保障**。记它需要什么才答得了。
   * **数量承诺的达成率没算** —— 要先回答"哪些单据算进这份承诺"(下单算还是收货算?
     跨月的一船算哪个月?)。一个口径没人定过的达成率比没有更坏。
   * **品位违反是报告不是闸**,升成闸的触发条件是**阶段 6 的 G29 质量暂扣**落地。
5. **队列没划**:`docs/forward-queue.md` 阶段 5 那条
   「一刀:合同登记簿 + 卖方已承诺条款 + 保险登记簿」要**改写**(不是划掉)——
   保险那一半是**复用了既有的证书机制**(`certificate_types` 加一行 `insurance`,
   RUNTIME CONFIG,不是第二套到期机制),而**指数挂钩定价仍然没做**。
   `docs/proc-reality.md` 的 **G11(目标品位与公差)** 可以划掉:它此前被 **U8** 挡着,
   而 U8 的触发条件写的正是「第一份带规格的供货合同」—— 本刀建的就是那个。

---

## 八 · 第 4 刀(指数挂钩定价)的交接点

**不要**把定价的列加在 `contracts` 那一行上 —— 那正是第 4 刀要迁走的形状。
它应当落成**第四个兄弟子表**:建议 `contract_pricing_terms`,同样以 `contract_id` 为键,
与 `contract_grade_specs` / `contract_insurance_obligations` /
`contract_volume_commitments` 并列。这段话也写在 `db/tables/contracts.sql` 的表注里
与 `/contracts` 页面的末尾。

**本刀刻意没有预建那张空表** —— 一张没有写入方的空表,是 PARTY-1 点名过的
"写给谁都不看的表单"。

> ★ 另外(**2026-08-30 更新:这一条已经不成立了**):此前那次会话找不到
> `/Users/timchen/Downloads/index-pricing-spec.md`,于是按规矩**没有**替它编一份 ——
> 凭想象造一份规格,正是本仓库明令禁止的「把一个待答的问题伪装成一个已完成的规格」。
> **那份文件后来真的拿到了**,现已归档为 `docs/index-pricing-spec.md`,
> 并在归档时对着线上核过一遍(结果写在它自己的抬头里,含**一处与线上不符**:
> §5 说的「LME 和 SMM 两个序列」线上并不存在,`price_index` 10 行全是 NULL)。
> **它的 §6 七问 Tim 已于 2026-08-29 全部裁定 —— 那一节是【已答】,不是待办。**

---

## 九 · 本刀的几条设计裁定(Tim,2026-08-29),改之前先读

1. **两条拒绝、且只有两条**:对手方对不上、合同不是 active。**两条都是【不一致】不是【政策】** ——
   AGENTS.md 给 `ALLOC_CURRENCY_MISMATCH` 与 `ALLOC_EXCEEDS` 划过这条线。
   **单据日期落在合同期之外【刻意不拒】**:回填正当,而"能不能背靠未生效的合同下单"
   没有人裁过 —— 要加这道闸,先要有一次裁定,不是先加一句 `IF`。
2. **覆盖率必须被说出来**:没有任何东西强制单据挂合同(现货采购本来就没有),
   所以「没有合同被违反」很可能只是「没有人挂过东西」。`contract_coverage` 给的是分母。
3. **品位用 min/max,不用 target±tolerance**(后者是前者的对称特例,两种都存就是两个写法);
   **报告违反,不拒绝交货**(化验回来时货已经在场上,而没有暂扣状态可以放它)。
4. **保险是两件事**:我们持有的**保单**(有到期日,归既有证书机制)与合同里那条
   **义务**(没有自己的到期日,被违反的方式是保单**不存在**)。**判据是它们能各自为真。**
5. **一张 `contracts` 表同时装买卖两侧**,一行恰好属于一边 —— 但
   **它不是一方两身那个结构**:它不把任何客户与任何供应商连起来,
   同一家公司在两侧会有两份合同,而那是对的。
