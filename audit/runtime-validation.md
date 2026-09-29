# 运行时 override 验证记录

采集时间：2026-09（单次会话）
设备：OPlus / OPPO PKU110，`battery_type = silicon_1`
序列号：`[REDACTED]`

本文件记录 runtime force 的实测结果。所有测试均在电压裕度充足、未接充电器、低负载条件下进行，单次保持 5–10 秒，测试后立即恢复。

---

## 0. 测试前提

| 条件 | 门槛 | 实测 |
| --- | --- | --- |
| SOC | ≥ 60% | 72–74% ✅ |
| 实时电压 `gauge_vbat` | ≥ 3800 mV | 4019–4074 mV ✅ |
| 温度 | 15–38 °C | 31.5–32.6 °C ✅ |
| 充电器 | 未连接 | `Discharging` ✅ |
| 初始 `force_active` | 均为 0 | 0 / 0 ✅ |

任一条件不满足时，`device-safe-probe.sh` 会在**任何写入之前**以非 0 退出码终止。

---

## 1. 恢复保护机制

在第一次写入之前建立三层独立保护：

| 层 | 实现 | 触发条件 |
| --- | --- | --- |
| 1 | 脚本内 `EXIT` / `INT` / `TERM` / `HUP` trap | 任何退出路径 |
| 2 | 设备端独立 watchdog（`setsid` 分离） | 15 秒内未收到解除标记 |
| 3 | PC 端 watchdog（第二条 adb 连接） | 45 秒内未收到解除标记 |

`setsid` 使设备端 watchdog 脱离 adb 会话，即使 PC 断开、adb 被杀，它仍会执行恢复。

三层机制**只写两个 `force_active` 节点**，从不写 `force_val`，不写其他路径。

恢复顺序固定：

```
1. /proc/oplus-votable/GAUGE_SHUTDOWN_VOLTAGE/force_active = 0
2. /proc/oplus-votable/GAUGE_TERM_VOLTAGE/force_active     = 0
```

---

## 2. 测试结果

### 2.1 No-op force — [PASS]

目的：验证接口可用，且写入「与当前有效值相同」的数值不产生任何行为变化。

| 项目 | 写入前 | 强制期间 | 恢复后 |
| --- | --- | --- | --- |
| TERM effective | `DEEP_COUNT_VOTER`=3250 | `DEBUG_FORCE_CLIENT`=3250 | `DEEP_COUNT_VOTER`=3250 |
| SHUT effective | `SUPER_ENDURANCE_MODE_VOTER`=3250 | `DEBUG_FORCE_CLIENT`=3250 | `SUPER_ENDURANCE_MODE_VOTER`=3250 |
| `force_active` | 0 / 0 | 1 / 1 | 0 / 0 |

关键结论：`force_active=1` 时有效值被 `DEBUG_FORCE_CLIENT` **直接接管**，`type=Max` 投票语义被绕过。这是本模块能生效的机制，也是它必须谨慎使用的原因。

### 2.2 BALANCED 3150 / 3100 — [PASS]

| 项目 | 结果 |
| --- | --- |
| TERM effective | `DEBUG_FORCE_CLIENT` = **3150** ✅ |
| SHUTDOWN effective | `DEBUG_FORCE_CLIENT` = **3100** ✅ |
| `vbat_uv` | **3100** ✅ |
| 保持时间 | 8 秒 |
| 恢复后 TERM | `DEEP_COUNT_VOTER` = 3250 ✅ |
| 恢复后 SHUTDOWN | `SUPER_ENDURANCE_MODE_VOTER` = 3250 ✅ |
| 恢复后 `vbat_uv` | 3250 ✅ |

`vbat_uv` 同步变化是关键证据：驱动实际采纳了该阈值，而不仅是 votable 层显示。

### 2.3 FULL_OEM 3040 / 3000 — [PASS]

前提全部满足：DT 中存在该 pair、BALANCED 已 PASS、SOC / 电压 / 温度达标、`force_active=0`。

