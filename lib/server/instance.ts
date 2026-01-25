import { Construct } from "constructs";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as iam from "aws-cdk-lib/aws-iam";

export const ROOT_VOLUME_SIZE_GIB = 16;
export const DATA_VOLUME_SIZE_GIB = 30;

export function createInstanceRole(scope: Construct): iam.Role {
  const role = new iam.Role(scope, "HytaleInstanceRole", {
    assumedBy: new iam.ServicePrincipal("ec2.amazonaws.com"),
  });

  role.addManagedPolicy(iam.ManagedPolicy.fromAwsManagedPolicyName("AmazonSSMManagedInstanceCore"));

  return role;
}

export function createInstance(
  scope: Construct,
  vpc: ec2.Vpc,
  sg: ec2.SecurityGroup,
  role: iam.Role
): ec2.Instance {
  return new ec2.Instance(scope, "HytaleInstance", {
    vpc,
    vpcSubnets: { subnetType: ec2.SubnetType.PUBLIC },
    securityGroup: sg,
    role,
    instanceType: ec2.InstanceType.of(ec2.InstanceClass.T3A, ec2.InstanceSize.LARGE), // 2 vCPU / 8 GiB
    machineImage: ec2.MachineImage.latestAmazonLinux2023({
      cpuType: ec2.AmazonLinuxCpuType.X86_64,
    }),
    blockDevices: [
      {
        deviceName: "/dev/xvda",
        volume: ec2.BlockDeviceVolume.ebs(ROOT_VOLUME_SIZE_GIB, {
          encrypted: true,
          volumeType: ec2.EbsDeviceVolumeType.GP3,
        }),
      },
      {
        deviceName: "/dev/xvdb",
        volume: ec2.BlockDeviceVolume.ebs(DATA_VOLUME_SIZE_GIB, {
          encrypted: true,
          volumeType: ec2.EbsDeviceVolumeType.GP3,
        }),
      },
    ],
  });
}

