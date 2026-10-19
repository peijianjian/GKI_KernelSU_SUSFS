# TB710FU 内核构建 — 工作上下文备忘（2026-10-19 会话压缩）

> 本文件是新对话/后续接手的唯一上下文入口。读完它即可继续，无需原对话。

## 一、任务目标（用户原话归纳）

- 产出 **6.1.128** 的 **AnyKernel3 zip**，用户**自己 TWRP 刷入**
- 修改对象：`GKI_KernelSU_SUSFS-dev`（用户已下载的 GitHub 项目源码，改完由用户重新上传跑 Action）
- 原料：`coloros-pad-fixes-main`（兄弟目录）里已真机验证过的 ColorOS 移植修复
- **GKI 的全部特性开关一个不少**（15 个 input），用户自己选开不开
- 不做刷机自动化、不碰 vendor_boot 打包

## 二、两个仓库的角色

| 仓库                     | 角色                                                                                          |
| ------------------------ | --------------------------------------------------------------------------------------------- |
| `GKI_KernelSU_SUSFS-dev` | **构建工厂**。上游 build.yml 产通用 GKI（gki_defconfig + bazel）。本任务加了 TB710FU 专用目标 |
| `coloros-pad-fixes-main` | **原料库**（只读）。`kernel-compat/` 下有真机验证过的配置、补丁、ABI 门禁                     |

## 三、交付物清单（全部在 GKI 仓库内）

```
.github/workflows/kernel-tb710fu.yml   49 steps / 15 inputs（未动上游 build.yml）
targets/tb710fu/
├── config/base.config                 原厂 7550 行（stock-6.1.128-ab13606743）
├── config/delta.config                pad 的 19 行增量（SYSVIPC/NS/DEVTMPFS/TMPFS/SIG_PROTECT）
├── config/abi_symbollist.raw          8490 行 TRIM 白名单（含 pad 新增 6 符号）
├── patches/0001-gloom-percpu-code.patch   9 文件 56 行（从 203KB 原补丁剥离白名单后）
├── patches/0002-sysvipc-kabi-slots.patch  task_struct KABI 槽位（保 module_layout CRC）
├── patches/ordered.list               显式顺序，冲突即 fail
├── patches/hooks/apply_oplus_hooks.py 锚点改写器（binder hook + 白名单追加）
├── scripts/prepare_config.sh          base+delta → .config → olddefconfig → 断言 → 漂移报告
│                                      并在此步把 DEFCONFIG 重定向到 $OUT_DIR/.config
├── scripts/apply_patches.sh           白名单安装 → 补丁（--batch 防挂起）→ hooks；fail-loud
├── scripts/verify_abi.sh              module_layout==0xea759d7f 哨兵 + 符号存在性 + 白名单覆盖
└── manifest.json                      版本/commit/哨兵值/排除补丁清单（自描述上下文）
```

## 四、五个关键设计决策及依据（新对话勿"纠正"这些）

1. **整份原厂 .config 作基线，不用 gki_defconfig+fragment**
   gki_defconfig 缺原厂 3840 行 "is not set"；pad configs/README 记录过踩坑：追加式 → module_layout 0xea759d7f→0x28c5e94f → 289 模块全拒载、第一屏重启。
2. **make 而非 bazel**
   bazel 的 --defconfig_fragment 装不下 7550 行；且强制 --lto=thin 与原厂 CONFIG_LTO_NONE=y 冲突。
3. **编译用原厂同代 clang（17.0.2 / clang-r487747c），但树里其实没有**
   kernel/manifest 的 android14-6.1 manifest 在 root 上 `remove-project kernel/prebuilts/clang/host/linux-x86`，
   repo sync 只拉 common/kernel/tools，不拉 clang。所以 workflow 自己装：`clang lld llvm`（+ 能拿到时用
   GitHub llvm-project 预编译）→ 「校验 LLVM 工具链」→ 编译时若有树内 clang 仍优先用它。
   历史：2026-10-19 那次 CI 挂在 `scripts/Kconfig.include:40: linker 'ld.lld' not found`，就是这么来的。
4. **ABI 门禁 = module_layout CRC 哨兵 0xea759d7f**
   289 个厂商 .ko 进不了 CI，无法逐符号比对；KMI 分支内布局冻结 → 单一哨兵足够。pad 文档：r3 也是此值。
5. **ColorOS 补丁排在 SUSFS 之后**
   SUSFS 基线快照（susfs.patch 导出）不能混入 pad 改动；且 SUSFS apply.sh 是 `|| true` 容错，pad 补丁是 fail-loud，顺序颠倒会把冲突吞掉。
   注意：Droidspaces 的 SYSVIPC kABI 补丁与 pad 0002 **功能等价但槽位不同**，两者同开会冲突（上游步骤用 `|| warning` 容错，暂未加互斥 guard——已知遗留，见第七节）。

## 五、本轮修掉的坑（已验证修复，勿回退）

