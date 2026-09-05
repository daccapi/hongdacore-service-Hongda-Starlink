# Android UI / 功能映射

参考图：`design/reference-ui.png`

## 首页

- 鸿达星轨智连 / Hongda Starlink 品牌头部
- 星轨蓝色连接 Hero + 点击连接环
- 当前节点、协议、延迟、切换节点
- 延迟 / 下载 / 上传 / 总流量四卡
- 实时下载/上传曲线
- TUN / DNS / 系统代理 / 自动选择快捷开关
- 订阅管理与一键更新
- 近期节点、国家旗帜、延迟、收藏
- 首页 / 节点 / 订阅 / 工具 / 设置底栏

## 节点

- 全部节点列表
- 当前节点与收藏状态
- 单节点延迟测试
- 批量延迟测试
- 手工导入节点
- 自动选择最低延迟节点

## 订阅

- 添加订阅
- 全部更新
- 展示格式、节点数、流量、更新时间和错误
- 删除订阅时同步清理来源节点、规则组与规则

## 工具与设置

- TUN、严格路由、IPv6
- Local DNS / DoH
- Rule / Global / Auto / Direct
- 绕过 LAN、FakeIP
- Mixed Port、Clash API、URLTest、日志级别
- Android 核心检测状态与运行日志


## V1.6.4 R2 Core Bridge

Android native core is now wired through `HongdaVpnService.kt` and the generated `HongdaCore.aar`; see `BUILD_ANDROID.md`.
