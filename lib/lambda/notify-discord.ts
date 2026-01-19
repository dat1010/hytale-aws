import https from "https";
import { SecretsManagerClient, GetSecretValueCommand } from "@aws-sdk/client-secrets-manager";
import {
  DescribeInstanceStatusCommand,
  DescribeInstancesCommand,
  EC2Client,
} from "@aws-sdk/client-ec2";

const sm = new SecretsManagerClient({});
const ec2 = new EC2Client({});

async function getWebhookUrl(secretArn: string): Promise<string | undefined> {
  try {
    const out = await sm.send(new GetSecretValueCommand({ SecretId: secretArn }));
    const s = out.SecretString?.trim();
    if (!s || s === "None" || s === "null") return undefined;
    return s;
  } catch {
    // If the secret doesn't exist yet / has no value, Discord is effectively disabled.
    return undefined;
  }
}

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

async function getPublicIp(instanceId: string): Promise<string | undefined> {
  const out = await ec2.send(new DescribeInstancesCommand({ InstanceIds: [instanceId] }));
  return out.Reservations?.[0]?.Instances?.[0]?.PublicIpAddress;
}

async function getEc2StatusOk(instanceId: string): Promise<boolean> {
  const out = await ec2.send(
    new DescribeInstanceStatusCommand({ InstanceIds: [instanceId], IncludeAllInstances: true })
  );
  const s = out.InstanceStatuses?.[0];
  return s?.SystemStatus?.Status === "ok" && s?.InstanceStatus?.Status === "ok";
}

function postJson(url: string, body: unknown): Promise<{ statusCode?: number; body: string }> {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const data = Buffer.from(JSON.stringify(body), "utf8");
    const req = https.request(
      {
        hostname: u.hostname,
        path: u.pathname + u.search,
        method: "POST",
        headers: { "Content-Type": "application/json", "Content-Length": data.length },
      },
      (res) => {
        let buf = "";
        res.on("data", (d) => (buf += d));
        res.on("end", () => resolve({ statusCode: res.statusCode, body: buf }));
      }
    );
    req.on("error", reject);
    req.write(data);
    req.end();
  });
}

// EventBridge: EC2 Instance State-change Notification
type Ec2StateChangeEvent = {
  detail?: {
    "instance-id"?: string;
    state?: string;
  };
};

export async function handler(event: Ec2StateChangeEvent) {
  const instanceId = event?.detail?.["instance-id"];
  const state = event?.detail?.state;

  if (instanceId !== process.env.INSTANCE_ID || state !== "running") {
    return { ok: true, skipped: true };
  }

  const secretArn = process.env.DISCORD_WEBHOOK_SECRET_ARN;
  if (!secretArn) return { ok: true, skipped: true, reason: "missing DISCORD_WEBHOOK_SECRET_ARN" };

  const webhook = await getWebhookUrl(secretArn);
  if (!webhook) return { ok: true, skipped: true, reason: "discord webhook not configured" };

  const port = process.env.SERVER_PORT || "5520";
  const maxWaitSeconds = Math.max(0, Number(process.env.MAX_WAIT_SECONDS || "45"));
  const pollSeconds = Math.max(1, Math.min(10, Number(process.env.POLL_SECONDS || "5")));

  let publicIp: string | undefined;
  let statusOk = false;
  const deadline = Date.now() + maxWaitSeconds * 1000;

  // Wait a bit for the public IP + EC2 status checks to become available.
  while (Date.now() <= deadline) {
    [publicIp, statusOk] = await Promise.all([
      getPublicIp(instanceId).catch(() => undefined),
      getEc2StatusOk(instanceId).catch(() => false),
    ]);

    if (publicIp && statusOk) break;
    await sleep(pollSeconds * 1000);
  }

  const endpoint = publicIp ? `${publicIp}:${port}` : `(public IP pending):${port}`;
  const content = statusOk
    ? `🟢 EC2 status checks are **OK**. Hytale server is starting up — connect at \`${endpoint}\` in a couple minutes.`
    : `🟡 Hytale EC2 is **booting** — it should be ready soon. Connect at \`${endpoint}\` in a few minutes.`;

  return await postJson(webhook, { content });
}

