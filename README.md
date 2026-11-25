# s3Shelf

s3Shelf 是基于 SwiftUI 和 AppKit 的中文 macOS 对象存储客户端，支持 Amazon S3 和兼容端点。外观默认跟随系统，也可在「设置 → 外观」切换浅色或深色。

## 功能

- 浏览存储桶和对象前缀，按页加载并短时缓存清单。筛选在本地执行，详情按需请求。
- 上传、下载、同步和批量删除对象。传输队列支持并发、取消和重试。
- 查看 HTTP 响应头、ACL、标签、对象元数据、历史版本和会话日志，预览文本、图片和二进制内容。
- 使用 AWS Profile、IAM Identity Center、访问密钥、临时凭证或匿名连接。手动输入的密钥由 macOS 钥匙串保存。
- API 工作台可调用内置 AWS CLI v2 的六个 S3 命令组。操作可用性取决于端点、账户权限和存储桶类型。

## 构建

运行环境为 macOS 14 或更新版本。构建需要支持 Swift 6 的 Xcode 工具链，以及 Python 3。构建产物同时包含 Apple 芯片和 Intel 两种架构。

```bash
./build.sh build
open build/s3Shelf.app
```

构建脚本从 AWS 获取固定版本的 AWS CLI v2 安装包，验证 Amazon 安装包签名，再提取 CLI 并生成 API 目录。若已有 AWS CLI 安装包，可将其路径作为第二个参数传入。构建输出采用本地临时签名，适合本地运行和验证。

## 项目结构

| 路径 | 用途 |
| --- | --- |
| `Sources/` | 原生界面、浏览与传输状态、详情面板、AWS CLI 调用和凭证处理 |
| `Resources/AppIcon.icns` | s3Shelf macOS 图标 |
| `catalog.py` | 根据 AWS CLI 服务模型生成 API 工作台命令目录 |
| `build.sh` | 生成通用架构的 `s3Shelf.app` |

## 提交约定

提交格式为 `type(scope): 中文主题`。主题用简短的中文动词开头，末尾省略句号。首次克隆后可运行 `git config --local commit.template .gitmessage` 载入模板。
