#!/usr/bin/env node
import * as cdk from "aws-cdk-lib";
import { HytaleServerStack } from "../lib/hytale-server-stack";
import { HytaleBackupStack } from "../lib/hytale-backup-stack";

const app = new cdk.App();

// Deploy this once, and do NOT destroy it when tearing down the server.
// It retains the backup vault so recovery points survive even if the server stack is destroyed.
new HytaleBackupStack(app, "HytaleBackupStack", {
  // Optional:
  // env: { account: process.env.CDK_DEFAULT_ACCOUNT, region: process.env.CDK_DEFAULT_REGION },
});

new HytaleServerStack(app, "HytaleServerStack", {
  // Optional:
  // env: { account: process.env.CDK_DEFAULT_ACCOUNT, region: process.env.CDK_DEFAULT_REGION },
});

