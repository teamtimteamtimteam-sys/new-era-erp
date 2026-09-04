# KPI 框架 —— 源数据(逐格转录)与落地规格

**源:`Playbook_KPIs and achievement_Sep26toFeb27.xlsx`**(Tim 提供,2026-08-27;
sha256 `532cfe810c8fe637bde6a62a1daf20ff32663ce3da036a290d1043c084708261`)。
七页:`Playbook Summary` / `Organization KPIs` / `Asspcoate KPIs` /
`Associate Roll-up` / `KPI Linkage Matrix` / `Scoring` / `Source Basis`。

## 怎么读这份文件 —— **哪一半是源,哪一半是注**

| 章 | 是什么 | 能不能改 |
|---|---|---|
| **一 – 七** | **原表的逐格转录,英文原文** | **不能**。要改先改原表,再重新转录 |
| 八 – 十一 | 落地成系统数据的结构决定与实现顺序(Tim 2026-08-27) | 能,那是决定 |
| 十二 | 落地前对着**线上库**实测出来的现状 | 能,那是测量,会过期 |
| 十三 | 与另一份转录件的逐条比对 | 记录,不再变 |

> **★ 一 – 七 的英文是【机器从 xlsx 里抄出来的】,不是人打出来的。★**
> 生成脚本读 `sharedStrings.xml` + 各 `sheet*.xml`,逐格取值再拼成表格 ——
> 三十条 KPI 的目标句子由人重打一遍,就是三十次漏字的机会,而这份文件正是
> 模块要照着建的那一份。**这里不做任何翻译、压缩或润色**,
> 连原表自己的拼写也照录:页签是 `Asspcoate KPIs`(sic)、
> `Source Basis` 的列头是 `Matertials used`(sic)。
>
> **本文件里的中文,一律是注,不是源。** 判据很简单:中文出现在第八章之后,
> 或者出现在"栏"这一列的表头里;**KPI 的措辞、权重、链接、目标一个字都不是中文的**。

> **关于日期:原表的时间跨度是 `26 Aug 2026 → 26 Feb 2027`,而 Tim 说过那是模拟日期,
> 重要的是 KPI 的内容不是时间。** 所以第十一章的实现顺序按**逻辑依赖**排,
> 不按日历,本文件也不带任何时间紧迫性。

---

## 一、Playbook Summary（原表第 1 页,逐格转录）

**EVoltrya \| 3–6 Month KPI Framework**

Launch-phase performance framework linking 5 organization KPIs to 30 individual employee KPIs. Targets are designed for the current pre-commissioning / licensing stage and the planned transition to operations.

| | | |
|---|---|---|
| **Time horizon** | 26 Aug 2026 → 26 Feb 2027 | Use Month 3 and Month 6 gates; review monthly. |
| **Business gate** | Licensing → equipment → commissioning → commercial readiness → controlled operations | No KPI should encourage operation before the applicable regulatory approvals are in force. |
| **Org KPI weighting** | Licensing 25% \| Equipment 25% \| Cashflow 20% \| Commercial 15% \| Safety/compliance 15% | Total = 100%. |
| **Employee KPI design** | 5 KPIs per named employee; weights total 100% per employee | Individual KPIs are directly mapped to O1–O5. |

### Management Cadence

| | |
|---|---|
| **Weekly** | 13-week cash forecast; licensing action log; equipment critical-path review; commercial pipeline; safety critical actions. |
| **Monthly** | KPI scoring; management HSE/compliance review; AR ageing; cash reserve; commissioning readiness; customer/feedstock coverage. |
| **Month 3 gate** | Formal launch-readiness review against all 5 organization KPIs. |
| **Month 6 gate** | Commissioning / operating-readiness review and first formal performance cycle. |

### Important design principle

> The framework deliberately makes licensing, commissioning and safety 'gates', not merely activity targets. Commercial growth and cash generation are measured alongside readiness so EVoltrya does not commit feedstock, customer volume or cash beyond what the licensed and commissioned operation can safely deliver.

---

## 二、Organization KPIs(O1–O5)—— 原表第 2 页,逐格转录

Five organization-level KPIs for the next 3–6 months. Score each KPI monthly on a 0–5 scale; weighted score = score / 5 × KPI weight.

每条一块,因为 Month 3 / Month 6 / 证据 / 管理层备注四栏都是整句,塞进一行表格会被截断。

### O1 · Licensing & regulatory readiness —— 25%

| 栏 | 原文 |
|---|---|
| `Definition` | All permits, licences, registrations, notifications and regulator conditions required for intended battery receipt, storage, handling and recycling operations. |
| `Month 3 target` | Month 3: 100% required applications/submissions lodged; 100% regulator queries/actions tracked with owner/date. |
| `Month 6 target` | Month 6: 100% required approvals/licences in force before operations; 0 unauthorized receipt/processing. |
| `Measurement / evidence` | Regulatory tracker, submission receipts, approval letters, conditions register. |
| `Criticality / management note` | Critical gate: no commercial production or battery receipt beyond what is legally permitted. |

### O2 · Line equipment readiness & commissioning —— 25%

| 栏 | 原文 |
|---|---|
| `Definition` | Critical recycling line equipment confirmed, delivered, installed, tested and commissioned to agreed acceptance criteria. |
| `Month 3 target` | Month 3: 100% critical equipment specifications/POs confirmed; FAT/inspection completed where applicable; installation schedule locked. |
| `Month 6 target` | Month 6: 100% critical line installed and commissioned; ≥3 successful end-to-end commissioning runs; critical punch-list items closed. |
| `Measurement / evidence` | Equipment tracker, FAT/SAT records, installation sign-off, commissioning reports. |
| `Criticality / management note` | Protects processing continuity and the transition from pre-processing to black mass output. |

### O3 · Critical cashflow continuity —— 20%

| 栏 | 原文 |
|---|---|
| `Definition` | Liquidity, collections, working capital and cash visibility controlled through the full order-to-cash cycle. |
| `Month 3 target` | Weekly 13-week cash forecast maintained 100% of weeks; minimum cash reserve ≥3 months fixed OPEX; DSO target ≤45 days once invoicing starts. |
| `Month 6 target` | 0 unapproved material cash commitments; cash reserve maintained at ≥3 months fixed OPEX; overdue AR actively managed. |
| `Measurement / evidence` | 13-week cash forecast, bank reconciliation, AR ageing, AP schedule, approval log. |
| `Criticality / management note` | Reflects EVoltrya's cashflow controls: payment terms, credit risk, working capital, forecasting and governance. |

### O4 · Commercial readiness & secured business —— 15%

| 栏 | 原文 |
|---|---|
| `Definition` | Build a credible customer and feedstock base before committing processing capacity. |
| `Month 3 target` | Month 3: ≥3 priority customers at signed LOI/contract stage and first 90-day sales plan established. |
| `Month 6 target` | Month 6: ≥5 priority customers/long-term relationships with firm commitments covering ≥70% of planned initial processing capacity; feedstock coverage ≥100% of committed production. |
| `Measurement / evidence` | Signed LOIs/contracts, CRM/pipeline, feedstock contracts, order/backlog and capacity plan. |
| `Criticality / management note` | Aligned with the stated objective of 3–5 key long-term customers and controlled supply-to-sale continuity. |

### O5 · Facility safety, environmental & compliance readiness —— 15%

| 栏 | 原文 |
|---|---|
| `Definition` | Facility, people and operating controls ready for safe battery handling and compliant recycling. |
| `Month 3 target` | Month 3: 100% critical HSE/environmental risk assessments, SOPs and emergency controls completed; 100% pre-operational training complete for assigned staff. |
| `Month 6 target` | Month 6: 0 major non-conformities; 100% critical corrective actions closed by due date; ≥2 emergency drills completed; required inspections/documentation current. |
| `Measurement / evidence` | HSE register, SOP matrix, training records, drill reports, inspection logs, corrective-action register. |
| `Criticality / management note` | Matches EVoltrya's safety-first, traceability, storage/environmental compliance and responsible-operations positioning. |

