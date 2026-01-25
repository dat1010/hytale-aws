import { Construct } from "constructs";

export const HYTALE_UDP_PORT = 5520;

export function getBooleanContext(scope: Construct, key: string, defaultValue: boolean): boolean {
  const raw = scope.node.tryGetContext(key);
  if (raw === undefined || raw === null) return defaultValue;
  if (typeof raw === "boolean") return raw;
  if (typeof raw === "string") {
    const s = raw.trim().toLowerCase();
    if (["1", "true", "yes", "y", "on"].includes(s)) return true;
    if (["0", "false", "no", "n", "off"].includes(s)) return false;
  }
  // Fall back to default to avoid surprising synth errors.
  return defaultValue;
}

