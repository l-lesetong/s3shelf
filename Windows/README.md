# s3Shelf Windows 预览版

目标系统为 Windows 10 1607 或更新版本，以及带桌面体验的 Windows Server 2016 或更新版本。需要 Microsoft .NET Framework 4.8 或更新版本，安装程序会检查此依赖。便携版解压后运行 `s3Shelf.exe`。

- 支持 AWS S3 和自定义 S3 端点，可启用路径式访问。支持访问密钥、临时会话令牌、AWS 配置档案和匿名访问。手动保存的密钥使用 Windows DPAPI 按当前用户加密。
- 左右窗格可独立浏览连接、存储桶和路径。对象按页加载，筛选只检查已加载的条目。详情栏可查看属性、响应头和 ACL，并编辑存储桶和对象标签。
- 支持创建和删除空存储桶。删除桶时需再次输入完整桶名。单文件上传支持分片，下载完成后再写入目标文件。进度和结果显示在当前会话的传输历史中。
- 响应头、ACL 和标签按窗格缓存 30 秒，可查看缓存时间或强制刷新。跨桶 Copy/Sync、传输限速、ACL 写入和 API 工作台尚未移植。

## 构建

需要 PowerShell、可构建 .NET Framework 4.8 项目的 MSBuild（或 .NET SDK）和 NSIS 3。Windows 构建机可通过 Visual Studio Build Tools 安装 .NET Framework 4.8 构建工具。

```powershell
.\Windows\build.ps1 -MakeNSIS 'C:\Program Files (x86)\NSIS\makensis.exe'
```

安装包和便携 ZIP 默认输出到仓库的 `outputs/` 目录。脚本以项目版本为基线，后续构建根据该目录已有产物递增补丁号。用 `-Version` 可以显式指定构建版本。安装程序按当前用户安装，卸载后保留当前用户的连接配置。