**TOTAL = 100**(原表 `=SUM(C5:C9)`)。`Score (0–5)` 与 `Weighted score` 两栏在原表里是空的打分位,`Weighted score` 由公式 `=IF(I5="","",I5/5*C5)` 算出。

---

## 三、Employee KPIs(30 条)—— 原表第 3 页,逐格转录

Five quantifiable KPIs per employee. Each KPI is linked to one or more organization KPIs so individual performance rolls up to the company scorecard.

> **原表这一页的页签拼作 `Asspcoate KPIs`(sic)**,而下一页是 `Associate Roll-up`。照录,不改 —— 将来有人按页签名去找,改过的名字会让他找不到。

### Vince Goh — Founder / Managing Director

| `KPI ID` | `Individual KPI` | `Weight %` | `Linked Org KPI(s)` | `Quantifiable target / standard` |
|---|---|---|---|---|
| V1 | Regulatory leadership & escalation | 25 | O1 | Own master regulatory roadmap; 100% critical regulatory milestones have named owner, due date and escalation; no critical regulator action >5 working days overdue. |
| V2 | Commissioning governance | 20 | O2 | Chair weekly equipment/commissioning review; ≥90% critical project milestones delivered by committed date; all red issues escalated within 2 working days. |
| V3 | Liquidity & funding decisions | 20 | O3 | Approve/secure cash plan that maintains ≥3 months fixed-OPEX liquidity buffer; 100% material cash commitments reviewed against 13-week forecast. |
| V4 | Strategic customers & supply continuity | 20 | O4 | Personally sponsor ≥5 priority strategic relationships by month 6; secure executive-level support for commitments covering ≥70% of planned initial capacity. |
| V5 | Safety & governance culture | 15 | O5 | Monthly management HSE/compliance review; 100% critical actions assigned and tracked; zero knowingly approved operation outside regulatory/safety controls. |

权重合计 **100**。

### Tim Chen — Chief Financial Officer

| `KPI ID` | `Individual KPI` | `Weight %` | `Linked Org KPI(s)` | `Quantifiable target / standard` |
|---|---|---|---|---|
| T1 | 13-week cash forecast | 25 | O3 | Update forecast weekly with 100% on-time completion; target forecast variance for next 4 weeks within ±10%. |
| T2 | Liquidity buffer | 20 | O3 | Maintain minimum cash reserve ≥3 months fixed OPEX, with weekly visibility and documented mitigation for any projected breach. |
| T3 | AR / collections discipline | 20 | O3 | Issue invoices within 2 working days of approved billing trigger; maintain DSO ≤45 days once meaningful billing begins; escalate overdue balances >30 days weekly. |
| T4 | Financial controls for licensing & capex | 20 | O1 / O2 | 100% licence, equipment and commissioning payments matched to approved budget/contract milestones; zero unapproved material commitments. |
| T5 | Close & governance | 15 | O3 / O5 | Monthly management accounts and cash reconciliation completed by 5th working day; 100% material control exceptions logged and closed/actioned. |

权重合计 **100**。

### Cheng Siong Phua — Chief Technology Officer

| `KPI ID` | `Individual KPI` | `Weight %` | `Linked Org KPI(s)` | `Quantifiable target / standard` |
|---|---|---|---|---|
| C1 | Equipment delivery & installation | 25 | O2 | 100% critical equipment specifications/POs confirmed; ≥90% critical delivery/installation milestones on time; installation sign-off completed. |
| C2 | Commissioning & process acceptance | 25 | O2 | Complete ≥3 successful end-to-end commissioning runs from battery feed through separation/black mass output, with agreed safety, quality and process acceptance criteria met. |
| C3 | Technical licensing support | 15 | O1 | 100% required technical drawings, process descriptions, equipment data, risk assessments and regulator technical responses submitted by agreed dates. |
| C4 | Process safety & operating readiness | 20 | O5 | 100% critical SOPs, JSA/risk assessments, interlocks and emergency operating procedures completed and trained before relevant commissioning/operations. |
| C5 | Maintenance resilience | 15 | O2 / O5 | 100% critical equipment PM schedule and critical-spares list established before handover; downtime response protocol tested at least once. |

权重合计 **100**。

### Sandra Yap — Chief Commercial Officer

| `KPI ID` | `Individual KPI` | `Weight %` | `Linked Org KPI(s)` | `Quantifiable target / standard` |
|---|---|---|---|---|
| S1 | Priority customer conversion | 25 | O4 | Secure ≥3 priority customers at signed LOI/contract stage by month 3 and ≥5 by month 6, with clear volume/specification/price/terms. |
| S2 | Revenue / order coverage | 25 | O4 / O3 | Build firm customer commitments covering ≥70% of planned initial processing capacity for the first 90 days after commissioning. |
| S3 | Commercial terms & credit protection | 20 | O3 / O4 | 100% customer contracts use approved pricing, Incoterms, payment milestones/deposits/credit limits and collection protections; 0 sales commitments without finance/operations capacity check. |
| S4 | Order-to-cash readiness | 15 | O3 / O4 | 100% contracted orders have feedstock check, production slot, assay/release, logistics, invoicing and collection owner documented before commitment. |
| S5 | Customer quality / retention | 15 | O4 / O5 | 100% customer product specifications and QA/assay requirements documented before shipment; 0 avoidable customer escalations caused by missing commercial/quality information. |

权重合计 **100**。

### Choo Er Teh — Lead – Accounts & Corporate Services

| `KPI ID` | `Individual KPI` | `Weight %` | `Linked Org KPI(s)` | `Quantifiable target / standard` |
|---|---|---|---|---|
| A1 | Cash & AR administration | 25 | O3 | 100% customer invoices, receipts and AR ageing records maintained accurately; collection follow-up list updated and reconciled weekly. |
| A2 | Corporate records & governance | 20 | O3 / O5 | 100% statutory/corporate records, approvals, contracts and key registers maintained in a controlled repository; zero missing critical documents at monthly review. |
| A3 | Licensing administration | 20 | O1 | Maintain master licence/regulatory document register with 100% submissions, approvals, expiry/renewal dates and regulator correspondence logged. |
| A4 | Facility / HSE administration | 20 | O5 | 100% required training, inspection, drill, incident and corrective-action records filed and current; monthly compliance pack issued on time. |
| A5 | Payroll / people readiness | 15 | O5 | 100% required employee onboarding, safety induction and training records complete before site duties; payroll/admin processed accurately and on schedule. |

权重合计 **100**。

### Fu Sheng Wong — Lead – Warehouse & Logistics

| `KPI ID` | `Individual KPI` | `Weight %` | `Linked Org KPI(s)` | `Quantifiable target / standard` |
|---|---|---|---|---|
| F1 | Warehouse & inventory readiness | 25 | O5 / O2 | Warehouse layout, segregation, labelling and inventory controls 100% ready before battery/material receipt; inventory accuracy ≥98% in monthly checks. |
| F2 | Inbound/ outbound declaration capability and clearance | 25 | O1 / O5 | 100% inbound/outbound battery movements supported by required certification, documentation, classification, packaging and approved transport arrangements; 0 major logistics compliance breaches. |
| F3 | Feedstock coverage & inbound continuity | 20 | O4 | Maintain rolling inbound plan covering ≥100% of committed production requirements; escalate supply gaps ≥10 working days before planned receipt. |
| F4 | Dispatch & documentation | 15 | O3 / O4 | ≥98% on-time dispatch readiness once sales begin; 100% shipping documents complete before dispatch and invoice trigger. |
| F5 | Warehouse safety & emergency readiness | 15 | O5 | 100% warehouse staff trained on battery handling/emergency procedures; ≥2 emergency drills supported; 0 critical housekeeping/safety findings left overdue. |

权重合计 **100**。

---

## 四、Associate Roll-up —— 原表第 4 页,逐格转录

The five individual KPIs for each employee total 100%. Use this page for the formal 3-month and 6-month review.

