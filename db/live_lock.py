# -*- coding: utf-8 -*-
"""db/live_lock.py —— 【一次只有一个东西对着线上库跑】(FIX-3,2026-08-23)

════════════════════════════════════════════════════════════════════════════
【为什么它是一个机制,而不是又一行文档】

规矩本来写在 `docs/concurrency-one-tree-one-smoke.md` 里:
**gate 或冒烟在跑的时候,不要单独跑 `check_mirrors.py`。**
那份文档是第一次事故之后写的,而**同一条规矩被同一个 agent 破了第二次**(GO-4):
`check_mirrors.py` 被单独起来,把 ~14,000 行重放推过连接池,超时;
`pkill` 之后**库那一侧还留着一个 613 秒的 `idle in transaction`**,
最后用 `pg_terminate_backend` 收的尾。

本仓库对这种事有一条成文的处置,而且已经用过三次
(OPS-7 用脚本替掉"记得检查 B1 与 is_system";`wait_for.sh` 替掉"记得给等待加上限";
`run_detached.sh` 替掉那段"记得只认脚本自己的退出码"的样板):
**一条被破了两次的规矩,不再是文档,是一个机制。** 这个文件就是那次替换。

════════════════════════════════════════════════════════════════════════════
【它怎么工作】

* `db/gate.py` 与 `scripts/smoke-routes.mjs` 在**整个运行期间**持有这把锁;
* `db/check_mirrors.py` 在启动时**发现锁被持有就拒绝开跑**,并说出
  【是谁持着、从什么时候起】。**拒绝,而不是等待** —— 一个默默阻塞的脚本
  在屏幕上与挂死是同一样东西(这条规矩本文件的兄弟 `wait_for.sh` 抬头也写着)。
* **释放必须包含失败与中断**。一把能在崩溃后活下来的锁**比没有锁更坏**:
  下一个人会用手把它删掉,然后学会每次都先删它 —— 那时它就只是一段仪式了。
  所以:`try/finally` + SIGINT/SIGTERM,三条路都释放。
* **陈旧锁被识别、报告、清除,而不是被尊重。** 判据两条,都要成立才算"还活着":
  ① 记下的 pid 还在;② 那个 pid 的进程名与记录时一致(**防 pid 复用** ——
  机器重启或长时间之后,同一个号码可能属于一个完全无关的进程)。

【锁文件的格式在这里定义,是唯一的一份】Node 那一侧
(`scripts/liveLock.mjs`)读写同一个文件、同一套字段;两种语言各一份实现是
不得已(gate 是 Python、冒烟是 Node),所以**字段与判据只在本文件里定义**,
那边的注释指回这里。改了这里,那边必须跟着改。
"""
from __future__ import annotations

import json
import os
import pathlib
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone

LOCK_PATH = pathlib.Path(__file__).resolve().parent.parent / ".live-lock"


def _proc_name(pid: int) -> str | None:
    """那个 pid 现在的进程名;进程不在就返回 None。"""
    try:
        out = subprocess.run(["ps", "-p", str(pid), "-o", "comm="],
                             capture_output=True, text=True, timeout=10)
    except Exception:
        return None
    name = out.stdout.strip()
    return name or None


def read() -> dict | None:
    """读锁。返回 None = 没有锁,或锁是陈旧的(**并且已被清除**)。"""
    if not LOCK_PATH.exists():
        return None
    try:
        info = json.loads(LOCK_PATH.read_text(encoding="utf8"))
    except Exception:
        # 读不出来的锁文件不能当成"被持有" —— 那会把所有人永久挡在门外。
        LOCK_PATH.unlink(missing_ok=True)
        return None
    pid = int(info.get("pid", -1))
    name_now = _proc_name(pid)
    alive = name_now is not None and name_now == info.get("proc_name")
    if not alive:
        info["stale"] = True
        info["proc_name_now"] = name_now
        LOCK_PATH.unlink(missing_ok=True)   # 陈旧锁被清除,不被尊重
        return None if info.get("_quiet") else info | {"cleared": True}
    return info


