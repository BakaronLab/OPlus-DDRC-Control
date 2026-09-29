# OPlus DDRC Control

一个针对 OPlus DDRC（Dynamic Deep Discharge Regulation / 动态深放调节）运行时策略的实验性 **KernelSU / ReSukiSU** 模块。

本模块通过 OPlus 内核的 **votable debug force** 接口，**临时**覆盖两个电池低压阈值：

- `GAUGE_TERM_VOLTAGE`
- `GAUGE_SHUTDOWN_VOLTAGE`

它**不修改**：

- boot / init_boot / vendor_boot / dtbo / vbmeta
- system / vendor / product / odm / system_ext / my_product
- `/persist` / `/metadata`
- `deep_dischg_counts` 等任何深放历史计数
- 任何 gauge 持久化数据（Qmax、循环计数、电池序列号）
- 任何充电电压、充电电流、温控参数

版本：`v0.1.0-alpha` — **alpha**。这不是一个经过长期验证的成品。

---

## 目录

- [项目是什么](#项目是什么)
- [为什么存在这个项目](#为什么存在这个项目)
- [当前支持设备](#当前支持设备)
- [档位](#档位)
- [安装](#安装)
- [恢复 Stock](#恢复-stock)
- [安全设计](#安全设计)
- [已完成测试](#已完成测试)
- [未完成的测试](#未完成的测试)
- [已知缺点](#已知缺点)
- [关于「解锁容量」](#关于解锁容量)
- [风险提示](#风险提示)
- [技术来源](#技术来源)
- [开发与审计](#开发与审计)

---

## 项目是什么

OPlus 内核的充电框架通过一个名为 **votable** 的机制决定低电量行为：多个「投票者」（voter）各自给出一个阈值，框架按策略（本机型上为 `Max`）选出最终生效值。

框架同时保留了一个**调试用强制接口**，允许直接指定生效值，绕过投票：

```
/proc/oplus-votable/GAUGE_TERM_VOLTAGE/force_val
/proc/oplus-votable/GAUGE_TERM_VOLTAGE/force_active
/proc/oplus-votable/GAUGE_SHUTDOWN_VOLTAGE/force_val
/proc/oplus-votable/GAUGE_SHUTDOWN_VOLTAGE/force_active
```

本模块把这四个节点封装成一个可安装的、带安全检查的 KernelSU 模块：

- 开机时按配置应用档位（只运行一次，无常驻进程）
- 通过 Action 按钮在档位之间切换
- 卸载时清理自己造成的运行时覆盖

由于 `force_active` 是**纯内存状态**，设备重启后一切自动恢复 OEM 行为，不留下任何需要清理的痕迹。

---

## 为什么存在这个项目

OPlus DDRC 会依据以下因素调整低电量阈值：

- 电池循环计数（CC）
- 深放计数 / 深放比例
- 温度

在测试机型上，当前生效的关断阈值为 **3250 mV**（由 `SUPER_ENDURANCE_MODE_VOTER` 投出）。而该机型自身的 OEM DDRC 曲线中，**本来就存在**更低的档位。

本模块做的事情是：允许用户把阈值临时切到这些**同样来自本机 OEM 曲线**的档位，从而在低电量区间保留一段额外的工作窗口。

它**不是**超越 OEM 设计边界的行为，也**不是**容量恢复手段。它只是把厂商运行时策略提前关闭的那部分低压工作窗口重新打开。

---

## 当前支持设备

| 项目 | 值 |
| --- | --- |
| 机型 | OPPO / OPlus **PKU110** |
| `battery_type` | `silicon_1` |
| Android | 16（API 36） |
| ColorOS | `V16.1.0` |
| build | `PKU110_16.0.10.501(CN01)` |
| kernel | `6.6.118-android15` |
| Root | KernelSU / ReSukiSU（`u:r:ksu:s0`） |

**以上仅代表本次测试的这一台设备与该固件版本。** 不代表所有 PKU110、所有 ColorOS 版本、所有 OPlus / OPPO / OnePlus 机型都兼容。

模块在运行时做两道机型门禁（`ro.product.model == PKU110` 且 `battery_type == silicon_1`），不匹配时拒绝写入任何节点。即便如此，**其他 PKU110 个体与固件版本仍未经测试**。

---

## 档位

| 档位 | TERM | SHUTDOWN | 说明 |
| --- | --- | --- | --- |
| `stock` | — | — | 不干预，使用厂商原始 DDRC |
| `balanced` | 3150 mV | 3100 mV | **默认档位** |
| `full` | 3040 mV | 3000 mV | 实验性 |

`balanced` 与 `full` 的两组数值**均来自测试机型 live device tree 中真实存在的 OEM DDRC 曲线**（见 [audit/device-baseline.md](audit/device-baseline.md)）。模块在应用 `full` 之前会重新扫描 live device tree 确认该组合仍然存在，不存在则拒绝并回落到 `stock`。

### 必须注意

> **「存在于 OEM 曲线」不等于「已验证适合一块老化电池长期放至该电压」。**

`full` 档的 3000/3040 是厂商在该机型上的 DDRC 曲线取值，但：

- 该曲线会随深放计数、温度、循环老化动态变化
- 厂商对**一块 540 循环的电池**是否应该长期工作在该档位，有自己的判断
- 本模块**绕过**了这个判断

`full` 档默认不启用，需要显式选择。

### 不允许自定义电压

本模块**不提供**任意 mV 输入。只有上述三个档位。理由：

- 用户输入的数值无法验证是否存在于 OEM 曲线中
- 任意值可能低于 `deep_spec,uv_thr`（本机型为 2750 mV），即低于厂商设定的硬性下限
- 提供一个「随便填」的输入框，等于把安全判断交给未经验证的数值

---

## 安装

### 前置条件

- 已安装 KernelSU 或 ReSukiSU
- 已取得 root（`su -c id` 返回 uid=0）
- 设备为 PKU110 且 `battery_type` 为 `silicon_1`

### 安装步骤

1. 从本仓库的 [dist/](dist/) 取得 `OPlus-DDRC-Control-v0.1.0-alpha.zip`，并核对 `dist/SHA256SUMS`
2. 在 KernelSU / ReSukiSU Manager 中选择「安装模块」并选择该 ZIP
3. 安装期间按提示选择档位

### 安装期档位选择

安装提示出现后有 **8 秒**时间选择：

| 按键 | 档位 |
| --- | --- |
| 音量下 | `STOCK` |
| 不按 | `BALANCED`（默认） |
| 音量上 | `FULL_OEM` |

如果按键检测不可用（无法访问 `/dev/input`、缺少 `getevent`、或识别失败），会输出：

```
Install-time key selection unavailable. Defaulting to BALANCED.
```

并自动选择 `BALANCED`。**任何情况下都不会自动选择 `FULL`。**

> **实现说明**：KernelSU 的 `customize.sh` 由安装器 `source` 执行，提供 `ui_print` / `abort` / `MODPATH` / `API` 等，但**不提供**音量键状态（这一点与 Magisk 不同）。本模块用 `getevent -lq` 自行实现检测。该实现已在本机实测验证（见 [audit/runtime-validation.md](audit/runtime-validation.md)）。

### 安装不会立即改变电池策略

`customize.sh` **不写入**任何 votable 节点。它只做：校验机型、选择档位、写 `config.conf`。

**安装 ZIP 本身不会立刻改变当前电池阈值。** 真正的应用发生在下次开机，或按下 Action 按钮时。

### 安装后需要重启

KernelSU 会把新安装的模块放入 `/data/adb/modules_update/<id>/`，**重启后**才合并到 `/data/adb/modules/<id>/` 并开始执行 `service.sh`。

因此在重启之前，模块不会自动生效。

---

## 恢复 Stock

有三种方式，效果不同：

| 方式 | 时机 | 效果 |
| --- | --- | --- |
| Action 按钮切到 `stock` | 立即 | 清除 `force_active`，立刻回到 OEM 行为 |
| 重启手机 | 立即（重启后） | 所有 proc 层 force 消失，OEM DDRC 自动恢复 |
| 卸载模块 | **不保证立即生效**，见下 | |

### 关于卸载（重要）

实测确认的卸载行为：

`ksud module uninstall <id>` 会创建一个 `remove` 标记文件，**不会**立即删除模块目录，**不会**立即调用 `uninstall.sh`，并且 **`force_active` 保持为 1**，运行时覆盖**继续有效**。

也就是说：

- 点击卸载后，电池阈值**不会立即恢复**
- `uninstall.sh` 是在**重启后的移除流程**中才执行的，而那次重启本身已经清除了所有 runtime force
- **真正可靠、必然生效的恢复方式是重启手机**

若需要立刻恢复，请先用 **Action 按钮切到 STOCK**，再卸载。

---

## 安全设计

### 允许写入的节点（全部，无例外）

整个项目生命周期中，除模块自身在 `/data/adb/modules/<id>/` 下的状态文件外，**唯一**允许写入的内核节点只有四个：

```
/proc/oplus-votable/GAUGE_TERM_VOLTAGE/force_val
/proc/oplus-votable/GAUGE_TERM_VOLTAGE/force_active
/proc/oplus-votable/GAUGE_SHUTDOWN_VOLTAGE/force_val
/proc/oplus-votable/GAUGE_SHUTDOWN_VOLTAGE/force_active
```

除此之外，所有 sysfs、procfs、live device tree **一律只读**。

`scripts/audit.sh` 会静态扫描全部脚本，任何指向其他路径的重定向都会导致审计失败。

### 只清除 force_active，不重置 force_val

`force_val` 在未生效时仍保留上一次写入的数值。因此恢复 OEM 的正确做法是**只清除 `force_active`**，而不是把 `force_val` 写回 0。后者既无必要，也是一次多余的写入。

### 恢复顺序固定

```
1. GAUGE_SHUTDOWN_VOLTAGE/force_active = 0
2. GAUGE_TERM_VOLTAGE/force_active     = 0
```

先关断后终止，避免中间态出现「终止阈值高于关断阈值」的反常组合。

### Ownership：绝不覆盖别人的 force

模块只在能**证明是自己设置**的情况下才清除 force，判据是三条同时成立：

1. `state/owned == 1`
2. `force_active == 1`
3. `force_val` 与记录的档位数值**完全相等**

只要发现 `force_active=1` 但数值不匹配（或没有自己的状态文件），即判定为 **EXTERNAL OWNER**，此时模块：

- **不关闭**它
- **不覆盖**它
- **不修改**它
- Action 按钮会直接报 `EXTERNAL OWNER` 并退出（退出码 1）

该路径已实测验证。

### 应用失败的自动回滚

任意一步写入失败，模块会：

1. 重新读取状态，清除自己已设置的 `force_active`
2. 整体重试**一次**
3. 再次失败则回落到 `stock` 并退出

不会无限重试，不会留下半应用状态。

### 电压裕度检查

应用任何档位前，模块会确认 **实时电压比目标关断阈值高出至少 200 mV**。

这样可以避免一种危险情形：当前电池电压已经低于要设置的关断阈值，一旦生效就会要求 gauge 立刻动作。

### 安装期不做任何运行时写入

见上文「安装不会立即改变电池策略」。

### 测试用脚本的多层恢复保护

`scripts/device-safe-probe.sh` 是项目中唯一会写内核节点的**测试**脚本。它在第一次写入之前建立三层独立保护：

| 层 | 实现 | 触发条件 |
| --- | --- | --- |
| 1 | 脚本内 `EXIT` / `INT` / `TERM` / `HUP` trap | 任何退出路径 |
| 2 | 设备端独立 watchdog（`setsid` 分离） | 15 秒未解除 |
| 3 | PC 端 watchdog（第二条 adb 连接） | 45 秒未解除 |

`setsid` 让设备端 watchdog 脱离 adb 会话：即使 PC 断开、adb 进程被杀，它仍会执行恢复。

**三层机制都只写两个 `force_active` 节点。**

---

## 已完成测试

以下为本次实际完成并观察到的结果。详细记录见 [audit/](audit/)。

| 测试项 | 结果 |
| --- | --- |
| ADB root 可用性（`su -c id` → uid=0） | **[PASS]** |
| 只读电池 / votable 基线采集 | **[PASS]** |
| 只读 live device tree 解码 | **[PASS]** |
| OEM pair 存在性验证（3100/3150、3000/3040） | **[PASS]** 两者均存在 |
| No-op force（写入等于当前有效值） | **[PASS]** |
| BALANCED 运行时接受（3150/3100） | **[PASS]** `vbat_uv` 同步变为 3100 |
| FULL_OEM 运行时接受（3040/3000） | **[PASS]** `vbat_uv` 同步变为 3000 |
| 运行时恢复到 Stock（4 次独立测试） | **[PASS]** |
| 真实 KernelSU 安装器安装 ZIP | **[PASS]** |
| 安装不触碰运行时状态 | **[PASS]** |
| 安装期按键选择（无按键 / 音量上 / 音量下） | **[PASS]** 三条分支均验证 |
| `service.sh` 应用档位（balanced） | **[PASS]** |
| `service.sh` 不干预（stock） | **[PASS]** |
| `action.sh` 档位循环与边界 | **[PASS]** |
| 外部 owner 拒绝路径 | **[PASS]** 未写入任何节点 |
| `uninstall.sh` 恢复逻辑 | **[PASS]** |
| `dt_has_pair()` 电压对判定（7 组） | **[PASS]** |
| 静态安全审计 `scripts/audit.sh` | **[PASS]** |
| Shell 语法检查（`sh -n` 全部脚本） | **[PASS]** |
| Shell 静态分析（`shellcheck -s sh`） | **[PASS]** 零告警 |
| 隐私 / 密钥扫描 | **[PASS]** |

### 关于这些 PASS 的边界

- 「运行时接受」只证明**内核接受了该参数**，`vbat_uv` 随之改变。它**不证明**电池在真实放电中会在该电压关断。
- 所有运行时测试的实时电压都在 4000 mV 以上，**从未接近** 3100 或 3000 mV。
- **重启后 `service.sh` 是否自动执行，本轮未验证**（本轮禁止重启）。

---

## 未完成的测试

**以下项目本轮完全没有测试，任何相关结论都不成立。**

### 电化学与实机行为

- ❌ 未实际把电池放电到 **3100 mV** 观察真实关断
- ❌ 未实际把电池放电到 **3000 mV** 观察真实关断
- ❌ 未做真实 shutdown test
- ❌ 未做完整 100% → 关断的能量测试
- ❌ 未测真实 Wh / mAh 增益
- ❌ 未验证长期循环寿命影响
- ❌ 未验证长期低压使用对老化的影响
- ❌ 未验证高负载低 SOC 下的 voltage sag
- ❌ 未验证寒冷环境低 SOC 行为
- ❌ 未验证高温低 SOC 行为

### 设备与固件覆盖

- ❌ 未验证其他 PKU110 个体
- ❌ 未验证其他电池老化程度
- ❌ 未验证其他固件版本
- ❌ 未验证其他 ColorOS build
- ❌ 未验证其他 OPlus / OPPO / OnePlus 机型

### 生命周期

- ❌ **未验证重启后 `service.sh` 自动执行**（本轮禁止重启）
- ❌ 未验证通过 Manager 图形界面点击卸载的完整生命周期（本轮使用 `ksud` 命令行等价路径）
- ❌ 未验证模块在 OTA 升级后的行为

---

## 已知缺点

1. **需要 Root。** 没有 KernelSU / ReSukiSU 就无法使用。

2. **只针对单一测试设备建立兼容逻辑。** 机型门禁写死为 PKU110 + silicon_1，其他设备一律拒绝。

3. **OPlus OTA 可能改变节点、曲线或驱动。** 四个 debug-force 节点是内核内部接口，不是稳定 ABI。厂商随时可能移除或改名，导致模块静默失效。

4. **降低 cutoff 可能增加低电量 voltage sag、意外关机与深放压力。** 这是该功能的固有代价，无法通过代码消除。

5. **`full` 档比厂商当前的 aging policy 更激进。** 它来自 OEM 曲线的**一个**取值，但厂商选择不把它作为当前生效值，这个选择本身携带信息。

6. **SOH / FCC 显示值可能随 term coefficient 变化。** 短时间内的 FCC 数值变化**不能**等同于真实可用容量的变化。

7. **临时 root 环境下重启后可能失去模块运行能力。** 本模块不做任何持久化 root 的尝试；如果 root 在重启后消失，模块就不运行——这是可接受的。

8. **本项目不能恢复真实化学老化已经损失的容量。** 详见下一节。

---

## 关于「解锁容量」

本模块能做的只有一件事：**重新打开厂商运行时策略提前关闭的一部分低压工作窗口。**

它**不能**：

- 修复老化
- 恢复 Qmax
- 让衰减的电芯重新变新
- 改变电芯的化学特性

真实可用能量的增加幅度**目前未知**。这个数字必须通过后续的受控放电测量才能得出，在测量完成之前，任何「增加 X%」的说法都没有依据。

已经可以确定的量级参照：测试设备当前有效关断阈值为 3250 mV（`balanced` 为 3100，`full` 为 3000）。在 3250 → 3000 mV 这段区间内，电芯实际还能放出多少电量，**取决于电池老化程度与放电电流**，不能仅由电压差推算。

---

## 风险提示

低压终止策略与电池寿命、voltage sag 和意外关机直接相关。

- 电压越低，同样负载下的瞬时压降越容易触底
- 老化电池的内阻更高，在低 SOC 高负载时更容易触发非预期关机
- 在低温环境下上述风险进一步放大

因此：

- **`full` 档是实验性的，默认不启用。**
- 本模块**不保证**任何容量、续航或寿命结果。
- 若设备出现低电量下意外关机、异常发热或其他异常，请立刻通过 Action 切回 `stock`。

本项目的作者无法为电池损坏、数据丢失或设备故障负责。

---

## 技术来源

### 公开内核源码

OPlus 充电框架的源码由 OnePlus 开源发布：

- 组织页：<https://github.com/OnePlusOSS>
- 本机型平台对应仓库：<https://github.com/OnePlusOSS/android_kernel_oneplus_sm8750>

该框架中与本模块机制相关的文件（尚未在本项目中逐行比对）：

- `oplus_sili.c`
- `oplus_configfs.c`
- `oplus_chg_voter.c`
- `oplus_strategy_ddrc.c`

> **诚实说明**：本轮验证**没有**逐行阅读上述源码。本 README 中关于 votable 机制与 DDRC 行为的描述，来源如下。

### 结论来源分布

| 结论 | 来源 |
| --- | --- |
| 四个 debug-force 节点的存在与行为 | **实机运行时测试** |
| `force_active=1` 时 `DEBUG_FORCE_CLIENT` 直接接管、绕过 `Max` 投票 | **实机运行时测试** |
| 清除 `force_active` 即可恢复 OEM voter | **实机运行时测试** |
| 生效值为 3250 mV，由 `SUPER_ENDURANCE_MODE_VOTER` 投出 | **实机只读读取** |
| `balanced` / `full` 两组数值存在于 OEM 曲线 | **live device tree 解码** |
| DDRC 曲线按 ratio × 温度分档 | **live device tree 解码** |
| 深放计数为 3096、循环计数为 540 等电池状态 | **实机只读读取** |
| `Max` 投票语义为「多 voter 取最大值」 | **实机观察推断**（未核对源码） |
| term_coeff 三列的确切语义 | **推断**：第 1 列与曲线 term 列完全吻合，第 2、3 列语义未确认 |
| DDRC 曲线第 1 列（阈值列）的确切语义 | **未确认**，本项目不依赖该列 |
| `deep_dischg_counts` 写入会调用 gauge 持久化接口 | **来自项目安全约定**，本轮未验证（也刻意不验证） |

### 未验证的推断

上面标注为「推断」与「未确认」的项目，都是**基于单台设备单次观察**得出的，没有源码级确认，也没有跨设备验证。

---

## 开发与审计

### 仓库结构

```
.
├── README.md
├── module/                   # 模块载荷（打包进 ZIP 的内容）
│   ├── module.prop
│   ├── customize.sh          # 安装期：校验机型、选档位、写 config
│   ├── service.sh            # 开机：应用档位（只运行一次）
│   ├── action.sh             # Action 按钮：档位循环
│   ├── uninstall.sh          # 卸载：清理自己的运行时覆盖
│   ├── common.sh             # 共享逻辑（唯一的节点写入点）
│   ├── config.conf
│   └── skip_mount
├── scripts/
│   ├── build.sh              # 构建 dist/*.zip 与 SHA256SUMS
│   ├── audit.sh              # 静态安全审计
│   ├── device-readonly-audit.sh   # 设备端只读基线采集
│   ├── device-dt-dump.sh          # 设备端 device tree dump（递归）
│   ├── decode-dt.sh               # PC 端大端 u32 解码
│   ├── device-safe-probe.sh       # 设备端运行时测试（带三层恢复）
│   └── host-probe.sh              # PC 端驱动
├── audit/                    # 脱敏后的验证记录
└── dist/                     # 构建产物
```

### 构建

```sh
sh scripts/build.sh
```

生成 `dist/OPlus-DDRC-Control-v0.1.0-alpha.zip` 与 `dist/SHA256SUMS`。

ZIP 的根目录直接包含模块文件（`module.prop`、`customize.sh` …），没有多余的目录层级——这是 KernelSU 安装器要求的格式。

### 静态审计

```sh
sh scripts/audit.sh
```

审计内容：

1. 全部脚本中不得出现 `fastboot flash` / `dd if=` / `/dev/block/` / `remount` / `mkfs` / `setenforce 0` 等破坏性原语
2. 内核写入只能通过 `common.sh` 中定义的四个节点变量
3. 不得出现 `system/` / `vendor/` / `product/` / `system.prop` / `sepolicy.rule` / `initrc` 等非 systemless 载荷
4. 载荷中不得有 `.img` / `.dtbo` / `.bin` / `.ko` 或任何 ELF 文件
5. 行尾必须为 LF

### 运行时测试

```sh
sh scripts/host-probe.sh check      # 只读
sh scripts/host-probe.sh noop       # 写入等于当前值的数值
sh scripts/host-probe.sh balanced
sh scripts/host-probe.sh full
```

`host-probe.sh` 会在执行前确认只有一个 adb 设备、推送脚本、开启 PC 端 watchdog，并在结束后独立复核最终状态。

**警告**：`noop` / `balanced` / `full` 会**真实写入内核节点**。仅在理解其含义后执行，并确保设备满足前提条件（SOC ≥ 60%、电压 ≥ 3800 mV、温度 15–38 °C、未充电、低负载）。

### 关于原始日志

`audit/raw/` 保存原始的、未脱敏的采集输出，**已在 `.gitignore` 中排除，不提交到仓库**。其中可能含设备序列号与本机路径。仓库中的 `audit/*.md` 是脱敏后的记录，规则见 [audit/README.md](audit/README.md)。

---

## 许可与免责

本项目按现状提供，不附带任何担保。

作者不对设备损坏、数据丢失、电池损伤或其他任何后果负责。使用前请自行确认风险，并确保设备有可用的恢复手段。

如果你的设备不是 PKU110，或者你不确定上述任一条目的含义，**请不要安装**。
