#!/usr/bin/env node
import * as cdk from "aws-cdk-lib";
import { HytaleServerStack } from "../lib/hytale-server-stack";
import { HytaleDataStack } from "../lib/hytale-data-stack";

const app = new cdk.App();

// Deploy this once; it contains the S3 bucket where server backups are stored.
const data = new HytaleDataStack(app, "HytaleDataStack", {
  // Optional:
  // env: { account: process.env.CDK_DEFAULT_ACCOUNT, region: process.env.CDK_DEFAULT_REGION },
});

new HytaleServerStack(app, "HytaleServerStack", {
  backupBucket: data.backupBucket,
  // Optional:
  // env: { account: process.env.CDK_DEFAULT_ACCOUNT, region: process.env.CDK_DEFAULT_REGION },
});

