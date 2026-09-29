# 只读基线与 live device tree 解码

采集时间：2026-09（单次会话）
设备：OPlus / OPPO PKU110
固件：ColorOS `V16.1.0`，build `V.162c4c9_ee4651_ed3a8f`，`PKU110_16.0.10.501(CN01)`
平台：Android 16（API 36），kernel `6.6.118-android15`
序列号：`[REDACTED]`

> 以下数值全部来自本机实读。除「允许写入的四个节点」一节所述接口外，采集过程未写入任何节点。

---

## 1. 电池基线（只读）

| 项目 | 值 | 说明 |
| --- | --- | --- |
| `battery_type` | `silicon_1` | 模块的机型门禁之一 |
| `battery_cc` | 540 | 循环计数 |
| `battery_fcc` | 5558 | 满充容量（mAh 量纲） |
| `battery_soh` | 94 | |
| `design_capacity` | 6100 | |
| `battery_rm` | 3284 | 剩余容量 |
| `vbat_uv` | 3250 | **关断阈值**，非实时电压 |
| `gauge_vbat` | 4074 | 实时电芯电压（mV） |
| `chip_soc` | 71 | |
| `power_supply.capacity` | 74 | Android 层电量百分比 |
| `power_supply.temp` | 315 | 31.5 °C（单位 0.1 °C） |
| `power_supply.status` | `Discharging` | 未接充电器 |

`vbat_uv` 与 `gauge_vbat` 是两个不同概念：前者是当前生效的**关断阈值**，后者是**实时电压**。运行时 override 改变的是前者。本文档中所有「voltage」若未特别说明均指阈值（mV）。

### deep discharge 计数器（只读，本项目从不写入）

| 项目 | 值 |
| --- | --- |
| `deep_dischg_counts` | 3096 |
| `deep_dischg_count_cali` | 0 |
| `deep_dischg_ratio_thr` | 30 |
| `super_endurance_mode_status` | 0 |
| `super_endurance_mode_count` | 0 |

这些是电池的历史真实记录。本项目不写入它们中的任何一个，也不写入任何会间接调用 gauge 侧持久化接口的节点。

---

## 2. STOCK votable 状态

```
GAUGE_TERM_VOLTAGE:
  READY_VOTER               en=0 v=0
  DEEP_COUNT_VOTER          en=1 v=3250
  effective = DEEP_COUNT_VOTER (Max) v=3250

GAUGE_SHUTDOWN_VOLTAGE:
  READY_VOTER               en=0 v=0
  SPEC_VOTER                en=1 v=2750
  DEEP_COUNT_VOTER          en=1 v=3200
  SUPER_ENDURANCE_MODE_VOTER en=1 v=3250
  effective = SUPER_ENDURANCE_MODE_VOTER (Max) v=3250

TARGET_TERM_VOLTAGE:      effective = DEEP_COUNT_VOTER     v=3250
TARGET_SHUTDOWN_VOLTAGE:  effective = DEEP_COUNT_VOTER     v=3200
```

`type=Max` 表示该 votable 在多个 voter 之间取**最大值**。这解释了为什么当前有效关断阈值是 3250 而不是 SPEC 的 2750 或 DEEP_COUNT 的 3200：`SUPER_ENDURANCE_MODE_VOTER` 投出了最高的 3250。

`TARGET_*` 是驱动内部的目标值，不是独立可写接口，本项目不写入。

开始测试前两个 debug-force 节点的状态：

```
force_val    = 3150 / 3100   （上一次会话遗留的数值，不被清零）
force_active = 0    / 0
```

**`force_active` 均为 0**，说明没有其他软件正在占用该接口。若其中任一为 1，本项目会直接停止而不是覆盖。

> 注意 `force_val` 在未生效时仍保留旧值。因此恢复 OEM 的策略是清除 `force_active`，而**不是**把 `force_val` 写回 0 — 后者既不是必要操作，也会多产生一次无意义的写入。

---

## 3. live device tree 解码

节点根：

```
/sys/firmware/devicetree/base/soc/oplus,mms_gauge
```

`/proc/device-tree` 是指向 `/sys/firmware/devicetree/base` 的 symlink；脚本使用真实路径，避免 `find` 默认不跟随 symlink 造成的误判。

Device tree 的 u32 cell 为 **big-endian**，以下数值均已按大端解码。

### 3.1 `deep_spec` 系列

| 属性 | 解码结果 | 说明 |
| --- | --- | --- |
| `deep_spec,uv_thr` | `2750` | 最低关断阈值，与 `SPEC_VOTER` 一致 |
| `deep_spec,count_thr` | `50` | 深放计数阈值 |
| `deep_spec,vbat_soc` | `20` | |
| `deep_spec,volt_step` | `20` | |
| `deep_spec,ddrc_strategy_name` | `"ddrc_curve"` | 字符串 |
| `deep_spec,count_step` | `0 10 0 350 12 1 450 15 2 530 20 3` | 12 个 u32 |
| `deep_spec,term_coeff` | 见下表 | 21 个 u32 = 7 行 × 3 |
| `deep_spec,support` | 存在（空属性） | |

#### `deep_spec,term_coeff`（7 行 × 3 列）

| term voltage | 系数 | 索引 |
| --- | --- | --- |
| 3040 | 800 | 4 |
| 3059 | 800 | 4 |
| 3060 | 800 | 4 |
| 3070 | 800 | 4 |
| 3150 | 900 | 6 |
| 3250 | 1000 | 9 |
| 3350 | 1100 | 10 |