| Employee | Role | KPI weight total | Primary organizational contribution |
|---|---|---|---|
| Vince Goh | Founder / Managing Director | 100 | Enterprise gatekeeping: licensing, commissioning, liquidity, strategic relationships and safety governance. |
| Tim Chen | Chief Financial Officer | 100 | Liquidity protection, cash visibility, collections, capex control and governance. |
| Cheng Siong Phua | Chief Technology Officer | 100 | Equipment readiness, commissioning, technical licensing evidence, process safety and maintenance resilience. |
| Sandra Yap | Chief Commercial Officer | 100 | Customer conversion, capacity coverage, commercial protection and order-to-cash discipline. |
| Choo Er Teh | Lead – Accounts & Corporate Services | 100 | Finance/admin records, licensing administration, HSE documentation and people readiness. |
| Fu Sheng Wong | Lead – Warehouse & Logistics | 100 | Warehouse readiness, battery logistics compliance, feedstock continuity, dispatch and safety. |

`Weighted score achieved` / `Performance %` 是公式列(`=SUM('Asspcoate KPIs'!J5:J9)`、`=IF(C5=0,"",D5/C5)`),未打分时为空/0。
`Management focus` 一栏**原表六行全空**。

---

## 五、KPI Linkage Matrix —— 原表第 5 页,逐格转录

Each employee has explicit contribution to the five organization KPIs. The matrix counts the number of individual KPIs supporting each organization KPI.

| Employee | Role | O1 Licensing | O2 Equipment | O3 Cashflow | O4 Commercial | O5 Safety/Compliance |
|---|---|---|---|---|---|---|
| Vince Goh | Founder / Managing Director | 1 | 1 | 1 | 1 | 1 |
| Tim Chen | Chief Financial Officer | 1 | 1 | 4 | 0 | 1 |
| Cheng Siong Phua | Chief Technology Officer | 1 | 3 | 0 | 0 | 2 |
| Sandra Yap | Chief Commercial Officer | 0 | 0 | 3 | 5 | 1 |
| Choo Er Teh | Lead – Accounts & Corporate Services | 1 | 0 | 2 | 0 | 3 |
| Fu Sheng Wong | Lead – Warehouse & Logistics | 1 | 1 | 1 | 2 | 3 |

| Organization KPI | O1 | O2 | O3 | O4 | O5 |
|---|---|---|---|---|---|
| Weight | 25 | 25 | 20 | 15 | 15 |

### How to read this

> A single employee KPI can support more than one organization KPI. The detailed Employee KPIs sheet preserves the exact linkage. The matrix is a management view of coverage, not a mathematical re-weighting of the organization scorecard.

---

## 六、Scoring, Governance & Review Rules —— 原表第 6 页,逐格转录

Suggested operating rules for a practical launch-phase KPI process.

| Score | Interpretation | Suggested evidence standard | Management action | Critical safety/regulatory override | Review cadence |
|---|---|---|---|---|---|
| 5 | Outstanding / materially ahead | ≥100% of target plus positive stretch outcome | Recognise; capture best practice | Does not override a major safety/regulatory breach | Monthly / formal at M3 & M6 |
| 4 | Fully achieved | 95–99% of target or target achieved with minor timing variance | Maintain; close minor gaps | Major breach can cap score at 0–2 depending on severity | Monthly / formal at M3 & M6 |
| 3 | Mostly achieved | 90–94% of target | Corrective action required | Critical control gap should reduce score | Monthly / formal at M3 & M6 |
| 2 | Partially achieved | 80–89% of target | Management recovery plan | Critical control gap may cap at 2 | Monthly / formal at M3 & M6 |
| 1 | Materially behind | 70–79% of target | Escalate with named recovery owner/date | Any unauthorized operation = 0 | Weekly until recovered |
| 0 | Failed / unacceptable | <70% of target or major compliance/safety failure | Immediate escalation and recovery plan | Unauthorized battery processing/receipt where prohibited = 0 | Immediate |

### Recommended review sequence

| | | |
|---|---|---|
| 1 | **Weekly operating review** | Review O1/O2/O3/O4/O5 exceptions, not just the score. |
| 2 | **Monthly scorecard** | Score each KPI 0–5 using evidence; record owner, action and due date for anything <3. |
| 3 | **Month 3 gate** | Decide whether EVoltrya is regulatory-ready, equipment-ready, commercially ready and financially protected. |
| 4 | **Month 6 gate** | Decide whether the plant and organization are ready for sustained controlled operations and customer fulfilment. |

---

## 七、Source Basis & Rationale —— 原表第 7 页,逐格转录

The framework is grounded in the EVoltrya organization profile, business continuity deck and role/salary materials supplied for the team.

### EVoltrya Organization Profile

| 栏 | 原文 |
|---|---|
| `Relevant content used` | Singapore-based battery recovery business; purpose/vision/mission; services; differentiators; pre-processing; mechanical dry recycling; safety, traceability and environmental compliance. |
| `Matertials used` | Organization Profile, pp. 2–12 |
| `How it informs this KPI framework` | Supports O1, O2 and O5 and the emphasis on recovery, traceability, safety and responsible operations. |
| `Notes / limitation` | The profile does not specify the exact licence names or regulator approval dates, so O1 deliberately uses a generic 'all required approvals/licences' gate. Actual licenses and timelines need to be developed once there is clarity |

### EVoltrya Business Continuity: Supply to Sale

| 栏 | 原文 |
|---|---|
| `Relevant content used` | Supply-to-sale continuity; 3–5 key long-term customers; feedstock pipeline; processing continuity; QA/assay release; order-to-cash; cashflow controls and critical perimeters. |
| `Matertials used` | Business Deck, pp. 2–8 |
| `How it informs this KPI framework` | Supports O3/O4 and the commercial/cashflow measures: customer count, feedstock coverage, cash forecast, DSO, payment terms, credit risk, working capital and liquidity buffer. |
| `Notes / limitation` | The deck gives identified feedstock of 423 MT/month and potential additional 90 MT/month, but does not state that all volumes are contractually firm; therefore the KPI uses 'firm commitments' and capacity coverage rather than treating the pipeline as contracted. Contracts need to be drawn and secured once the business kicks in |

### EVoltrya Business Continuity: Resilience by design

| 栏 | 原文 |
|---|---|
| `Relevant content used` | Risk/control mapping for feedstock, equipment, quality/logistics/regulatory and cashflow/collection. |
| `Matertials used` | Business Deck, p. 9 |
| `How it informs this KPI framework` | Supports cross-functional ownership and the linkage between commercial, technology/operations, QA/traceability, logistics and finance. |
| `Notes / limitation` | **（原表此格为空）** |

### Salary Proposal & Justification

| 栏 | 原文 |
|---|---|
| `Relevant content used` | Named roles and role scope: MD, CFO, CTO, CCO, Lead Accounts & Corporate Services, Lead Warehouse & Logistics. |
| `Matertials used` | Salary Proposal & Justification, Role Basis and Salary Proposal sheets |
| `How it informs this KPI framework` | Used to tailor the 5 KPIs for each named employee to the scope already proposed for their role. |
| `Notes / limitation` | This workbook makes use of existing positions that are critical in the beginning stage.  |

### Important target-setting note

> Some targets are management recommendations rather than facts stated in the supplied materials — particularly the 3-month/6-month dates, ≥3 months fixed-OPEX liquidity buffer, DSO ≤45 days, ≥70% initial-capacity customer coverage, ≥98% inventory accuracy, and ≥90% milestone adherence. They are intentionally quantifiable launch controls and should be adjusted accordingly to the final commissioning schedule, licensed capacity, commercial terms or financing plan changes.

---

## 八、结构决定(Tim,2026-08-27)

### 8.1 KPI 绑在【职位】上,不绑在人上

新账号创建时填了职位,**自动关联该职位的 KPI**。

> **这不是一条新规矩,是仓库里已有那条的第二次落地。**
> `docs/exec-views-plan.md` 开篇就写着:**「"谁需要哪个数"的答案取自职责,不取自职级」**,
> 并按职责锚点排四个人 —— Vince GOH(Founder & MD)、Sandra YAP(CCO)、
> Cheng Siong PHUA(CTO)、Tim CHEN(CFO),公司职能(HR/薪酬/IT)在 Choo Er TEH 之下。
> 与本框架第三章的六个人对得上。绑在职位上,是同一条原则用在考核上。