def held_by() -> dict | None:
    """还活着的持有者;没有就 None。陈旧锁在这里被顺手清掉。"""
    info = read()
    if info is None:
        return None
    if info.get("cleared"):
        sys.stderr.write(
            f"· live-lock:清掉一把陈旧的锁(holder={info.get('holder')} "
            f"pid={info.get('pid')} 记录的进程名={info.get('proc_name')} "
            f"现在那个 pid 是={info.get('proc_name_now')})\n")
        return None
    return info


def acquire(holder: str) -> bool:
    """拿锁。**已被别人持有时返回 False,不等待。**"""
    other = held_by()
    if other is not None:
        return False
    LOCK_PATH.write_text(json.dumps({
        "holder": holder,
        "pid": os.getpid(),
        "proc_name": _proc_name(os.getpid()),
        "started_at": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
        "started_epoch": int(time.time()),
        "host": os.uname().nodename,
    }, ensure_ascii=False), encoding="utf8")
    return True


def release() -> None:
    """释放 —— **只释放自己那一把**(别人的锁不能被顺手删掉)。"""
    if not LOCK_PATH.exists():
        return
    try:
        info = json.loads(LOCK_PATH.read_text(encoding="utf8"))
    except Exception:
        LOCK_PATH.unlink(missing_ok=True)
        return
    if int(info.get("pid", -1)) == os.getpid():
        LOCK_PATH.unlink(missing_ok=True)


class Held:
    """with 语句:进入即拿锁,退出必释放 —— 正常、异常、SIGINT/SIGTERM 都释放。"""

    def __init__(self, holder: str):
        self.holder = holder
        self._prev: dict = {}

    def __enter__(self):
        if not acquire(self.holder):
            other = held_by() or {}
            sys.stderr.write(
                f"✗ live-lock:拿不到锁 —— {other.get('holder')} 从 "
                f"{other.get('started_at')} 起持有它(pid {other.get('pid')})。\n")
            raise SystemExit(5)
        for sig in (signal.SIGINT, signal.SIGTERM):
            self._prev[sig] = signal.getsignal(sig)
            signal.signal(sig, self._on_signal)
        return self

    def _on_signal(self, signum, frame):
        release()
        prev = self._prev.get(signum)
        signal.signal(signum, prev if callable(prev) else signal.SIG_DFL)
        os.kill(os.getpid(), signum)

    def __exit__(self, *exc):
        release()
        for sig, prev in self._prev.items():
            try:
                signal.signal(sig, prev)
            except Exception:
                pass
        return False


def refuse_if_held(who: str) -> None:
    """给 check_mirrors 用:被持有就【当场拒绝】并说出是谁、从何时起。"""
    other = held_by()
    if other is None:
        return
    ago = int(time.time()) - int(other.get("started_epoch", 0))
    sys.stderr.write(
        f"\n✗ {who} 拒绝开跑 —— 线上库此刻被【{other.get('holder')}】占着。\n"
        f"   持有者 pid {other.get('pid')},自 {other.get('started_at')} 起,"
        f"已经 {ago // 60} 分 {ago % 60} 秒。\n"
        f"\n   【为什么是拒绝而不是排队等】默默阻塞的脚本与挂死的脚本"
        f"在屏幕上是同一样东西。\n"
        f"   【为什么这条规矩存在】单独跑 check_mirrors 会把 ~14,000 行重放推过连接池;\n"
        f"   与 gate/冒烟撞在一起时它会超时,而 pkill 掉本机进程【不会】结束它在\n"
        f"   线上开着的那笔事务 —— GO-4 那次留下了一个 613 秒的 idle in transaction。\n"
        f"   顺带:db/gate.py 内部就会跑 check_mirrors,通常你不需要单独起它。\n"
        f"\n   等 {other.get('holder')} 跑完再来;它退出时会自己把锁放掉(失败与中断也放)。\n")
    raise SystemExit(5)
