# Placard

Placard 是一款克制的 SwiftUI 本地互动壁纸写入器。当前阶段提供：

- 通过“浏览 / 自定义 / 管理”三个一级页面组织完整壁纸工作流
- 浏览、搜索并预览 Pocket Poster 社区壁纸目录
- 下载并检查 `.tendies` 壁纸包
- 从照片图库导入最长 12 秒的视频，预览并转换成可循环或往返播放的 CAML 动态壁纸
- 在受支持的 iOS 真机上通过 `bad_query` 直接写入 PosterBoard descriptors
- 写入完成后通过 NeoSpring 刷新 SpringBoard，使 PosterBoard 重新载入壁纸
- 从“已安装”管理页渲染并删除“精选”descriptor 或“我的壁纸”configuration

## 运行条件

- Xcode 26 或更新版本
- iOS 26 或更新版本
- 安装功能仅可在 `bad_query` 动态探测成功的真机系统上使用

首次真机运行前，请在 Xcode 的 Signing & Capabilities 中选择你自己的开发团队。

模拟器可用于浏览与界面调试，但不会尝试写入系统壁纸。

## 致谢与许可

目录格式和 PosterBoard descriptor 安装流程基于
[leminlimez/Pocket-Poster](https://github.com/leminlimez/Pocket-Poster)，sandbox extension 实现基于
[forcequitOS/bad_query](https://github.com/forcequitOS/bad_query)。壁纸目录来自
[SerStars/nugget-wallpapers](https://github.com/SerStars/nugget-wallpapers)。桌面刷新方案来自
[rooootdev/neospring](https://github.com/rooootdev/neospring)。

本项目按 GNU GPL v3 发布，详见 [LICENSE](LICENSE)。`bad_query` 与 `neospring`
上游仓库目前未声明独立许可证；对外分发前请确认其授权条件。