| 项目 | 结果 |
| --- | --- |
| TERM effective | `DEBUG_FORCE_CLIENT` = **3040** ✅ |
| SHUTDOWN effective | `DEBUG_FORCE_CLIENT` = **3000** ✅ |
| `vbat_uv` | **3000** ✅ |
| 保持时间 | 8 秒 |
| 恢复后 | OEM voter 全部恢复 ✅ |

**重要限定**：测试期间实时电压始终在 4000 mV 以上，**从未接近** 3000 mV。本测试只证明「内核接受该 OEM pair」，**不构成**关断行为或容量收益的验证。

### 2.4 恢复 OEM — [PASS]

4 次独立测试（noop / balanced / full / uninstall）结束后均确认：两个节点 `force_active=0`，有效值回到对应 OEM voter，`vbat_uv` 回到 3250。

---

## 3. 模块功能验证（真实路径）

以下均通过真实 `ksud` 安装器与模块脚本执行，非 PC 侧模拟。

| 测试 | 方法 | 结果 |
| --- | --- | --- |
| 真实安装 | `ksud module install <zip>` | [PASS] |
| 安装不触碰运行时 | 安装后立即读 votable | [PASS] `force_active` 仍为 0 |
| 无按键安装 | 不注入按键 | [PASS] 默认 BALANCED |
| Volume Up 安装 | 注入合成 `KEY_VOLUMEUP` | [PASS] 选中 FULL_OEM |
| Volume Down 安装 | 注入合成 `KEY_VOLUMEDOWN` | [PASS] 选中 STOCK |
| service.sh（balanced） | 手动执行 | [PASS] 应用 3150/3100 |
| service.sh（stock） | 手动执行 | [PASS] 未写入任何节点 |
| action.sh 循环 | stock→balanced→full→stock | [PASS] |
| action.sh 边界 | full→stock | [PASS] |
| 外部 owner 拒绝 | 伪造不匹配的 `force_val` | [PASS] 报 EXTERNAL OWNER，未写入，rc=1 |
| uninstall.sh 恢复 | 应用 balanced 后执行 | [PASS] 回到 OEM |
| `dt_has_pair()` | 7 组电压对单元检查 | [PASS] 3 组存在全识别，3 组不存在全拒绝 |

### 3.1 安装期按键选择的实现依据

先做实证调研，未照搬 Magisk 模板：

- KernelSU 官方文档确认 `customize.sh` 由安装器 **source**，提供 `ui_print` / `abort` / `MODPATH` / `API` 等，但**不提供**音量键状态。
- 本机 `ksud`（v4.2.0-rc3）二进制中不存在 `getevent` / `chooseport` / `VOLUMEUP` 等字符串。
- 因此使用 `getevent -lq` 自行实现。不指定设备时它会监听全部输入设备。

设备侧实测：本机输入设备共 14 个，音量键位于 `event1`（仅 DOWN）、`event5`（仅 UP）、`event8`（UP+DOWN）。注入合成按键后 `getevent -lq` 能正确捕获。三条分支（up / down / 无按键）均验证通过。

无法访问 `/dev/input` 或缺少 `getevent` 时输出：

```
Install-time key selection unavailable. Defaulting to BALANCED.
```

并自动选择 BALANCED，**绝不**自动选择 FULL。

### 3.2 一个被测出的真实缺陷

`dt_has_pair()` 第一版使用 `printf '%04x%04x'` 拼接匹配串，导致中间缺少零填充，实际无法匹配任何 pair（表现为 FULL 被错误拒绝）。改为 `printf '%08x%08x'`（u32 是 4 字节对齐）后修正，并补充了 7 组单元检查确认修正有效。

该缺陷是 fail-closed 的（错误地拒绝 FULL，而非错误地允许），但仍然是缺陷，已修复并验证。

---

## 4. 卸载行为（实测结论）

必须如实说明，这一点与常见预期不同。

实测 `ksud module uninstall oplus_ddrc_control`：

| 观察项 | 结果 |
| --- | --- |
| 命令返回 | rc=0 |
| `/data/adb/modules/<id>/remove` | 被创建 |
| 模块目录 | **仍存在**，未删除 |
| `uninstall.sh` | **未被调用** |
| `force_active` | **仍为 1**，override 继续生效 |

