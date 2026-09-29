# 只读基线与 live device tree 解码

采集时间：2026-09（单次会话）
设备：OPlus / OPPO PKU110，`battery_type = silicon_1`
序列号：`[REDACTED]`

> 采集使用 `scripts/device-readonly-audit.sh` 与 `scripts/device-dt-dump.sh`，两者均为**纯只读**，不含任何写入语句。

---

## 1. 设备与固件

| 项目 | 值 |
| --- | --- |
| `ro.product.model` | `PKU110` |
| `ro.product.device` | `OP5DD2L1` |
| `ro.product.vendor.name` | `PKU110` |
| Android | 16（API 36） |
| ColorOS | `V16.1.0` |
| `ro.build.display.id` | `PKU110_16.0.10.501(CN01)` |
| `ro.build.version.incremental` | `V.162c4c9_ee4651_ed3a8f` |
| kernel | `6.6.118-android15` |
| root 上下文 | `u:r:ksu:s0`（KernelSU / ReSukiSU） |

模块运行时用于机型门禁的两个条件：`ro.product.model == PKU110` 且 `battery_type == silicon_1`。

---

## 2. 电池基线

| 项目 | 值 | 单位 / 说明 |
| --- | --- | --- |
| `battery_type` | `silicon_1` | |
| `battery_cc` | 540 | 循环计数 |
| `battery_fcc` | 5558 | 满充容量 |
| `battery_soh` | 94 | % |
| `battery_rm` | 3284 | 剩余容量 |
| `design_capacity` | 6100 | 设计容量 |
| `vbat_uv` | 3250 | 当前生效的**关断阈值**（mV） |
| `gauge_vbat` | 4074 | **实时**电芯电压（mV） |
| `power_supply.capacity` | 74 | % |
| `power_supply.temp` | 315 | 31.5 °C（0.1 °C 单位） |
| `power_supply.status` | `Discharging` | |

**务必区分 `vbat_uv` 与 `gauge_vbat`**：前者是阈值，后者是实测电压。运行时 override 改变的是前者。

### 2.1 深放计数器（只读，本项目从不写入）

| 项目 | 值 |
| --- | --- |
| `deep_dischg_counts` | 3096 |
| `deep_dischg_count_cali` | 0 |
| `deep_dischg_ratio_thr` | 30 |
| `super_endurance_mode_status` | 0 |
| `super_endurance_mode_count` | 0 |

`deep_dischg_counts` 是电池的真实历史记录。`/sys/class/oplus_chg/common/deep_dischg_counts` 的写路径可能最终调用 `OPLUS_IC_FUNC_GAUGE_SET_DEEP_DISCHG_COUNT`，触碰 gauge 持久化数据。本项目**不写入它，也不写入任何可能间接影响它的节点**。

---

## 3. STOCK votable 状态

```
GAUGE_TERM_VOLTAGE
  READY_VOTER                en=0  v=0
  DEEP_COUNT_VOTER           en=1  v=3250
  effective = DEEP_COUNT_VOTER (Max) = 3250

GAUGE_SHUTDOWN_VOLTAGE
  READY_VOTER                en=0  v=0
  SPEC_VOTER                 en=1  v=2750
  DEEP_COUNT_VOTER           en=1  v=3200
  SUPER_ENDURANCE_MODE_VOTER en=1  v=3250
  effective = SUPER_ENDURANCE_MODE_VOTER (Max) = 3250

TARGET_TERM_VOLTAGE        effective = DEEP_COUNT_VOTER = 3250
TARGET_SHUTDOWN_VOLTAGE    effective = DEEP_COUNT_VOTER = 3200
```

`type=Max` 表示多 voter 取最大值。这解释了为什么当前有效关断阈值是 3250，而不是 SPEC 的 2750 或 DEEP_COUNT 的 3200 —— `SUPER_ENDURANCE_MODE_VOTER` 投出了最高的 3250。

测试前 debug-force 节点的初始状态：

```
TERM     force_val = 3150   force_active = 0
SHUTDOWN force_val = 3100   force_active = 0
```

两个 `force_active` 均为 0，说明**没有其他程序正在使用该接口**，可以安全接手。

`force_val` 在未生效时仍保留上一次会话的旧值（3150 / 3100），这说明 `force_val` 是持久保留在内存中的，**清除 `force_active` 才是恢复 OEM 的正确做法**；不需要也不应该把 `force_val` 写回 0。

---

## 4. live device tree 解码

节点路径（`/proc/device-tree` 是符号链接，脚本使用真实路径以确保 `find` 能正常递归）：

```
/sys/firmware/devicetree/base/soc/oplus,mms_gauge
```

Device tree 的 u32 cell 为 **big-endian**，以下均已按大端解码。

### 4.1 `deep_spec` 系列

| 属性 | 解码值 | 说明 |
| --- | --- | --- |
| `deep_spec,uv_thr` | `2750` | 与 `SPEC_VOTER` 一致 |
| `deep_spec,count_thr` | `50` | |
| `deep_spec,vbat_soc` | `20` | |
| `deep_spec,volt_step` | `20` | |
| `deep_spec,ddrc_strategy_name` | `ddrc_curve` | 字符串 |
| `deep_spec,support` | 存在（空值属性） | |
| `deep_spec,count_step` | `0 10 0 350 12 1 450 15 2 530 20 3` | 12 个 u32 |

#### `deep_spec,term_coeff`（21 个 u32 = 7 行 × 3 列）

