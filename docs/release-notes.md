# 发布说明(给测试者)· Release notes (for the people testing)

> **这份文件从 v1.4.4 开始记。** 在它之前的版本号消耗在各自的切次报告与提交信息里,
> 没有一份面向使用者的合并说明 —— 而 BTN-3 / BTN-3b 两刀干脆没有写、也没有消耗版本号。
> **写下来的理由:六个人不会去读提交信息。**
>
> **★ 2026-09-07:此前的 v1.4.4 与 v1.4.5 两份【一份都没有发出去】。**
> 它们分六刀讲了同一批改动,而没有人会经历六次改动 —— 打开系统的是同一次。
> 所以它们**被下面这一份合并的 v1.4.5 取代了**,版本号不动。
> 用英文写,因为它是要直接转发给人的那一份。

---

## v1.4.5 — Buttons, everywhere, and one real change to how deleting works

**2026-09-07.**

> This note replaces the two earlier button notes. Neither of those was ever sent,
> so there is nothing to read before this one. Everything below is what you will
> see when you next open the system.

---

### ★ The one thing that behaves differently

* **Removing a step inside a task now asks first.**
  It used to happen the instant you clicked. Now a dialog appears, names the step,
  and says plainly that this removal is permanent: the record leaves the database
  and no copy is kept anywhere.

  > **This is worth knowing once:** it is the only place in the system where
  > "delete" really destroys something. Everywhere else, a deleted record is still
  > there and simply marked as deleted. That dialog is the only place you are told
  > the difference.

---

### Confirmations

* Where the browser's own grey pop-up used to appear, you now get the system's own
  dialog — and it **names the thing you are about to act on**, instead of asking
  "Are you sure?" about nothing in particular.
* Where a reason is required, **the confirm button stays unavailable until you type
  one**, rather than letting you press it and then complaining. With a reason
  typed, pressing Enter confirms.

### What buttons look like now

* **Buttons look the same throughout the system.** The blue "New …" at the top of a
  list, "Cancel" next to "Save" on a form, "Export" and the CSV / PDF links in
  report headers, the page arrows at the foot of a long list, and the "Edit" beside
  each row of a table — all of them are now the same set of buttons.
* **A button that destroys data carries a solid bar down its left edge. A button
  that undoes something carries a dashed bar.** Undo means the data stays and is
  only reversed or marked. You can tell the two apart without relying on colour.
* Some buttons labelled "Delete", "Cancel" or "Remove" carry the **dashed** bar,
  because what they do is reversible — a role, a leave request, a customer contact.
  **That is deliberate, not an oversight.**
* **"Cancel order" on a sales order is now the red, destructive kind**, while
  "Confirm" and "Close" beside it are not. They used to look identical.
* The amber buttons for the GST correction, the inventory hold and the retention
  release are now ordinary buttons. They neither destroy nor undo anything.
* **A button you cannot use is grey with dark text, not faded.** The intent is
  "clearly switched off" rather than "possibly still loading". A couple of them no
  longer show the "forbidden" cursor when you hover.
* At the ends of a list, **the greyed-out page arrow now matches the live one** —
  same size, same shape.
* Deleting a rate on the exchange-rate page no longer opens the browser's grey
  input box to ask why. It asks in the system's own dialog, and says which rate.

### These are still links

* Every one of those buttons is still a link wherever it always was.
  **Middle-click, "open in new tab", "copy link address" and the back button all
  work exactly as before.** If any of them has stopped working, that is a bug and
  worth reporting.

### Screen readers

* The arrows that move the calendar a month backwards or forwards now say which
  one they are, instead of announcing a bare symbol.

### Where you will still see a mix, on purpose

* **Some things look like buttons and are not**, so they were left alone: the
  coloured status chips beside assays and metal content; the row of tabs at the top
  of the leave, settings and deleted-records pages; the filter chips on the
  calendar; and the large clickable cards on the reports and pricing pages.
  Making them look like buttons would suggest they perform an action, and they
  do not — they show a state, or take you somewhere.
* On the metal-price forms, the "Save" button keeps its own look, because it
  turns amber when a price looks anomalous. That colour is a separate open question
  and was deliberately not touched here.

### What should NOT have changed

* **What any button does.** Nothing was rewired: same destination, same form, same
  submission. If a button does something different from before, that is a bug.
* **The phone layout.** Nothing here was meant to change how a page sits on a
  phone. If a page now needs dragging sideways to read, please report it.
