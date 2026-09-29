# 审计记录说明

本目录保存本项目在测试设备上取得的**脱敏**验证记录。

## 目录内容

| 文件 | 内容 |
| --- | --- |
| `README.md` | 本说明 |
| `device-baseline.md` | 只读电池 / votable 基线（脱敏） |
| `live-dt-decoded.md` | live device tree 解码结果 |
| `runtime-validation.md` | 运行时 override 测试结果 |

## 未提交的内容

`audit/raw/` **不提交**，已在 `.gitignore` 中排除。其中包含：

- 设备原始属性输出
- 未经处理的 votable / sysfs 原文
- 完整的 device tree 十六进制 dump
- 测试过程日志

原因：原始输出可能包含设备序列号、主机用户名、本机路径等与项目无关的个人信息。仓库中的记录只保留推理所必需的数据。

## 脱敏规则

提交到本目录的记录遵循以下规则：

- **设备序列号**一律写为 `[REDACTED]`，或完全省略
- **不记录** IMEI、MAC 地址、账户信息、主机名、本机用户名
- **不记录**本机绝对路径
- 记入的机型、固件版本属于公开可查的产品信息，不构成个人标识

## 记录范围

本目录只记录本次验证实际观察到的事实。任何未实测的结论都不会以 PASS 的形式出现，未验证项在根目录 `README.md` 的「未完成的测试」章节集中列出。

## 复现方式

设备端脚本本身是仓库的一部分（`scripts/`），任何人都可以在自己的设备上重新采集：

```sh
su -c 'sh scripts/device-readonly-audit.sh'
su -c 'sh scripts/device-dt-dump.sh'
bash scripts/decode-dt.sh audit/raw/dt-dump.txt
```

运行时验证脚本带有多层恢复保护，使用说明见 `scripts/device-safe-probe.sh` 顶部注释与根目录 `README.md`。
