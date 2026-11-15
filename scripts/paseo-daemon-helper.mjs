#!/usr/bin/env node
import { createRequire } from "node:module";
import { existsSync, mkdirSync, realpathSync } from "node:fs";
import path from "node:path";
import os from "node:os";

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (!token.startsWith("--")) {
      continue;
    }
    const key = token.slice(2);
    const next = argv[i + 1];
    if (!next || next.startsWith("--")) {
      args[key] = "true";
    } else {
      args[key] = next;
      i += 1;
    }
  }
  return args;
}

function resolveAppAsar() {
  const override = process.env.BEANBRIDGE_PASEO_ASAR || process.env.PASEO_APP_ASAR;
  if (override && existsSync(override)) {
    return override;
  }
  const candidates = [
    "/Applications/Paseo.app/Contents/Resources/app.asar",
    path.join(os.homedir(), "Applications", "Paseo.app", "Contents", "Resources", "app.asar"),
  ];
  for (const candidate of candidates) {
    if (existsSync(candidate)) {
      return candidate;
    }
  }
  throw new Error("未找到 Paseo 桌面端资源（app.asar），请确认已安装 Paseo.app。");
}

function safeRealpath(targetPath) {
  const resolved = path.resolve(targetPath);
  try {
    return realpathSync(resolved);
  } catch {
    return resolved;
  }
}

async function resolveProvider(client, requested) {
  const explicit = (requested || process.env.BEANBRIDGE_PASEO_PROVIDER || "").trim();
  const availResp = await client.listAvailableProviders();
  const availableList = (availResp?.providers || [])
    .filter((entry) => entry && entry.available === true && typeof entry.provider === "string")
    .map((entry) => entry.provider);

  if (explicit) {
    if (availableList.length > 0 && !availableList.includes(explicit)) {
      throw new Error(`指定的 Paseo Provider「${explicit}」当前不可用，可用列表：${availableList.join(", ")}`);
    }
    return explicit;
  }

  const availableSet = new Set(availableList);
  const agentsResp = await client.fetchAgents({ filter: {} }).catch(() => ({ entries: [] }));
  const entries = Array.isArray(agentsResp?.entries) ? agentsResp.entries : [];
  const sorted = entries
    .map((entry) => entry?.agent)
    .filter((agent) => agent && !agent.archivedAt && agent.internal !== true)
    .sort((a, b) => {
      const ta = Date.parse(a.updatedAt || a.createdAt || "") || 0;
      const tb = Date.parse(b.updatedAt || b.createdAt || "") || 0;
      return tb - ta;
    });

  for (const agent of sorted) {
    if (typeof agent.provider === "string" && (availableSet.size === 0 || availableSet.has(agent.provider))) {
      return agent.provider;
    }
  }

  for (const preferred of ["claude", "codex", "antigravity", "gemini"]) {
    if (availableSet.has(preferred)) {
      return preferred;
    }
  }
  if (availableList.length > 0) {
    return availableList[0];
  }
  throw new Error("未检测到可用的 Paseo AI Provider，请先在 Paseo 中完成至少一个模型的登录或配置。");
}

async function connectPaseoClient(asarPath) {
  const req = createRequire(path.join(asarPath, "package.json"));
  const { createHostClient } = await import(req.resolve("@getpaseo/client/node"));
  const { waitForDaemonReady, resolvePaseoHome, readLocalCredentialForTarget } = await import(
    req.resolve("@getpaseo/server/daemon-control")
  );

  const home = resolvePaseoHome(process.env);
  const hostOverride = (process.env.BEANBRIDGE_PASEO_HOST || "").trim();
  const endpoint = hostOverride || (await waitForDaemonReady(home, { timeoutMs: 5000 })).listen;
  const password = (process.env.PASEO_PASSWORD || "").trim();
  const cred = readLocalCredentialForTarget(home, endpoint);

  const client = createHostClient(endpoint, {
    clientId: "beanbridge-helper",
    clientType: "cli",
    ...(password ? { password } : {}),
    ...(!password && cred ? { localCredential: () => readLocalCredentialForTarget(home, endpoint) ?? undefined } : {}),
    connectTimeoutMs: 5000,
    reconnect: { enabled: false },
  });

  await client.connect();
  return client;
}

function readWorkspacesList(wsResp) {
  if (Array.isArray(wsResp?.entries)) {
    return wsResp.entries;
  }
  if (Array.isArray(wsResp?.workspaces)) {
    return wsResp.workspaces;
  }
  return [];
}