| 坑                                                                                                                | 修复                                                                                                                                          |
| ----------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| heredoc 顶格破坏 YAML 块标量（AK3/EOF）                                                                           | 内容与结束符统一缩进 10 空格，YAML 还原后 bash 正确                                                                                           |
| PyYAML dump 把 `on:` 写成 `true:`、run 转义成单行字符串                                                           | 弃用 dump，从提取的 JSON 手工发射块标量格式重建                                                                                               |
| 多行 `with:` 值（cache path/restore-keys）顶格                                                                    | 改 `                                                                                                                                          |
| 准备配置在特性步骤之后 → ZRAM/BBG/BBRv3 配置写进 gki_defconfig 丢失                                               | 准备配置移到所有特性步骤之前 + DEFCONFIG 重定向                                                                                               |
| 编译无树内 clang PATH / 无 ccache                                                                                 | 已加 CLANG_BIN 探测 + CC="ccache clang"                                                                                                       |
| **`linker 'ld.lld' not found`（2026-10-19 CI 实测）**：manifest 移除 clang 预编译，树内既无 clang 也无 ld.lld/gas | 新增「安装 LLVM 工具链」（apt clang/lld/llvm + 预编译回退 + `/usr/local/bin` 链接兜底）与「校验 LLVM 工具链」门禁；prepare_config.sh 也先自检 |
| patch 无 --batch 在 CI 挂起等 stdin                                                                               | apply_patches.sh 全部 --batch，失败时 dry-run 输出冲突详情                                                                                    |
| apply_patches.sh 相对路径 cd 后失效                                                                               | 脚本入口 pwd 归一化                                                                                                                           |
| hooks 对缺失文件抛 Traceback                                                                                      | 改为友好 fail                                                                                                                                 |
| ZRAM 配置双写 + CONFIG_MODULE_SIG=n 破 ABI                                                                        | 追加步骤 ZRAM 段删除，统一由「配置 ZRAM 选项」负责                                                                                            |
| prepare_config 覆盖 hooks 追加的白名单符号                                                                        | 白名单安装移到 apply_patches.sh（hooks 之前）                                                                                                 |

## 六、本地已验证 / 未验证

**已验证**（离线静态）：

- workflow YAML 合法（15 inputs / 51 steps / on: 正常）
- 三个 shell 脚本 `bash -n`、hooks Python AST、manifest JSON
- 补丁 `git apply --stat` 结构正确（0001=9文件56行，0002=6文件40行）
- verify_abi.sh 正例（哨兵命中）/ 负例（0x28c5e94f 正确拦截，退出码1）
- prepare_config 拼接 7580 行、6 项断言全过
- 步骤顺序、DEFCONFIG 引用面、文件交叉引用

**未验证**（需第一次 Action 或真机）：

- 真实编译能否通过（本环境无网络，git ls-remote/curl 被墙）
- 新的 LLVM 安装步骤只做了 `bash -n` + 门禁失败路径测试；clang-18 编原厂配置是否会出现
  `-Wincompatible-pointer-types` 之外的新报错、CONFIG_LTO_NONE 下 clang-18 的 bpf 目标是否可用，都要看下一次 Action
- module_layout 哨兵是否会因换编译器而漂移（预期不漂：CRC 由类型/布局决定，与编译器版本无关）
- **module_layout 实际 CRC 是否 = 0xea759d7f**（唯一关键验证；若不等 → 门禁拦截，日志给实际值）
- SUSFS 补丁与 pad 补丁在 sched.h 是否冲突（pad 不用 SUSFS，建议用户默认不开）
- AK3 `split_boot`/`flash_boot` 在 WildKernels gki-2.0 分支的行为、`device.name1=TB710FU` 是否匹配 ro.product.device
- `repo sync` deprecated/android14-6.1-2025-03 的 tip 是否恰为 5c2cea985a84（钉死步骤会强制 checkout 并校验 sublevel=128）

## 七、已知遗留（下次接手优先看）

1. **Droidspaces 与 pad 0002 补丁无互斥 guard**：`apply_coloros_patches=true` 且 `droidspaces!=off` 时，上游 SYSVIPC kABI 补丁会尝试再打一次（冲突 → .rej → 上游步骤仅 warning）。应加 guard：coloros 开启时跳过上游补丁只保留 config 启用。
2. `config/stock_defconfig` 不存在 → Stock Config 伪装步骤自动跳过。可选：把 base.config 复制为该文件启用 /proc/config.gz 伪装。
3. `apply_coloros_patches=false` 时 prepare_config 仍拼 delta（含 SYSVIPC=y 但无 0002 补丁）→ 门禁会正确拦截，但语义上应支持 base-only 模式。
4. `ENABLE_SUSFS` 定义在 workflow 级 env 引用 inputs——GitHub 对 workflow 级 env 用 inputs 有版本兼容争议，稳妥做法是改为各步骤内联 `inputs.ksu_mode == '关闭'`。
5. 可复现性：未设固定 KBUILD_BUILD_TIMESTAMP（上游有对应步骤可抄）。

## 八、用户操作流程

1. 整个 `GKI_KernelSU_SUSFS-dev/` 内容作为仓库根上传（targets 下两个 ~200K 文件正常入库）
2. Actions → 「内核构建 - TB710FU (ColorOS 16 移植)」→ Run workflow（默认= ColorOS 补丁开 + GKI 特性全关）
3. 产物 artifact：`*AnyKernel3.zip`（TWRP 刷）+ `*AnyKernel3` 全量（含 Image/Module.symvers/config-final/config-drift/build.log/README-build.txt）
4. 失败时看：构建日志 → config-drift.txt（漂移）→ .rej（补丁冲突）→ module_layout 实际值
5. AK3 只刷 boot；vendor_boot-hyperSched-stub.img 须按 pad README 成对 fastboot 刷入；KernelSU LKM 在 init_boot，boot 内置 KSU 时注意双 KSU 冲突

## 九、关键数据速查

- GKI commit: `5c2cea985a841939e6d074cbed2019dec0245fcd`（build 13606743 / android14-6.1-2025-03 / 6.1.128）
- module_layout 哨兵: `0xea759d7f`（踩坑值 `0x28c5e94f`）
- 白名单: 8490 行；基线: 7550 行（stock）+ 19 行 delta
- boot 布局: ramdisk size=0（通用 ramdisk 在 init_boot，第一阶段在 vendor_boot）→ AK3 用 split_boot
- vendor 模块: 289 个 / 3615 符号对 / 0 CRC mismatch 为过线标准