### 8.2 于是需要一张【职位表】,而它今天不存在

原表第三章的六个职位就是职位主数据的第一批行:

| 代号(建议) | 职位(原表 `Role` 列原文) | 现任(原表 `Name` 列原文) |
|---|---|---|
| MD | Founder / Managing Director | Vince Goh |
| CFO | Chief Financial Officer | Tim Chen |
| CTO | Chief Technology Officer | Cheng Siong Phua |
| CCO | Chief Commercial Officer | Sandra Yap |
| LEAD-ACC | Lead – Accounts & Corporate Services | Choo Er Teh |
| LEAD-WH | Lead – Warehouse & Logistics | Fu Sheng Wong |

**代号那一列是本文件提的,原表没有代号。** 职位名与人名是原表原文。

> **职位表不只服务 KPI。** 招聘、组织架构、薪资将来都要用它 ——
> 这也是它值得单独建、而不是塞进 KPI 模块里的理由:
> 一张挂在 KPI 之下的职位表,第一次被招聘用到的时候就要搬家。

**线上现状与这条决定的关系,见第十二章第 1 节**(有一个从没人用过的 `job_title` 自由文本列)。

### 8.3 生成方式:**复制,不是引用**

一个人加入某职位时,把该职位模板的五条**复制**到他名下;
**日后修改职位模板,不影响已经复制出去的条目**。复制时记下**来源职位与模板版本**,
使其可追溯,而不被后续修改污染。

> **理由是仓库自己的先例,不是一句偏好:**
> 采购单的定价条款在**承诺那一刻抄下**(FIN-27),发票的税率在**开出那一刻冻结**(GST-2)。
> **一个人某个周期被考核的是哪五条,是一件【已经发生】的事。**
> 后来改了职位模板,不该回头改写他当时被考核的标准 —— 那不是"更新",那是改历史。
>
> FIN-27 那一刀还留下了这条规矩的下半句,这里一并继承:
> **引用了模板却没有留下副本的记录,要按名拒绝,不许悄悄回退去读"现在的模板"。**

---

## 九、三件落地时必须一并处理的事

### 9.1 roll-up 与联动矩阵是【算出来的】,不另存

原表第四页 `Associate Roll-up` 与第五页 `KPI Linkage Matrix`,**每一个数字都能从
KPI 行推导**,原表自己就是用公式算的(`=SUM('Asspcoate KPIs'!E5:E9)` 一族)。
两者都做成**视图**,不建表。

> **本刀验算过,不是照抄结论。** 按第三章 `Linked Org KPI(s)` 那一列逐人统计,
> 与第五页写死的六行数字**逐格相同**:
>
> | 人 | 由链接列算出 | 原表第五页 |
> |---|---|---|
> | Vince Goh | 1 / 1 / 1 / 1 / 1 | 1 / 1 / 1 / 1 / 1 ✓ |
> | Tim Chen | 1 / 1 / 4 / 0 / 1 | 1 / 1 / 4 / 0 / 1 ✓ |
> | Cheng Siong Phua | 1 / 3 / 0 / 0 / 2 | 1 / 3 / 0 / 0 / 2 ✓ |
> | Sandra Yap | 0 / 0 / 3 / 5 / 1 | 0 / 0 / 3 / 5 / 1 ✓ |
> | Choo Er Teh | 1 / 0 / 2 / 0 / 3 | 1 / 0 / 2 / 0 / 3 ✓ |
> | Fu Sheng Wong | 1 / 1 / 1 / 2 / 3 | 1 / 1 / 1 / 2 / 3 ✓ |
>
> 六行全中。**所以"矩阵是派生的"是一句被验过的话,不是一句设计意图。**

★**这一句必须写在矩阵旁边,原表原文,不许改写:**★

> *A single employee KPI can support more than one organization KPI. The detailed
> Employee KPIs sheet preserves the exact linkage. **The matrix is a management view
> of coverage, not a mathematical re-weighting of the organization scorecard.***

**为什么这句话必须贴着数字放:** 矩阵那六行数字长得像权重(它们是整数,按组织 KPI 分列,
下面还紧跟着一行 `Weight 25 / 25 / 20 / 15 / 15`)。**没有这句话在旁边,
第一个读它的人会把"Sandra 在 O4 上有 5 条"读成"Sandra 的 O4 权重是 5"。**

### 9.2 建议值 ≠ 既定标准 —— 而原表自己声明了这件事

原表第七页最后一格,**原文照录**:

> *Some targets are management recommendations rather than facts stated in the supplied
> materials — particularly the 3-month/6-month dates, ≥3 months fixed-OPEX liquidity buffer,
> DSO ≤45 days, ≥70% initial-capacity customer coverage, ≥98% inventory accuracy, and ≥90%
> milestone adherence. They are intentionally quantifiable launch controls and should be
> adjusted accordingly to the final commissioning schedule, licensed capacity, commercial
> terms or financing plan changes.*

**落地要求:系统必须能看出【哪些目标是暂定的】。** 不是一句备注,是目标行上的一个属性。

> **不这么做的后果是可预见的:** 第一个读到 T3 的人会把 `DSO ≤45 days` 当成公司已经
> 定下的政策,并据此去问"为什么我们没做到 45 天" —— 而原表说的是"这是个建议值,
> 应随商务条款调整"。**一个建议值在系统里长得像一条既定标准,就是一次误导**,
> 与本仓库反复修的"算出来却不说话的值就是错答案"是同一族。
>
> 第七页另外三格的 `Notes / limitation` 同理,都要跟着数据走 —— 尤其
> **O1 之所以写成笼统的 "all required approvals/licences",是因为原始材料没有写出
> 具体牌照名与批复日期**;以及 **423 MT/月 的进料是"已识别"而非"已签约"**。

### 9.3 权重必须【被强制】,不是被信任

* 每个职位模板的五条权重合计 **必须 = 100**;
* 组织 KPI 的五条权重合计 **必须 = 100**。

**这是一条按名字拒绝的规则,不是一句提示。**

> **原表今天是对的 —— 本刀逐条加过:** 组织 25+25+20+15+15 = **100**;
> 六个人各自 **100**(Vince 25/20/20/20/15、Tim 25/20/20/20/15、Phua 25/25/15/20/15、
> Sandra 25/25/20/15/15、Choo Er 25/20/20/20/15、Fu Sheng 25/25/20/15/15)。
> **正因为今天是对的,才要把它做成闸** —— 一张今天合计 100 的表,
> 在有人加第六条 KPI、或把 25 改成 30 的那一刻会变成 105,而**加权分照样算得出来**,
> 只是从此没有一个数是可比的。**闸要在写入那一刻拦,不是在报表上提醒。**

---

## 十、系统能算什么、不能算什么

### 10.1 少数几条的证据,今天的数据就能算

| KPI | 证据来源 | 系统里的对应物 |
|---|---|---|
| **F1** inventory accuracy ≥98% | 月度盘点 | `stocktakes` / `stocktake_lines` |
| **C5** critical equipment PM schedule | 预防性保养计划 | `equipment_service_intervals` / `equipment_service_status` / `equipment_maintenance` |
| **A1**、**T3**(一部分) | 应收账龄 | `ar_aging_asof` / `ap_aging_asof`(AGING-1,2026-08-27 建成) |

**C5 只有一半能算** —— `critical-spares list` 在这套系统里**一张表、一个列都没有**,
详见第十二章第 3 节。

### 10.2 ★算出来的分与人判断的分,在屏幕上【必须长得不一样】★

**这是设计要求,不是可选项。**

