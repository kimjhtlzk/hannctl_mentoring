#!/usr/bin/env python3
"""스택의 모든 AWS 리소스가 hannctl 식별자(이름 또는 Project=hannctl 태그)를 갖는지 검사.

usage: tagcheck.py stack-resources.json tagged-resources.json report.txt
stdout: COMPLIANT | VIOLATION(n)
"""
import json
import sys

# 태그/이름 자체를 가질 수 없는 연결(association)형 리소스
NON_TAGGABLE = {
    "AWS::EC2::SubnetRouteTableAssociation", "AWS::EC2::VPCGatewayAttachment", "AWS::EC2::Route",
    "AWS::EC2::SecurityGroupIngress", "AWS::EC2::SecurityGroupEgress", "AWS::Lambda::Permission",
    "AWS::SNS::TopicPolicy", "AWS::SNS::Subscription", "AWS::IAM::UserToGroupAddition",
}

resources = json.load(open(sys.argv[1]))["StackResourceSummaries"]
tagged = json.load(open(sys.argv[2]))["ResourceTagMappingList"]
# hannctl 식별자를 가진 리소스: Project=hannctl 태그 또는 Name 태그에 hannctl 포함
marked = []
for m in tagged:
    tags = {t["Key"]: t["Value"] for t in m.get("Tags", [])}
    if tags.get("Project") == "hannctl" or "hannctl" in tags.get("Name", ""):
        marked.append((m["ResourceARN"], tags.get("aws:cloudformation:logical-id", "")))

lines, violations = [], 0
for r in resources:
    typ, pid = r["ResourceType"], r.get("PhysicalResourceId", "")
    if "hannctl" in pid.lower():
        verdict = "OK(name)"
    elif any((pid and pid in arn) or lid == r["LogicalResourceId"] for arn, lid in marked):
        verdict = "OK(tag)"   # 물리 ID 가 IP 등이라 ARN 과 다른 경우(EIP)는 logical-id 태그로 매칭
    elif typ in NON_TAGGABLE:
        verdict = "N/A(association)"
    else:
        verdict = "VIOLATION"
        violations += 1
    lines.append(f"{verdict:24} {typ:45} {pid}")

with open(sys.argv[3], "w") as f:
    f.write("\n".join(lines) + f"\n\nviolations={violations} total={len(resources)}\n")
print("COMPLIANT" if violations == 0 else f"VIOLATION({violations})")
