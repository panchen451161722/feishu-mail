---
name: feishu-mail-cutover
description: Configure Feishu Mail and public mailboxes for Cloudflare-hosted domains using a local Global API Key. Use for domain verification, MX/SPF cutover, Email Routing shutdown, mailbox setup, optional DKIM after mailbox completion, interrupted-run recovery, or rollback. Never use Wrangler OAuth, API Tokens, or Cloudflare dashboard automation.
---

# Feishu Mail Cutover

Treat the workflow as a production mail-routing change. Use the bundled
`scripts/cloudflare-feishu-mail.ps1`; do not rewrite its Cloudflare mutation logic.

## Non-negotiable rules

- Use only Cloudflare Global API Key authentication.
- Never invoke Wrangler in any form or use OAuth login, token discovery, or API Token flows.
- Never read `CLOUDFLARE_API_TOKEN` or Cloudflare credentials from process environment variables.
- Read the Cloudflare account email and Global API Key only from the workspace `.enviroment` file. Never request the key in chat or pass it as a command argument.
- Explain that the Global API Key has the account's full Cloudflare permissions and cannot be restricted to one zone.
- Prefer the user's explicitly requested browser workflow (including OpenCLI), and keep using the working tool and authenticated tab/session across turns. Otherwise use the available browser tooling with its applicable instructions. Let the user handle login, MFA, CAPTCHA, tenant selection, and domain entry.
- Never automate the Cloudflare dashboard.
- Never hardcode or reuse DNS records from an earlier domain or run.
- Never send test mail or assign a mailbox without the user's separate address mapping or confirmation.
- Default to a public mailbox (公共邮箱) unless the user explicitly requests a personal member mailbox. A member named by the user is a public-mailbox user, not an instruction to assign the public address as that member's personal enterprise email.
- After mailbox setup is complete, ask whether to configure DKIM. Do not generate DKIM keys, add DKIM records, or enable signing before the user agrees. Reuse an explicit DKIM request already given in this task instead of asking again.
- Treat an explicit execution request to configure, migrate, or cut over an exact domain to Feishu Mail as authorization to launch `Apply` after target validation. Do not ask for an additional chat or local confirmation such as “I confirm switching <domain> to Feishu Mail.” A request that is only for planning, explanation, review, or diagnosis does not authorize mutation.

## Required inputs

Obtain:

- the exact domain;
- an authenticated Feishu domain-setup page (provide the user an opening link using Phase 0; do not require them to discover the URL);
- the requested public mailbox address and the members allowed to use it; reuse any mapping already supplied. If a member also needs a personal enterprise email, obtain that separate address without assigning the public mailbox address to the member.

Create `.enviroment` in the current workspace before `Plan`, `Apply`, or `Verify`:

```dotenv
CLOUDFLARE_API_EMAIL=admin@example.com
CLOUDFLARE_GLOBAL_API_KEY=replace-with-global-api-key
```

Use `-EnvironmentFile '<absolute-path>'` only when the file is not at
`<current-workspace>/.enviroment`.

Normalize the domain to lowercase ASCII/Punycode. Reject a Feishu page whose displayed domain differs from the requested domain.

## Phase 0: Give the user a page to open

When the authenticated domain-setup page is missing, first provide a clickable Markdown link and ask the user to open it, log in, select their tenant, and enter the requested domain. Do not merely say the page is missing or ask the user to find and send its URL.