结论：

- 点击卸载后，运行时 force **不会立即消失**，会持续到设备重启。
- `uninstall.sh` 在重启后的移除流程中才被执行。
- **实测确认的即时恢复方式是 Action 按钮切到 STOCK**（会立即清除 `force_active`，OEM voter 重新接管）。
- 关于重启：proc 层的 `force_active` 属于内核运行时状态，按 Linux 的 proc 状态模型不会跨内核重启保留，因此重启**预期**会清除该 force。但本项目**尚未实测** reboot 后 gauge IC 内部 term 配置是否回到 OEM 值，也未实测 `service.sh` 的 reboot lifecycle，因此**不把「重启必然恢复全部 gauge 状态」作为已验证结论**。

因此，若需要立即恢复，请先用 Action 按钮切到 STOCK，再卸载。

---

## 5. 持久化电池数据未被触碰（实测核验）

本项目的核心安全主张之一是「不修改任何持久化电池数据」。该项通过了端到端实测核验：

| 项目 | 会话开始 | 会话结束（全部测试完成后） | 结论 |
| --- | --- | --- | --- |
| `deep_dischg_counts` | 3096 | **3096** | 未改变 ✅ |
| `battery_cc`（循环计数） | 540 | **540** | 未改变 ✅ |
| `deep_dischg_count_cali` | 0 | **0** | 未改变 ✅ |
| `design_capacity` | 6100 | **6100** | 未改变 ✅ |

在本次会话中，运行时 override 被反复施加与清除至少 8 次（noop / balanced / full / action 循环 / service.sh / 外部 owner 测试 / 卸载测试），期间：

- 未执行任何 `fastboot` 操作
- 未向任何块设备或分区写入
- 未写入 `deep_dischg_counts` 或任何 gauge 持久化节点
- 未修改 `boot` / `dtbo` / `vbmeta` / `system` / `vendor`
- 未主动重启设备

### 这个证据能证明什么、不能证明什么

**能证明的**：在这些特定计数器上，本次会话没有留下任何可观察的变化。这排除了「模块直接写这些计数器」这一类副作用。

**不能证明的**：不能据此推断「运行时 override 走的是纯内存路径」或「不存在任何持久化副作用」。原因：

- 这些计数器不变，只说明**这几个特定寄存器**没有变化，不覆盖 gauge IC 内部所有可能的配置存储
- 对照公开源码：`force_active` 会触发 votable callback，`GAUGE_TERM_VOLTAGE` 的 callback 会经 `oplus_mms_gauge_set_deep_term_volt()` 下发 `OPLUS_IC_FUNC_GAUGE_SET_DEEP_TERM_VOLT`，并连带改变 FCC / SOH 系数（见 `audit/` 与 README「已确认的事实」）
- 公开源码**没有**给出「term 配置一定写入 gauge NVRAM」的证据，也**没有**给出「一定不写」的证据
- 因此 gauge IC 内部 term 寄存器的持久性属于**尚未确认**项

准确的表述应当是：**已确认没有写这些计数器；gauge IC 内部的 term 配置持久性尚未确认。**

> 注意：会话结束时 `chip_soc` 从 71 降至 60、`gauge_vbat` 从 4074 降至 3976 mV。这是设备在整个测试过程中**自然放电**的结果，与阈值的即时变化无关（阈值在测试结束前已恢复为 3250）。

---

## 6. 本次**未**验证的事项

以下内容本轮没有测试，**不作为结论**：

- 真实放电到 3100 mV 的实际关断行为
- 真实放电到 3000 mV 的实际关断行为
- 完整放电的能量（Wh / mAh）差异
- 低 SOC 下的 voltage sag
- 低温 / 高温低 SOC 行为
- 循环寿命影响
- 老化电池长期运行于低阈值的风险
- 重启后 `service.sh` 的自动执行（本轮禁止重启）
- 通过 Manager 图形界面点击卸载的完整生命周期（本轮使用 `ksud` 命令行等价路径）
- 其他 PKU110 个体、其他固件、其他机型

完整清单见根目录 `README.md`。
