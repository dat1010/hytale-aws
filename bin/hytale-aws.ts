#!/usr/bin/env node
import * as cdk from "aws-cdk-lib";
import { HytaleServerStack } from "../lib/hytale-server-stack";

const app = new cdk.App();

new HytaleServerStack(app, "HytaleServerStack", {
  // Optional:
  // env: { account: process.env.CDK_DEFAULT_ACCOUNT, region: process.env.CDK_DEFAULT_REGION },
});