第 1 列的 7 个数值 `{3040, 3059, 3060, 3070, 3150, 3250, 3350}` 与第 4 节 DDRC 曲线表中「term 电压」列出现过的全部取值**完全一致**。这交叉印证了第 4 节对列含义的判读。

#### `deep_spec,ddbc_curve`（子节点）

温度键为 `deep_spec,ddbc_temp_{cold,cool,normal,warm}`，每个 6 个 u32：

| 温度档 | 值 |
| --- | --- |
| cold | `500 3200 5  10000 3150 2` |
| cool | `500 3250 5  10000 3200 2` |
| normal | `500 3350 5  10000 3300 2` |
| warm | `500 3350 5  10000 3300 2` |

`oplus,temp_range = [-100, 50, 200]`（首值为有符号 32 位 `4294967196`，即 -100），`oplus,temp_type = 0`。

这是 DDBC（deep discharge 补偿）曲线，与本项目覆盖的 DDRC 是两个不同机制。本项目**不覆盖** ddbc。

### 3.2 `ddrc_strategy` 策略表

```
oplus,temp_type  = 0
oplus,ratio_range = 20 30 50 70 90
oplus,temp_range  = [-50, 100, 350]      # 单位 0.1 °C
```

5 个边界值划分出 6 个 ratio 档位，对应 6 个 `strategy_ratio_range_*` 子节点；每档下再按 4 个温度档 `strategy_temp_{cold,cool,normal,warm}` 给出曲线。

每行 4 个 u32。以 `mid_high / normal` 为例：

```
0 3000 3040 0
50 3100 3150 1
100 3200 3250 2
150 3300 3350 3
```

结合 §3.1 的交叉印证，列含义判读为：

| 列 | 含义 |
| --- | --- |
| 1 | 该行的触发阈值（判读为深放计数类阈值；本项目不依赖该列） |
| 2 | **shutdown 电压（mV）** |
| 3 | **term 电压（mV）** |
| 4 | 行索引 |

第 1 列的确切语义（具体对应哪个计数器、是否有缩放）尚未从公开源码确认，本项目**不依赖**它做任何判断，仅依赖第 2、3 列。

#### 全部 `strategy_temp_normal` 曲线

| ratio 档 | 行（shutdown / term） |
| --- | --- |
| `min` | 3000/3040, 3000/3040, 3100/3150, 3200/3250, 3300/3350 |
| `low` | 3000/3040, 3000/3040, 3100/3150, 3200/3250, 3300/3350 |
| `mid_low` | 3000/3040, 3000/3040, 3100/3150, 3200/3250, 3300/3350 |
| `mid` | 3000/3040, 3100/3150, 3200/3250, 3300/3350 |
| `mid_high` | 3000/3040, 3100/3150, 3200/3250, 3300/3350 |
| `high` | 3000/3040, 3100/3150, 3200/3250, 3300/3350 |

`strategy_temp_warm` 的取值与 `normal` 相同。

#### 出现的全部唯一 (shutdown, term) 组合

| shutdown | term | 出现在 |
| --- | --- | --- |
| 2750 | 3059 | 仅 cold 档 |
| 2900 | 3060 | 仅 cold / cool 档 |
| 3010 | 3070 | 仅 cold / cool 档 |
| **3000** | **3040** | normal / warm，所有 ratio 档 |
| **3100** | **3150** | normal / warm，所有 ratio 档 |
| 3200 | 3250 | normal / warm，所有 ratio 档 |
| 3300 | 3350 | normal / warm，所有 ratio 档 |

---

## 4. OEM pair 存在性验证（关键结论）

协议要求先确认两个电压对在本机 live OEM 曲线中**确实存在**，然后才允许做成模块档位。

| 目标 | 要求 | 实测结果 |
| --- | --- | --- |
| BALANCED | 3100 / 3150 | **存在** ✅ |
| FULL_OEM | 3000 / 3040 | **存在** ✅ |

两个 pair 都出现在全部 6 个 ratio 档的 `strategy_temp_normal` 与 `strategy_temp_warm` 表中。因此 FULL_OEM 档位在本固件上被允许保留。

模块中的 `dt_has_pair()` 会在运行时**重新扫描** live DT 来确认这一点，而不是硬编码结论；一旦固件更新导致该 pair 消失，FULL 会被自动拒绝并回落到 STOCK。

### 一个重要细节：本项目只扫描 `strategy_temp_normal`

`dt_has_pair()` 只检查 `strategy_temp_normal`。这是刻意的保守选择：

- 低温档（cold/cool）的曲线**本来就允许**更低的值，例如 cold 档存在 `2750/3059`。这是 OEM 在低温下自己的策略，与本模块无关。
- 若把 cold 档也算作「pair 存在」的证据，就等于用一个仅在低温下成立的策略去授权常温下的覆盖，属于扩大授权范围。
- 因此判定基准设为常温档，这是最保守的一档。

---

## 5. 采集方法

```sh
# 只读基线
su -c 'sh scripts/device-readonly-audit.sh'

# device tree 原始 dump（递归，含子节点）
su -c 'sh scripts/device-dt-dump.sh'

# PC 端解码（自动处理 big-endian u32 与 ASCII）
sh scripts/decode-dt.sh audit/raw/dt-dump.txt
```

`scripts/device-dt-dump.sh` 使用 `find -type f` 递归遍历，因为 DDRC 曲线位于子节点（`deep_spec,ddbc_curve/`、`ddrc_strategy/strategy_ratio_range_*/`）中，非递归会漏掉全部曲线数据。