> **理由:** 一份记分卡上,`98.4%`(盘点算出来的)与 `4 分`(有人看了证据判的)
> 并排放着,如果字体、位置、样式一模一样,**打分的人会默认两个数一样可靠**。
> 而它们的可靠性差着一整个数量级:一个可以点开看到是哪几次盘点、哪几行差异;
> 另一个背后是一个人的判断,可能有证据,也可能只是印象。
>
> 本仓库对这一族已经有先例:`lib/permissions.ts` 存在的全部理由,就是
> **`null`(看不到)与 `0`(确实是零)不能长得一样**;`MaskedValue` 把"受限"
> 渲染成「受限」而不是 `0.00`。**这里是同一条规矩换了个场景:
> "算出来的"与"判出来的"不能长得一样。**

### 10.3 这份框架点名要、而系统还没有的能力 —— **记录,不是依赖**

| KPI | 依赖的能力 | 现状(2026-08-27 实测) |
|---|---|---|
| **T1 / V3** | 13 周现金预测 | 队列中(阶段 4);实测其输入(到期日)不存在 |
| **T2 / V3** | 固定运营支出基线 | **经常性支出没有任何表**:`%recurring%`/`%subscription%`/`%opex%`/`%budget%` 合计 **0 张** |
| **T3** | DSO | 账龄按**单据日**分档而非逾期;付款条款 **0/8 供应商、0/3 客户** |
| **T5** | 月度管理账目 | 月度报表包在队列中(阶段 4) |
| **A3** | 许可/监管文件登记册 | **`%licen%`/`%permit%` 0 张**;阶段 6(牌照到手时触发) |
| **F2** | 进出口单证与分类 | 只有 `lane_document_requirements`(按航段);**没有出口单证登记册**;阶段 6 |
| **S3** | 已批准定价、贸易术语、信用额度 | 信用额度已有(`customer_credit_status` 一族);指数联动定价在阶段 5 |

> **★ 这些【不是】本模块的前置条件。★** KPI 可以先记录、先**人工打分** ——
> 三十条里绝大多数本来就是人判断的。列在这里只是让后来的人知道:
> **这几条 KPI 的证据来源,一部分已经排在队列里了**,
> 等那几刀落地,它们可以从"人填"改成"系统算",而那一天要用到第 10.2 条。

---

## 十一、实现顺序(按逻辑依赖,不按日历)

0. **补齐原表 O1–O5 的四栏原文** —— 已随本文件完成(第二章)。留作第 0 步是因为
   在它补齐之前,第 2 步没有规格可照。
1. **职位主数据** —— 六个职位;员工挂到职位上
2. **组织 KPI** —— O1–O5,含权重、Month 3 / Month 6 目标、证据、管理层备注
3. **职位 KPI 模板** —— 每职位 5 条,权重合计 100,每条链到一或多条组织 KPI
4. **考核周期与打分** —— 0–5、加权、安全/监管否决、M3 与 M6 两道关口
5. **入职按职位自动生成** —— **复制**,记来源职位与模板版本
6. **roll-up 与联动矩阵** —— 派生视图,不建表

> **它挡不住任何一件事,也不被任何一件事挡住。**
> 所以它在队列里的位置是一个**排期选择**,不是一条依赖 ——
> Tim 已经说过**没有紧迫性**,原表的日期是模拟的。

---

## 十二、落地前对着线上库实测的现状(KPI-0,2026-08-27)
## —— ★**其中三处已于 KPI-1(2026-08-29)过期,逐条标在下面**★

> **本章抬头自己写着「会过期,过期就重测」。KPI-1 动手前重测了一遍,三处对不上:**
>
> | § | 当时记的 | 2026-08-29 重测 |
> |---|---|---|
> | 12.1 | 员工 **6 人** | **21 行**,其中 **19 行是 ZZ-* 脚手架**,真员工只有 **2 位** |
> | 12.1 | `job_title` 那一列**从来没人用过** | 列本身确实 0 填,**但它有真读者**:`/me` 渲染它、HR 表单写它、而且**改它会写一行不可变的 `employment_history`**(线上 3 行)。所以它是一条**审计轨迹里的快照**,不是一列死数据 —— KPI-1 因此从 employees 上删掉它,却**保留 employment_history 上的同名列** |
> | 12.2 | 扩建 vs 另起是**公开问题,归 Tim** | **已裁定:另起,两者并存**(2026-08-29)。代码本身给出了理由 —— `review_goals` 的表注写着「没有权重、没有逐条打分」,而 KPI 的全部内容就是 0–5 乘权重 |
>
> **还有一处不是过期,是一个当时没被写下来的后果:** 原表点名的六个人里,
> **四位在 `employees` 里根本没有档案**(Vince Goh、Cheng Siong Phua、
> Sandra Yap、Fu Sheng Wong)。于是**员工级的 roll-up 与联动矩阵今天只到六分之二** ——
> KPI-1 把这件事做成屏幕上的一句**具名缺席**,而不是一张画满零的表:
> **一片零读起来是「这些人什么都没贡献」,而事实是「他们还没被建档」。**
> 职位级那张矩阵不受影响,而且**可以对着原表第五页逐格核**(fixture 146 的 A 臂)。


**这一章记的是【这套系统今天的样子】,不是框架。** 会过期,过期就重测。

### 12.1 职位:表确实没有 —— 但 `job_title` 这一列【是有的】

| 问的是什么 | 实测 |
|---|---|
| 有没有 `positions` / `job_titles` / `grades` 表 | **0 张** |
| `employees` 上有没有职位 | **有 `job_title`,自由文本** |
| `job_title` 填了多少 | **6 个员工,0 个填过** |
| `departments` | **1 行**(`Dep-001 Finance Department / 财务部门`) |
| 员工数 | **6 人**,全部有账号 —— 与原表六个人对得上 |

**往好的方向:** 那一列从来没人用过,所以建职位表**没有历史自由文本要迁移、要去重**。
**往坏的方向:** 职位表建起来之后,`job_title` 要么退役、要么明写它与职位表的关系;
**两个都留着、两个都能填,就是同一个事实有两个写入口。**

### 12.2 ★这套系统里【已经有一个考核模块】,而且一行都没用过★ —— **公开问题,本刀不裁**

| 已有的东西 | 装了什么 | 用过没有 |
|---|---|---|
| `review_cycles` | `name, period_start, period_end, due_date, status` | **0 行** |
| `performance_reviews` | 含 `review_type, cycle_id, reviewer_employee_id, rating_code, summary_text, self_assessment_text, probation_outcome, new_monthly_salary` | **0 行** |
| `review_goals` | `sequence, objective_text, target_value, actual_value, unit, employee_result_text, reviewer_assessment_text` | — |
| `review_rating_scale` | **四档具名**:`OUTSTANDING / EXCEEDS / MEETS / BELOW`,每档带 `is_probation_pass` | 4 行(引导数据) |
| 界面 | `/hr/reviews`、`/my-reviews/[id]`,及 `performance_reviews_masked`、`my_review_subjects`、`my_self_assessment_goals` | 已上线 |

**两处实测出来的正面撞车:**

* **打分刻度不是同一把尺。** 已有的是**四档具名**、为转正/年度结论设计的
  (`is_probation_pass` 就是为转正设的);本框架要的是 **0–5 数值**、要**乘权重**、
  还要带**安全/监管否决**(「Major breach can cap score at 0–2」、
  「Any unauthorized operation = 0」)。**四档表达不出 0–5,更表达不出"封顶"这个动作。**
* **`review_goals` 差四样东西,而差的正是把它变成 KPI 的那四样。**
  它已经有 `objective_text` / `target_value` / `actual_value` / `unit` ——
  与一条 KPI 只差 **① 权重 ② 到组织 KPI 的链接 ③ 证据来源 ④ "从职位模板复制而来"**。
  它挂在 `review_id` 上、逐条手录,**没有"模板"这个概念**。

> ★**这是一个【公开问题】,归 Tim,本刀不裁。**★
>
> **(a) 扩建** —— KPI 条目就是 `review_goals` 加上权重/链接/证据/来源模板;
> 打分另立一张 0–5 的刻度,与四档并存(一个管转正、一个管 KPI)。
> **(b) 另起** —— KPI 自成一套表,与既有考核模块并排,各走各的周期。
>
> **写文档与定架构是两件事。** 把这个选择放进这一刀,它会被文档的进度推着走 ——
> 而它该由 Tim 在看得见两边代价的时候决定,不是在一份文档写到第十二章的时候顺手决定。
> 这里只记**测出来的东西**:四档 vs 0–5、`review_goals` 缺的那四样。