async function runWorkspaceAgents(opts) {
  const workspaceId = (opts["workspace-id"] || "").trim();
  if (!workspaceId) {
    throw new Error("缺少工作区 ID 参数（--workspace-id）。");
  }
  const client = await connectPaseoClient(resolveAppAsar());
  try {
    const [wsResp, agentsResp] = await Promise.all([
      client.fetchWorkspaces({}),
      client.fetchAgents({ filter: {} }),
    ]);
    const workspaces = readWorkspacesList(wsResp);
    const targetWorkspace = workspaces.find((ws) => ws && ws.id === workspaceId && !ws.archivingAt) || null;
    if (!targetWorkspace) {
      throw new Error(`未找到指定的 Paseo 工作区：${workspaceId}`);
    }
    const entries = Array.isArray(agentsResp?.entries) ? agentsResp.entries : [];
    const agents = entries
      .map((entry) => entry?.agent)
      .filter(
        (agent) =>
          agent &&
          !agent.archivedAt &&
          agent.internal !== true &&
          agent.workspaceId === workspaceId &&
          typeof agent.id === "string" &&
          agent.id.trim().length > 0
      )
      .map((agent) => ({
        id: agent.id.trim(),
        title: typeof agent.title === "string" ? agent.title : "",
        name: typeof agent.name === "string" ? agent.name : "",
        status: typeof agent.status === "string" ? agent.status : "",
      }));

    process.stdout.write(
      JSON.stringify({
        workspace: {
          id: targetWorkspace.id,
          title: typeof targetWorkspace.title === "string" ? targetWorkspace.title : "",
          name: typeof targetWorkspace.name === "string" ? targetWorkspace.name : "",
          projectDisplayName:
            typeof targetWorkspace.projectDisplayName === "string" ? targetWorkspace.projectDisplayName : "",
        },
        agents,
      }) + "\n"
    );
  } finally {
    await client.close().catch(() => {});
  }
}

async function runCreate(opts) {
  const cwdRaw = (opts.cwd || process.env.BEANBRIDGE_PASEO_CWD || "").trim();
  if (!cwdRaw) {
    throw new Error("缺少工作目录参数（--cwd）。");
  }
  const idempotencyKey = (opts["idempotency-key"] || "").trim();
  if (!idempotencyKey) {
    throw new Error("缺少幂等键参数（--idempotency-key）。");
  }
  const explicitWorkspaceId = (opts["workspace-id"] || process.env.BEANBRIDGE_PASEO_WORKSPACE_ID || "").trim();

  if (!existsSync(cwdRaw)) {
    mkdirSync(cwdRaw, { recursive: true, mode: 0o700 });
  }
  const normalizedCwd = safeRealpath(cwdRaw);

  const client = await connectPaseoClient(resolveAppAsar());
  try {
    const provider = await resolveProvider(client, opts.provider);
    const workspaces = readWorkspacesList(await client.fetchWorkspaces({}));

    let targetWorkspace = null;
    if (explicitWorkspaceId) {
      targetWorkspace = workspaces.find((ws) => ws && ws.id === explicitWorkspaceId && !ws.archivingAt) || null;
      if (!targetWorkspace) {
        throw new Error(`未找到指定的 Paseo 工作区：${explicitWorkspaceId}`);
      }
    } else {
      targetWorkspace =
        workspaces.find(
          (ws) => ws && !ws.archivingAt && ws.workspaceDirectory && safeRealpath(ws.workspaceDirectory) === normalizedCwd
        ) || null;
    }

    let createdAgent = null;
    let resolvedWorkspaceId = targetWorkspace?.id || null;
    if (targetWorkspace) {
      createdAgent = await client.createAgent({
        workspaceId: targetWorkspace.id,
        config: {
          provider,
          cwd: targetWorkspace.workspaceDirectory || normalizedCwd,
        },
        idempotencyKey,
        labels: { source: "beanbridge" },
      });
    } else {
      const wsResult = await client.createWorkspace({
        source: { kind: "directory", path: normalizedCwd },
        title: "安克豆语音",
        idempotencyKey,
        agent: {
          config: {
            provider,
            cwd: normalizedCwd,
          },
          idempotencyKey: `${idempotencyKey}:agent`,
          labels: { source: "beanbridge" },
        },
      });
      if (wsResult?.error) {
        throw new Error(wsResult.error);
      }
      createdAgent = wsResult?.agent || null;
      resolvedWorkspaceId = wsResult?.workspace?.id || null;
    }

    if (!createdAgent || typeof createdAgent.id !== "string" || !createdAgent.id.trim()) {
      throw new Error("Paseo 守护进程未返回有效的新建对话 ID。");
    }

    const title =
      (typeof createdAgent.title === "string" && createdAgent.title.trim()) ||
      (typeof createdAgent.name === "string" && createdAgent.name.trim()) ||
      "新 Paseo 对话";

    process.stdout.write(
      JSON.stringify({
        id: createdAgent.id.trim(),
        title,
        provider,
        workspaceId: createdAgent.workspaceId || resolvedWorkspaceId || null,
        appID: "paseo",
      }) + "\n"
    );
  } finally {
    await client.close().catch(() => {});
  }
}

async function main() {
  const [command, ...rest] = process.argv.slice(2);
  const opts = parseArgs(rest);
  if (command === "create") {
    await runCreate(opts);
    return;
  }
  if (command === "workspace-agents") {
    await runWorkspaceAgents(opts);
    return;
  }
  throw new Error(`不支持的子命令：${command || "<empty>"}`);
}

main().catch((error) => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`${message}\n`);
  process.exit(1);
});