- Prefer an exact domain-setup URL already supplied by the user or observed in their browser. Keep tenant-specific URLs in the current session; do not persist them in shared documentation or assume they belong to another user or tenant.
- If no tenant-specific URL is known, provide [飞书管理后台](https://www.feishu.cn/admin/) and the navigation path: 产品设置 → 邮箱 → 服务管理 → 域名管理 → 添加/配置域名. Do not invent a tenant hostname.
- Suggested wording: “请打开 [飞书邮箱域名设置](the-known-URL)，登录并选择正确企业，输入 `<requested-domain>`，停留在 DNS 记录表页面。打开后告诉我，我会读取页面继续配置。” Replace the link target and domain with the actual known values before sending.
- After the user says the page is ready, inspect it using the available browser tool or the user's explicitly requested OpenCLI workflow. Read the complete live DNS table and verify the displayed domain before continuing.
- If browser access fails, offer copying the DNS table or sending a screenshot as a fallback, while still providing the opening link. Never claim a page has opened merely because an open request was queued.

## Phase 1: Read live Feishu records

### Browser continuity and result verification

- Reuse the known working browser tool and session; do not switch back to a previously failing tool without a concrete reason. For OpenCLI, inspect command help when needed and reuse the same named session and selected tab.
- After every click, submission, or navigation, read fresh page state before deciding the next action. A `clicked: true` response proves only that the action was attempted; a queued opening request does not prove the page opened.
- Require visible evidence for each claimed outcome: the requested domain and DNS table, “验证通过”, or the actual next-step page. Do not infer that a domain was never submitted merely because “下一步” does nothing; inspect disabled controls, visible validation messages, and page state first.
- On a connection timeout or detached browser, perform one bounded recovery/rebind attempt using that tool's documented workflow. If it still fails, stop repeating identical calls, provide the exact known page link and error, and ask the user to open/reconnect it; offer a screenshot or copied DNS table as a fallback. Do not request a new login when the existing authenticated session is accessible.

Open the Feishu setup page and extract every displayed DNS requirement:

- TXT verification records;
- the single intended SPF record;
- MX targets and priorities;
- any other records required for domain activation;
- owner names and TTL values.

Do not proceed until the page shows a complete record table. Preserve values exactly.

Optional DKIM signing belongs to Phase 7 after mailbox setup. Do not enter the DKIM setup flow during the initial domain cutover. Preserve any existing DKIM records and state.

Create a runtime JSON file under the current workspace, for example
`.feishu-mail-cutover/<domain>-target.json`:

```json
{
  "domain": "example.com",
  "records": [
    {
      "type": "TXT",
      "name": "@",
      "content": "verification-value-from-live-feishu-page",
      "ttl": 600,
      "comment": "Feishu domain verification"
    },
    {
      "type": "TXT",
      "name": "@",
      "content": "spf-value-from-live-feishu-page",
      "ttl": 600,
      "comment": "Feishu Mail SPF"
    },
    {
      "type": "MX",
      "name": "@",
      "content": "mx-target-from-live-feishu-page",
      "priority": 1,
      "ttl": 600,
      "comment": "Feishu Mail MX"
    }
  ]
}
```

Include every live Feishu row, not only the example rows. Supported types are `TXT`, `MX`, and `CNAME`. The JSON must be unique to the domain and current Feishu setup page. Keep runtime JSON and rollback snapshots local and ignored by Git: they can contain verification values, account details, and Cloudflare resource identifiers. Add any custom snapshot directory to `.gitignore` before use.

## Phase 2: Validate the target file

Resolve the bundled script relative to this `SKILL.md`, then run:

```powershell
& '<skill-directory>\scripts\cloudflare-feishu-mail.ps1' `
  -Mode Validate `
  -Domain '<domain>' `
  -RecordsFile '<absolute-target-json-path>'
```

Validation does not read `.enviroment`. It rejects domain mismatches, missing/duplicate records, unsupported types, missing MX priorities, and anything other than exactly one apex SPF record.

## Phase 3: Preflight and snapshot

Run the bundled script in `Apply` mode. It reads `.enviroment`, performs the read-only preflight, writes a snapshot, prints the exact plan, and proceeds directly to mutation without a confirmation prompt.

```powershell
& '<skill-directory>\scripts\cloudflare-feishu-mail.ps1' `
  -Mode Apply `
  -Domain '<domain>' `
  -RecordsFile '<absolute-target-json-path>'
```

Before launching `Apply`, summarize:

- Cloudflare Email Routing will stop receiving new inbound mail;
- exact DNS deletions, patches, and additions;
- unrelated records preserved;
- snapshot path and rollback behavior.

Do not add a separate chat or local confirmation when the user already made an explicit execution request for the exact domain. Launch `Apply` after validation; it does not pause between printing the plan and applying it.

The script must stop before mutation when it finds an inactive/mismatched zone, unknown apex MX, unknown SPF, duplicate target records, a records-file domain mismatch, or a failed Cloudflare response.

## Phase 4: Apply and compensate

### Diagnose connection failures before blaming credentials

- Never classify a credential as a Token or invalid Global API Key from its length, character set, or appearance. Do not print credentials while diagnosing.
- Inspect the exception type, full inner-exception chain, HTTP status (if present), and Cloudflare error codes/messages (if returned), with credentials and personal data redacted. Do not output a successful `/user` response body merely to test authentication.
- Distinguish transport failures (TLS/SSL, certificate validation, DNS, proxy, connection timeout) from HTTP errors and Cloudflare API errors. `AuthenticationException` during TLS negotiation is not evidence that Cloudflare rejected the API key. With no HTTP response, report that credential validity has not been established.
- Treat HTTP 401/403 as authentication or authorization evidence requiring the actual API error for diagnosis; do not automatically equate either with an invalid key. Only ask the user to check credentials when the returned evidence supports it.
- If an essential request fails with a likely sandbox-related network/TLS error, use the tool's `require_escalated` mechanism promptly to retry through the host network, following its approval requirements. Do not repeatedly run the same failing sandbox request or ask the user to replace a key on that basis. Never disable certificate verification to work around TLS failures.
- If failure occurred during the initial read-only preflight, before any mutation, the already-authorized command may be retried with escalation. If any write was attempted or its outcome is ambiguous, first use read-only checks to reconcile DNS and Routing state before retrying writes. Escalation does not expand the authorized domain or operations.
- If earlier advice incorrectly blamed the credential, explicitly correct it when the diagnosis changes.

Allow the bundled script to mutate serially:

1. re-read the active zone, DNS, and Email Routing state;
2. snapshot the current Cloudflare state under `.feishu-mail-cutover/`;
3. disable Email Routing with `DELETE /zones/{zone_id}/email/routing/dns` when enabled;
4. re-read DNS;
5. remove only recognized retired Cloudflare Email Routing MX/SPF records;
6. batch-create or patch only the target records;
7. re-read and verify the API state.

Never retry an ambiguous mutation blindly. Re-read state first. If the forward cutover fails after Email Routing was disabled, let the script re-enable its DNS management automatically. Report any rollback failure immediately.

## Phase 5: Verify DNS and Feishu

After the script succeeds, query Cloudflare's authoritative nameservers directly and at least one independent recursive resolver. Require:

- exact target MX hosts and priorities;
- exactly one intended apex SPF record;
- exact verification TXT records;
- target DKIM/CNAME records when required;
- absence of retired Cloudflare Email Routing MX/SPF records;
- preservation of unrelated TXT, DKIM, DMARC, A, AAAA, CNAME, NS, DS, and CAA records.

Treat authoritative DNS as the source of truth. Use bounded retries and provide an update at least once per minute.

Only after authoritative DNS matches, click Feishu's verification control. Record the visible result. If Feishu reports propagation delay, keep correct Cloudflare records unchanged and retry later.

## Phase 6: Create the public mailbox and verify setup

Inspect the next Feishu step, then open 产品设置 → 邮箱 → 地址管理 → 公共邮箱 in the authenticated tenant. Create the requested address as a public mailbox by default and add the user-specified members. Follow an explicit request for a personal mailbox instead when given.

- Reuse the supplied address and member mapping. If the form requires at least one member and none was supplied, ask for a member and keep mailbox creation pending; never select an owner on the user's behalf.
- Keep members' personal enterprise email addresses separate from the public mailbox. If Feishu requires a member to have a personal enterprise email first, use their existing address or obtain a separate address from the user.
- If the requested public address is already a member's personal address or alias, inspect the conflict and obtain the replacement personal address before making changes. Account for aliases created automatically by Feishu, preserve existing mail, and report where historical mail remains. Do not delete a mailbox or its history just to free an address.
- Verify the public mailbox appears in the public-mailbox list with the requested address and authorized members. Domain DNS verification or assigning a personal enterprise address alone does not complete public-mailbox setup. Confirm domain activation in Feishu; if its setup wizard remains incomplete, inspect the visible requirements and finish the authorized steps.

Explain that Cloudflare Email Routing stores no mailbox history, so DNS cutover does not migrate historical messages.

Obtain separate confirmation before sending real inbound or outbound test messages. If tests are deferred, say so explicitly.

## Phase 7: Offer optional DKIM after mailbox completion

Once the domain and requested mailbox are configured, report that result and ask: “公共邮箱 `<requested-address>` 已配置完成，是否继续为 `<requested-domain>` 配置 DKIM，以改善外发邮件的身份验证？” Replace the placeholders with the actual address and domain. Do not postpone this question indefinitely for mail tests that the user has deferred.

If the user declines or has not answered, leave DKIM unchanged and report it as optional and deferred. If DKIM is already enabled and verified, report that state instead of regenerating its key. An explicit DKIM request already given in the current task is sufficient authorization to continue after mailbox completion.

When the user agrees:

1. Open 产品设置 → 邮箱 → 安全与反垃圾 → DKIM 身份验证, select the exact domain, and use the recommended 2048-bit key when available. Read the complete live DNS owner, type, value, and TTL; do not copy a truncated value or reuse another domain's selector/key.
2. Add the live DKIM record to the domain's validated target JSON while retaining its verified MX, SPF, and domain-verification records. Use the bundled script's `Validate`, `Plan`, and `Apply` modes; review the plan, preserve unrelated records, and save the snapshot. If the plan proposes unrelated mail-routing changes, reconcile current state before applying it.
3. Verify the exact DKIM record through Cloudflare API, authoritative DNS, and an independent resolver, then click Feishu's verification control. Require the domain to visibly show DKIM “已启用”.
4. Report DKIM activation separately from actual delivery results. Test messages still require the user's authorization; do not promise that DKIM guarantees inbox placement.

Agreement to DKIM does not authorize adding DMARC or changing its policy; handle DMARC only when separately requested or approved.

## Completion criteria

Report success only when:

- Cloudflare Email Routing is disabled;
- Cloudflare API state and authoritative DNS match the live Feishu records;
- Feishu reports the domain as verified or enabled;
- the requested public mailbox and member access are verified, or mailbox setup is explicitly reported as incomplete/deferred; a personal member mailbox counts only when explicitly requested;
- mail tests pass or are explicitly deferred;
- after mailbox completion, DKIM has been offered and its status is reported separately as already enabled, completed, declined, or awaiting the user's answer; optional DKIM does not block reporting completed mailbox setup;
- the snapshot path is reported;
- Cloudflare credentials were loaded from the selected `.enviroment` file.