### 12.3 证据能不能自动算 —— 逐条实测

| 第 10.1 条说的 | 实测 | 结论 |
|---|---|---|
| 库存准确率(盘点) | `stocktakes`、`stocktake_lines` **都在** | **能算**(F1) |
| 关键设备保养计划 | `equipment_service_intervals`、`equipment_service_status`、`equipment_maintenance` **都在** | **能算**(C5 前半) |
| 关键备件清单 | **没有表、没有列** —— 全库 `%spare%` 命中 **0**、`%critical%` 命中 **0** | **算不了**(C5 后半) |
| 应收账龄 | `ap_aging_asof` / `ar_aging_asof` 已建(AGING-1) | **能算**(A1、T3 一部分) |

**C5 因此是【一半自动、一半空的】,而这正是第 10.2 条要防的那一幕:**
一条 KPI 的证据里一半是系统算的、一半是人填的,**屏幕上长得一样,
打分的人就会以为整条都有据可依**。连"关键设备"这个标记本身在库里都不存在。

### 12.4 ★原表的 `Evidence / review source` 那一栏,三十条【全是空的】★

第三页(`Asspcoate KPIs`)的列头 `H4` 写着 `Evidence / review source`,
而 **H5:H34 三十格没有一格有内容**(实测)。

> **这不是转录漏了,是原表就没填。** 说出来是因为它直接影响第 4 步(打分):
> **一条没有证据来源的 KPI,打分时靠的是打分人自己记得该看什么。**
> 组织 KPI 那一页(第二页)的 `Measurement / evidence` 五条**是填了的**,
> 所以缺的只有个人这一层。落地时这一栏要么补,要么就得承认
> **个人 KPI 的证据标准今天不在系统里,只在人脑子里** —— 两者都行,
> 但不能默认它已经有了。

### 12.5 第 10.3 条那张表,逐条对着库查过

`%recurring%`/`%subscription%`/`%opex%`/`%budget%` 合计 **0 张**;
`%licen%`/`%permit%` **0 张**;付款条款 **0/8 供应商、0/3 客户**;
出口单证只有 `lane_document_requirements`(按航段的单证要求),没有登记册;
信用额度已有(`customer_credit_status` / `customer_credit_history`)。

---

## 十三、与另一份转录件的逐条比对(2026-08-27)

Tim 另外提供了一份在别处做的转录 `kpi-framework.md`,**明确只作交叉核对用;
两者不一致时以 xlsx 为准**。本章记下每一处不一致 —— **不挑边,照直列**。

**结论先写:那份 .md 的【结构与判断是对的】**(职位/复制/派生/建议值/权重强制,
六条全部与原表一致),**而它的【内容是不完整的,且是译文】**。以下八处:

| # | 不一致 | xlsx(准) | .md |
|---|---|---|---|
| 1 | **O1–O5 的四栏** | Month 3 / Month 6 / Measurement / Criticality **五条全有** | **整段没有转录**,写「完整文字见原表」 |
| 2 | **30 条个人 KPI 的目标** | **英文原文** | **中文译文** —— 见下方逐条 |
| 3 | **Scoring 页的否决与节奏** | **逐分档各一格**(5 分「Does not override…」、4 分「can cap 0–2」、3 分「should reduce」、2 分「may cap at 2」、1 分「Any unauthorized operation = 0」、0 分「…where prohibited = 0」);节奏也逐档(1 分「Weekly until recovered」、0 分「Immediate」) | 压成**一段话 + 一行节奏**,逐档的差别丢了 |
| 4 | **Playbook Summary 整页** | Time horizon / Business gate / Org KPI weighting / Employee KPI design 四行,外加 **Management Cadence**(Weekly / Monthly / M3 / M6) | **只取了 design principle 一段**,其余整页没有 |
| 5 | **Source Basis 整页** | 四个来源行,各带 `Notes / limitation` —— 含「O1 之所以写成笼统的 all required approvals/licences」与「423 MT/月 已识别、非已签约」 | **四行全无**,只留最后那段 target-setting note,且漏掉 “They are intentionally quantifiable launch controls” |
| 6 | **Roll-up 的 `Primary organizational contribution`** | 六人各一句 | **没有** |
| 7 | **`Evidence / review source` 三十格全空** | 是事实 | **没有记录**,读的人会以为原表有证据来源 |
| 8 | **F2 的名字** | `Inbound/ outbound declaration capability and clearance`(斜杠后有空格) | `Inbound/outbound…`(无空格) |

**第 2 条里已经看得出来的译文漂移**(举证,不穷举):

| 处 | xlsx 原文 | .md 译文 | 差在哪 |
|---|---|---|---|
| V1 | *no critical **regulator action** >5 working days overdue* | 无关键**监管事项**逾期 >5 个工作日 | 「监管方的动作」被译成「监管事项」,主语变了 |
| V1 | *named owner, due date and **escalation*** | 指定负责人、到期日与**升级路径** | 原文只说 escalation,译文加了「路径」 |
| O1 | *required for **intended** battery receipt…* | 电池收料…所需 | **`intended` 丢了** —— 而这个词正是 O1 那道闸的范围限定 |
| O1 | *storage, **handling** and recycling* | 储存、**处置**与回收 | handling(操作/搬运)译成处置(disposal),含义偏了 |
| O4 | *before **committing** processing capacity* | 在**投入**产能之前 | committing(承诺出去)译成投入(投资),方向不同 |

> **为什么把这几处列出来而不是"译得差不多就行":** 这份文件是模块的规格。
> `intended` 丢掉一个词,O1 的边界就从「打算开展的业务所需」变成「所有的」;
> `committing` 变成「投入」,S 系列那几条"不要承诺超过产能"的意思就散了。
> **这正是本刀被要求"逐字转录、不要翻译"的原因,而这五处就是不这么做的代价。**

**另外两处,两份文件都没有记,本刀补上:**

* **原表 O3 的 Month 3 / Month 6 两格【没有 `Month 3:` / `Month 6:` 前缀】**,
  而 O1 / O2 / O4 / O5 四条都有。原表自己的不一致,照录不改 ——
  但落地时若按前缀去解析这两栏,O3 会解析不出来。
* **页签拼作 `Asspcoate KPIs`(sic)**,而第四页是 `Associate Roll-up`;
  `Source Basis` 的列头是 `Matertials used`(sic)。**照录,不改** ——
  改过的名字会让下一个按页签去找原表的人找不到。

---

# 十三、C-2(2026-09-05)· 月度录入那一屏 —— **数据库早就写好了,缺的只有屏幕**

> **基线:** HEAD `8afa0b7`(C-1b),树干净。
> **委托书要求"先勘察再设计,不要重建已有的东西"。勘察的结论改变了这一刀的形状。**

## 13.1 ★ 勘察结论:KPI-1 建的东西比委托书以为的多得多

委托书写着「这个模块到底装了什么,你我都不知道 —— 表、页面、三十条 KPI
有没有载入、有没有打分」。逐项实测(2026-09-05,线上):

| 东西 | 实况 |
|---|---|
| `kpi_organisation` | **5 行** —— O1–O5,权重 25/25/20/15/15,四栏原文俱全 |
| `kpi_position_templates` | **30 行** —— 六职位 × 五条,每职位权重合计 100 |
| `positions` | **6 行** —— MD / CFO / CTO / CCO / LEAD-ACC / LEAD-WH |
| `assign_position_kpis()` | **完整** —— 复制模板、五道按名拒绝 |
| `score_kpi_entry()` | **完整,连封顶机制都有** —— 0–5、judged/computed、cap + reason |
| `kpi_employee_rollup` | **完整** —— 加权分、performance%、未打分不算 0 |
| `my_kpi_entries` | **完整** —— 本人看自己五条,分数到周期关闭才可见 |
| `/hr/kpi` | **在线** —— 组织记分卡、联动矩阵、具名缺席 |
| fixture 146 | **在** —— 复制而非引用,已证 |
| `kpi_cycles` | **0 行** |
| `kpi_entries` | **0 行** |

