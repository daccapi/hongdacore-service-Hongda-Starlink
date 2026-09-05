# 更新记录

## V1.6.5 — 2026-08-13

### Windows UI

- 修复节点国家不显示：扩大国家识别范围，使用自绘国家徽标代替 Windows 不完整的旗帜 Emoji。
- 修复普通窗口仪表盘必须下拉或最大化：新增紧凑/超紧凑高度布局，低高度窗口保持桌面网格。
- 国家名称加入节点搜索条件。

### 连接与监控

- 修复手动 VLESS 已连接但右侧实时流量图为空：`/traffic` 异常时使用 `/connections` 真实字节增量回退。
- 修复流量 WebSocket 反复断线后可能堆积重复重连的问题。
- Mixed 与 Clash API 端口支持冲突自动避让，实际端口同步到全部调用方并持久化。

### 节点与订阅

- 订阅更新时按完整配置、身份和唯一端点匹配旧节点。
- 保留节点 ID、收藏、启用状态、延迟时间和测试错误，避免当前选择失效。

### 核心与 Service

- `HongdaService` 升级到 1.4.2。
- Windows 子核心改为从本地源码构建的 `HongdaCore.exe` 1.13.18。
- 进程关系保持 `Hongda Starlink.exe -> HongdaService.exe -> HongdaCore.exe`。
- 删除旧的重复预编译核心资源，保留第三方许可证和必要来源说明。

### 验证

- `HongdaCore.exe version`：1.13.18。
- `HongdaService.exe version/features`：通过。
- Flutter 静态分析：无编译错误。

## 历史版本

- V1.6.4：见 `V1.6.4_BUGFIX_CHANGELOG.md` 与 `V1.6.4_R2_REGRESSION_FIX.md`。
- V1.6.3：见 `V1.6.3_BUGFIX_CHANGELOG.md`。