| 第 1 列 | 第 2 列 | 第 3 列 |
| --- | --- | --- |
| 3040 | 800 | 4 |
| 3059 | 800 | 4 |
| 3060 | 800 | 4 |
| 3070 | 800 | 4 |
| 3150 | 900 | 6 |
| 3250 | 1000 | 9 |
| 3350 | 1100 | 10 |

第 1 列的全部取值 `{3040, 3059, 3060, 3070, 3150, 3250, 3350}` 与 §4.2 曲线表中出现过的所有 term 电压**完全一致**，交叉印证了列含义判读。

### 4.2 `ddrc_strategy` 策略表

```
oplus,temp_type   = 0
oplus,ratio_range = 20 30 50 70 90
oplus,temp_range  = [-100, 50, 200]      # 第一个值是有符号 32 位 4294967196 = -100
```

5 个边界值划分出 6 个 ratio 档位，对应 6 个 `strategy_ratio_range_*` 子节点；每档下再按 4 个温度档（`cold` / `cool` / `normal` / `warm`）给出曲线。

每行 4 个 u32：

| 列 | 含义 | 依据 |
| --- | --- | --- |
| 1 | 阈值列 | 语义未完全确认，本项目**不使用** |
| 2 | shutdown 电压（mV） | §4.3 交叉验证 |
| 3 | term 电压（mV） | §4.3 交叉验证 |
| 4 | 行索引 | 取值连续递增 |

#### 全部 `strategy_temp_normal` 曲线

| ratio 档 | 各行 (shutdown / term) |
| --- | --- |
| `min` | 3000/3040, 3000/3040, 3100/3150, 3200/3250, 3300/3350 |
| `low` | 3000/3040, 3000/3040, 3100/3150, 3200/3250, 3300/3350 |
| `mid_low` | 3000/3040, 3000/3040, 3100/3150, 3200/3250, 3300/3350 |
| `mid` | 3000/3040, 3100/3150, 3200/3250, 3300/3350 |
| `mid_high` | 3000/3040, 3100/3150, 3200/3250, 3300/3350 |
| `high` | 3000/3040, 3100/3150, 3200/3250, 3300/3350 |

`strategy_temp_warm` 与 `normal` 取值相同。

#### 全部唯一 (shutdown, term) 组合

| shutdown | term | 出现范围 |
| --- | --- | --- |
| 2750 | 3059 | 仅 cold |
| 2900 | 3060 | cold / cool |
| 3010 | 3070 | cold / cool |
| **3000** | **3040** | normal / warm，全部 ratio 档 |
| **3100** | **3150** | normal / warm，全部 ratio 档 |
| 3200 | 3250 | normal / warm，全部 ratio 档 |
| 3300 | 3350 | normal / warm，全部 ratio 档 |

### 4.3 `deep_spec,ddbc_curve`（子节点）

温度键为 `deep_spec,ddbc_temp_{cold,cool,normal,warm}`，每项 6 个 u32：

| 温度档 | 值 |
| --- | --- |
| cold | `500 3200 5  10000 3150 2` |
| cool | `500 3250 5  10000 3200 2` |
| normal | `500 3350 5  10000 3300 2` |
| warm | `500 3350 5  10000 3300 2` |

`oplus,temp_range = [4294967196, 50, 200]`（即 -100 / 50 / 200），`oplus,temp_type = 0`。

这是 DDBC（deep discharge 补偿）曲线，与 DDRC 是不同机制。本项目**不覆盖** ddbc。

---

## 5. OEM pair 存在性判定

协议要求先确认目标电压对存在于本机 live OEM 曲线中，才允许做成模块档位。

| 目标档位 | 要求 pair | 实测 |
| --- | --- | --- |
| BALANCED | 3100 / 3150 | **存在** ✅ |
| FULL_OEM | 3000 / 3040 | **存在** ✅ |

两者都出现在全部 6 个 ratio 档的 `strategy_temp_normal` 与 `strategy_temp_warm` 中，因此 FULL_OEM 档位被允许保留。

模块不硬编码这一结论：`common.sh` 的 `dt_has_pair()` 在每次应用 FULL 之前会**重新扫描 live DT**，一旦固件更新导致该 pair 消失，FULL 会被拒绝并回落到 STOCK。

### 5.1 为什么只扫描 `strategy_temp_normal`

`dt_has_pair()` 刻意只检查常温档，这是保守选择：

- 低温档（cold / cool）的曲线**本来就允许**更低的值，例如 cold 档就存在 `2750/3059`。那是 OEM 在低温下自己的策略，与本模块无关。
- 如果把 cold 档也算作「pair 存在」的依据，就等于用一个仅在低温条件下成立的策略，去授权常温下的覆盖 —— 这是扩大授权范围。
- 因此判定基准取常温档，这是最保守的一档。

---

## 6. 复现方法

```sh
# 只读基线（无任何写入）
su -c 'sh scripts/device-readonly-audit.sh'

# device tree 原始 dump（递归到子节点）
su -c 'sh scripts/device-dt-dump.sh'

# PC 端解码（处理 big-endian u32 与 ASCII 字符串）
bash scripts/decode-dt.sh audit/raw/dt-dump.txt
```

`device-dt-dump.sh` 使用 `find -type f` **递归**遍历：DDRC 曲线位于子节点（`deep_spec,ddbc_curve/`、`ddrc_strategy/strategy_ratio_range_*/`）中，非递归遍历会漏掉全部曲线数据 —— 这也是为什么早期一次非递归 dump 只看到 21 个属性。