> ★★ **也就是说:打分引擎【整个是好的】,而它从来没有被任何一块屏幕碰过。**
> 全库 grep `score_kpi_entry` 与 `assign_position_kpis` 在 `app/` 下 **零命中**。★★

**真正缺的五样(这一刀补的就是这五样):**

1. **没有周期** —— `kpi_cycles` 0 行,没有月份可以录进去;
2. **没有条目** —— `kpi_entries` 0 行,没有人身上挂着那五条;
3. **六个人里四个没有职位**(Vince / Sandra / Phua / Fu Sheng,`position_id IS NULL`),
   而 `assign_position_kpis` 对他们抛 `EMPLOYEE_HAS_NO_POSITION` ——
   **员工级 roll-up 因此卡在六分之二**;
4. **`kpi_entries` 没有反馈字段** —— 只有 `evidence_note`,而 Tim 要三样;
5. **0–5 刻度与封顶规则只活在这份文档里**,不是数据、也不在文案里 ——
   而 Tim 要求它出现在【她打分的那一刻】眼前。

## 13.2 ★ 停止闸那一轮:Tim 的裁定逐条(2026-09-05)

**委托书要求"问题连同推荐答案一起交上去,等他回话再动手"。十六个问题,
十六条裁定,全部照录 —— 结论与理由都记,因为下一个读的人要能看出【为什么】。**

| # | 问题 | Tim 的裁定 |
|---|---|---|
| Q1 | 「六个人的入职日都是 2026-09-01」是否包括 Choo Er 与 Tim? | **只写四个占位行。** Choo Er(2026-08-01)与 Tim(2026-08-11)不动 —— 「我不知道其中两个是真的」 |
| Q2 | 其余占位字段 | `work_category`:Fu Sheng = shopfloor,其余五人 office · `employment_type`:六人全 full_time · 试用期:六人都不在,`probation_end_date` 留空 · **`residency_status`:见 13.3** |
| Q3 | Phua 的角色是 operations,职位却是 CTO | **挂 CTO。** 并在文档里写明:**职位决定他被考核哪五条,角色决定他看得见什么 —— 两者不必一致,也都不算错** |
| Q4 | 2027 年假期 | **全部 12 行载入**,记下 MOM 来源与取用日期。「不自己算农历与回历日期是对的」 |
| Q5 | `holiday_key` + `is_in_lieu` | **批准。** UI-1 读键,工作日计算读日期。**文档写下 UI-1 将来读什么,代码一行都不建** |
| Q6 | 周六算不算工作日 | **保持五天工作周。** 仓库平时不上周六,赶工时有周末加班 —— **但那是【加班】,不是"哪几天算工作日"的改变**。把周六变成工作日会让 Fu Sheng 每次请假被多扣一天。**只报告加班现状,不设计、不建表、不建屏** |
| Q7 | 谁能看见分数 | **读权限原样不动。不加自我打分的守卫** —— 它会把 admin(Tim 自己)一起挡住,而这是政策问题不是 bug。**报告里要明说 Vince、Tim、Sandra 各自都能给自己打分**,并进人工走查清单 |
| Q8 | `closed` 一个 flag 干了冻结与揭晓两件事 | **★ 两半都批准 ★** 拆成 `locked_at`(冻结)与 `status='closed'`(揭晓)。**并且 M3 关口锁住第 1–3 个月,不是只锁第 3 个月 —— 一道过后还能靠改第 1 个月推翻的关口,不是关口** |
| Q9 | 周期哪来 | **迁移里播六个**:2026-09 → 2027-02,M3 在 2026-11,M6 在 2027-02。**这一刀不建"建周期"的界面** |
| Q10 | 条目何时生成 | **迁移里生成六人 × 九月**,让每个人上线第一天就在 `/me` 上看见自己那五条。后面五个月给一个显式的生成动作 |
| Q11 | 反馈字段 | **加 `feedback_note` 与那个参数。** 「你说的 DROP+CREATE 在同一事务里是对的 —— 那正是预检存在的意义,**不要绕过它**」 |
| Q12 | 刻度与封顶规则放哪 | **`kpi_score_rubric`,数据,逐格抄自原表打分页(含否决那一栏)。** 与假期同一条论证:打分的规则必须能不发版就改正 |
| Q13 | 组织 KPI 打不打分 | **这一刀不打分、不做 roll-up。** O1–O5 保持描述性。要做需要它自己的定义和它自己的一刀 |
| Q14 | 屏幕放哪 | `/hr/kpi/score`;`/hr/kpi` 仍是报告体 |
| Q15 | `due_date` | **告知性的,代码不强制任何节奏** |
| Q16 | 跑长了怎么办 | **停止点现在就选定,不是跑到一半才发现**:先落第一步、第二步与第三步的【数据】那一半,**必要时推迟打分屏幕** —— 九月没过完谁也打不了分,所以屏幕有一个月的余量,数据没有 |

### ★ 勘察推翻的八条前提(Tim 全部接受)

1. **「那四个人的假期余额现在是错的」—— 假的。** 累积从
   `date_trunc('month', hire_date)` 起算,而 `2026-09-04` 与 `2026-09-01`
   **是同一个月**:两者算出的余额逐位相同(今天 0 天,12-31 时 8 天;
   Fu Sheng 6 天)。**档案是错的,余额不是。**
2. **「零头月怎么取整要问 Tim」—— 树里早就答了。**
   `accrued_annual_leave_detail` 抬头:**「入职当月算整月;某个月要满了才计入」**。
   9 月 15 日入职的人拿整个 9 月,而那个月要到 10 月 1 日才计入。**没有问他。**
3. **「建一张公共假期表」—— 它 2026-08-02 就在了**,而且已经是数据、已经能不发版
   维护、已经被 `is_business_day` / `calculate_leave_days` / `fx_rate_asof` /
   两张日历页读着。
4. **「查一下逢周日顺延周一处理了没有」—— 处理了**,而且是作为【数据】(三行补假),
   不是逻辑。另有 `hr_alerts` 两支告警盯着"哪一年没排"。
5. **「三十条 KPI 载入了没有」—— 载入了**,30 条模板 + 5 条组织 KPI。
6. **「归 HR 评估机制还是另起」—— Tim 自己 2026-08-29 已经裁过**(本文 §12.2:
   **另起,两者并存**)。没有再问一遍。
7. **「gm 不持 view_pay / view_identity」—— 对,但不完整**:
   **gm 同时持有 `module.hr.view` + `module.hr.edit` + `data.view_reviews`**,
   也就是 **Vince 看得见每个人的分数,而且改得动**。
8. **「六个人的 HR 字段都是占位值」—— 只有四个**。Choo Er 那行是真数据,
   Tim 那行是另一种(TEST 数据)。

## 13.3 ★ 一次按名的停止:Tim Chen 的 `residency_status`

Tim 在补充裁定里给了六个人的居留身份,并写明:**「用这一列已有的词汇表。
若 PR / EP / citizen 里有哪一个今天没有对应的值,就停下来报告,不要发明一个,
也不要把这一列顺手放宽。」**

**逐条对照(实测 `employees_residency_status_check`):**

| 人 | Tim 给的 | 列里的词汇 | 处置 |
|---|---|---|---|
| Vince Goh | citizen | `citizen` ✓ | 已写 |
| Sandra Yap | citizen | `citizen` ✓ | 已写 |
| Cheng Siong Phua | citizen | `citizen` ✓ | 已写 |
| Fu Sheng Wong | PR | `pr` ✓ | 已写 |
| Choo Er Teh | WP | `work_pass` ✓ | **本来就是**,不动 |
| **Tim Chen** | **EP** | —— | **★ 停下,没写 ★** |

