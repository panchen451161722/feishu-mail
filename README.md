# Cloudflare → 飞书邮箱切换

项目现在是一个自包含 skill，Cloudflare 认证只读取项目内 `.enviroment` 中的 Global API Key，不依赖 Node、Wrangler、OAuth 或 API Token。

## 结构

- `feishu-mail-cutover/SKILL.md`：完整切换流程和安全约束。
- `feishu-mail-cutover/scripts/cloudflare-feishu-mail.ps1`：确定性的 Cloudflare API 执行脚本。
- `.enviroment.example`：凭据配置模板，仅含占位符。
- `.feishu-mail-cutover/`、`backups/`：本地运行记录和回滚快照，不提交到 Git。

## 工作方式

1. 先向用户提供可点击的飞书域名设置链接，请用户打开、登录并输入目标域名。已有租户页面时使用已确认的直达链接；否则给出 [飞书管理后台](https://www.feishu.cn/admin/)，引导进入“产品设置 → 邮箱 → 服务管理 → 域名管理”。不要只提示缺少页面或让用户自行寻找地址。
2. 用户打开后，skill 从飞书实时页面读取当前域名启用所需的 MX、SPF、验证 TXT 等记录。
3. 把记录写入当前工作区的临时 JSON；脚本不包含任何固定域名或验证码。
4. `Validate` 模式在输入凭据前校验 JSON。
5. `Apply` 模式从 `.enviroment` 读取 Cloudflare 凭据，备份 Cloudflare 状态并显示变更计划，随后直接执行，不再要求输入完整域名确认。
6. 脚本停用 Cloudflare Email Routing、写入飞书记录并回读校验；随后由 skill 验证权威 DNS 和飞书状态。
7. 默认创建公共邮箱，按用户给出的成员配置使用权限。成员个人企业邮箱与公共邮箱地址分开；缺少成员或个人地址时按需补齐，不把公共邮箱地址直接分配给成员。只有用户明确要求时才创建个人邮箱。
8. 邮箱配置完成后，询问用户是否继续配置 DKIM；同意后才读取飞书实时 DKIM 记录、写入 DNS 并验证“已启用”。用户已明确要求 DKIM 时无需重复询问。暂不配置 DKIM 不影响报告邮箱已配置完成，DMARC 需另行请求或同意。

复制 `.enviroment.example` 为项目根目录的 `.enviroment`，再填入实际凭据：

```dotenv
CLOUDFLARE_API_EMAIL=admin@example.com
CLOUDFLARE_GLOBAL_API_KEY=replace-with-global-api-key
```

Global API Key 权限覆盖整个 Cloudflare 账户，不能限制到单个域名。脚本不会再弹窗询问 Cloudflare 凭据，也不会读取 Wrangler OAuth 或 API Token。

## Git 与敏感信息

`.enviroment`、其他本地环境配置、私钥、运行 JSON、DNS 快照、日志和编辑器临时文件均由 `.gitignore` 排除。运行记录可能包含域名验证值、Cloudflare 资源标识和账户信息，请仅在本地保管；自定义快照目录也应加入忽略规则。

提交前检查 `git status --short` 和 `git diff --cached`，不要使用 `git add -f` 强行提交上述文件，也不要分享整个 `.git` 目录。忽略规则不会清除已经提交的历史；若凭据曾进入历史或被分享，应清理历史并撤销或轮换相关凭据。

## 执行与故障处理约定

- 不按密钥长度或字符形态判断类型。先检查异常链、HTTP 状态与 Cloudflare 错误；TLS 握手失败且无 HTTP 响应时，不能判定密钥无效。
- 遇到疑似受限环境造成的网络/TLS 错误，按工具权限机制及时使用主机网络重试；写操作结果不明时，先只读核对远端状态。
- 浏览器点击后读取新页面状态，以“验证通过”或实际下一步页面判断结果；按钮无响应不代表域名未提交。
- 沿用用户指定且已可用的浏览器工具、登录会话和标签页（如 OpenCLI）；连接故障只做一次有界恢复，仍失败则给出具体页面链接与恢复说明。

## 脚本参数

```powershell
& '.\feishu-mail-cutover\scripts\cloudflare-feishu-mail.ps1' `
  -Mode Validate `
  -Domain 'example.com' `
  -RecordsFile '.\.feishu-mail-cutover\example.com-target.json'

& '.\feishu-mail-cutover\scripts\cloudflare-feishu-mail.ps1' `
  -Mode Apply `
  -Domain 'example.com' `
  -RecordsFile '.\.feishu-mail-cutover\example.com-target.json'
```

不要把其他域名的 Feishu 验证码复制到新的 records JSON。