> ### ★ 为什么 EP 这一格停了,而它【不是】词汇表缺一个值
>
> **EP 在这套模型里是一种 work pass**:`residency_status = 'work_pass'`
> 加上 `work_pass_type = 'EP'`(`work_pass_type` 是自由文本,Choo Er 存的是 `WP`)。
> **所以词汇不缺。**
>
> **缺的是一个我没有的日期。** 表上有一条约束:
>
> ```sql
> CONSTRAINT employees_work_pass_shape CHECK (
>     residency_status IS DISTINCT FROM 'work_pass'
>     OR (work_pass_type IS NOT NULL AND work_pass_expiry_date IS NOT NULL))
> ```
>
> 把 Tim 标成 `work_pass` 就必须同时给出 **`work_pass_expiry_date`**,
> 而 Tim 没有给。**给一张准证编一个到期日,会让 `hr_alerts` 的
> `work_pass_expiry` 那一支照着一个假日期去提醒或不提醒** ——
> 而它看起来和一个真日期一模一样。
>
> **宁可空着,不可编。** 需要 Tim 补两样:准证类型(`EP`)与**到期日**。

**顺带一个勘察发现,不属于本刀但发号之前该知道:
Choo Er 的 `work_pass_expiry_date` 是 `2026-08-10` —— 已经过期 26 天。**
要么那是待更新的旧数据,要么她的准证真的需要处理。C-2 不碰它(我没有她的真实准证数据)。

## 13.4 这一刀建了什么

### 数据库(一支迁移,`2026-09-05-c2-hire-dates-holiday-identity-and-kpi-entry.sql`)

| | 做了什么 |
|---|---|
| ① 六个人 | 四行入职日 → 2026-09-01 · 四行居留身份 · 四行挂职位 · 清掉占位备注 · **反向断言 Choo Er 与 Tim 的入职日没被动** |
| ② 假期 | 见 `docs/public-holidays-and-working-days.md` |
| ③-a | `kpi_entries.feedback_note` |
| ③-b | `kpi_cycles.locked_at` + `locked_by` + 形状约束 |
| ③-c | `kpi_score_rubric`(6 行,RUNTIME CONFIG) |
| ③-d | `score_kpi_entry` **DROP + CREATE**:收下 feedback,认 `locked_at` |
| ③-e | 六个周期 2026-09 → 2027-02,M3 = 2026-11,M6 = 2027-02 |
| ③-f | 六人 × 九月 = **30 条条目**,走 `assign_position_kpis`(**不手写 INSERT**) |

> **★ ③-f 为什么绕了一圈去借身份 ★** `assign_position_kpis` 要
> `module.hr.edit`,而 psql 里 `auth.uid()` 是空的。所以迁移按 fixture 146 的
> 同一条路,把会话身份设成 **Tim 自己的账号**(admin,持该权限,而且这支迁移
> 确实是他在跑),`set_config(..., true)` 事务局部、提交后不残留。
> **在迁移里另写一份 INSERT 会是第二份复制实现,而两份实现一定会漂开。**

### 界面

| 文件 | 是什么 |
|---|---|
| `app/hr/kpi/score/page.tsx` | 月份选择器(**无默认值**)· 刻度表 · 缺席名单 · 网格 |
| `app/hr/kpi/score/ScoreEditor.tsx` | CONV-2 的 A 型可编辑网格,七列 |
| `app/hr/kpi/score/GenerateMissing.tsx` | 后面五个月的显式生成动作 |
| `app/hr/kpi/score/actions.ts` | 两个 server action + 错误码翻译 |
| `lib/modules.ts` | 导航项,**挂在 `module.hr.edit` 上,不是 view** |

### ★ 三条设计判断,连着理由记下来

**① 月份永远不默认成当月。** 九月三十号傍晚打开这一屏的人,可能在补八月,
也可能在录九月。**系统猜错的那一次,分数会落在错的月份上,而错的月份看起来
和对的月份一模一样。** 所以没有 `?cycle=` 就不画表,只画选择器和一句话。

**② `score_kind` 在这一屏恒为 `judged`,这是一个判断,不是偷懒的默认值。**
§10.2 要求算出来的分与人判的分在数据里分开,而**本屏的每一分都是人判的**。
`computed` 那一支要求 `computed_basis` 说出它算的是什么,而今天没有任何一条 KPI
接着一个真的计算 —— 给 Sandra 一个 judged/computed 下拉,只会让她在两个都不真的
选项之间挑一个,然后为了过约束去编一句 basis。**那才是把 §10.2 变成一个标签。**

**③ 加权分当场算给她看,不是保存之后才刷新出来。** 算式逐字照原表
(分 ÷ 5 × 权重,封顶后取 `LEAST`),与 `kpi_employee_rollup` 和
`score_kpi_entry` 里那两处是**同一个式子**。

### ★ 权限:读得进来 ≠ 改得动

导航项挂 `module.hr.edit`(auditor 只有 view,不该看见一个通往一排会被 42501
掉的钮的链接);**页面自己再判一次** `can('module.hr.edit')`,直接敲 URL 进来的人
落到只读并看见一句说明。**两道都要 —— 注册表只是界面的门,RLS 才是那扇门。**

### ★ 今天谁能给自己打分(Q7,Tim 已裁定不加守卫)

`score_kpi_entry` 要 `module.hr.edit`,而持有它的角色是 **admin / cco / gm / hr**。
六个人里:

* **Sandra(cco)** —— 她是录入人,也是被考核人 → **能给自己打分**;
* **Vince(gm)** —— 能看每个人的分,也**能给自己打分**;
* **Tim(admin + cfo)** —— 同上。

**Tim 的裁定是不加守卫**(它会连 admin 一起挡住,而这是政策问题不是缺陷)。
**已进 `docs/manual-walk-list.md`。**

## 13.5 ★ 冒烟抓到的那一条:一根【只有在系统坏着时才通过】的针

**这一条不是关于 KPI,是关于断言。**

`/hr/kpi` 有两条内容断言,第二条盯的是 `kpi.staffingGap` ——
「六个职位里只有几个有人」那句**具名缺席**。它是 KPI-1 立的,而且立得对:
当时六个职位只有两个挂了人,一张只显示两个人、什么都不说的 roll-up
**看起来像是全部**。

**C-2 把六个职位全部挂上了人。** 于是 `page.tsx` 里那个 `vacant.length > 0`
不再成立,那句话**正确地不再渲染**,而断言当场变红:

```
✗ /hr/kpi (/hr/kpi) → HTTP 200
    内容断言未通过:The roll-up below therefore covers only the positions that are filled…
```

> ### ★ 那根针从这一刀起,断言的是【一个缺陷】
> 它只有在「还有人没挂职位」的时候才成立。
> **一条只有在系统坏着的时候才通过的断言,比没有断言更坏** ——
> 因为它会在系统被修好的那一天变红,而红的样子和"有人把功能弄坏了"一模一样。
>
> 这与 AGENTS.md 那条「一个永远无法被满足的判据是一个坏判据」是同一族,
> 只是方向反过来:那一条说的是**从来就满足不了**,这一条是**被修好之后
> 才变得满足不了**。前者写下来的那天就能发现,后者要等到修好那天。

**换法:换成 `kpi.staffingCount`**(「N of M positions have an employee attached.」),
它是**无条件渲染**的,所以这根针是死的;而它守的是同一条原则的另一半 ——
**分母看得见**。一张只列出几个人的 roll-up,只有在旁边写着 `6 of 6`
的时候才不会被读成全部。

**两处实现上的小心:**
* 这句文案以 `{filled}` 开头,所以针不能像别的针那样从头取 ——
  取【最后一个 `}` 之后】那一段字面量(得到 `positions have an employee attached.`,36 字符);
* 加了一条**长度下限**(<12 字符即抛):一根空针对任何页面都成立,
  那是「空集当成通过」的另一种穿法。

**这一条【没有】被顺手删掉,而那是刻意的:** 删掉它会让"具名缺席"这条原则
在冒烟里彻底没有代表。换一根仍然守着同一条原则、而且不会变空的针,
比删掉一根碍事的针诚实。
