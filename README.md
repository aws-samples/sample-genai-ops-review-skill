# AWS AIO2 Multi-Framework Review — Agent Skill

AI Operations & Optimization (AIO2) is used to review AWS GenAI workloads against the AWS Well-Architected GenAI Lens, NIST AI Risk Management Framework, and FinOps Foundation FinOps for AI. The skill orchestrates a multi-framework review of Bedrock Agents and Bedrock AgentCore workloads. It accepts a Bedrock Agent ARN, CloudFormation/Terraform stack, or an AWS Resource Group as input, and coordinates framework-specific checks to produce a unified prioritized gap analysis report.

AIO2 evaluates AWS Generative AI solutions against three authoritative frameworks:
- [AWS Well-Architected Generative AI Lens](https://docs.aws.amazon.com/wellarchitected/latest/generative-ai-lens/generative-ai-lens.html)
- [NIST AI Risk Management Framework (AI RMF 1.0)](https://airc.nist.gov/airmf-resources/airmf/5-sec-core/) + [GenAI Profile (AI 600-1)](https://airc.nist.gov/Docs/1)
- [FinOps Foundation — FinOps for AI](https://www.finops.org/assets/) (AI Asset Library)

Using the open [Agent Skills](https://agentskills.io/) standard. Works in any IDE
that supports Agent Skills: Kiro, Cursor, Claude Code, and others.

## Prerequisites

- AWS CLI configured and authenticated with read access to the target account (see [Minimum IAM Permissions](#minimum-iam-permissions) for the required policy)
- An AI agent IDE that supports the Agent Skills standard
- POSIX Bash 3.2+
- [jq](https://jqlang.github.io/jq/)

## Skill

| Skill | Description | Activation Keywords |
|-------|-------------|-------------------|
| `aio2-review` | Orchestrates a multi-framework review — scope selection, framework selection, resource discovery, pillar assessments, and report generation. Loads pillar guides, check definitions, and report templates on demand as the review progresses. | "AIO2 review", "AIO2", "GenAI review", "multi-framework review", "WA review" |

### Documents Loaded On Demand

The skill reads these files progressively during the review — they are not loaded at activation.

| Document | Framework | Purpose |
|----------|-----------|---------|
| `wa-review-security.md` | WA | Security pillar — IAM, guardrails, VPC endpoints, CloudTrail, excessive agency |
| `wa-review-operational-excellence.md` | WA | Ops Excellence — monitoring, observability, tracing, IaC, GenAIOps |
| `wa-review-reliability.md` | WA | Reliability — retry logic, timeouts, cross-region, prompt catalogs |
| `wa-review-performance.md` | WA | Performance — benchmarking, load testing, model selection, vector stores |
| `wa-review-cost.md` | WA | Cost Optimization — model right-sizing, token optimization, pricing models |
| `wa-review-sustainability.md` | WA | Sustainability — serverless, managed services, model efficiency |
| `nist-ai-rmf-assessment.md` | NIST | NIST AI RMF — Govern, Map, Measure, Manage functions + GenAI Profile |
| `finops-ai-assessment.md` | FinOps | FinOps for AI — cost visibility, unit economics, optimization, practice management |
| `aio2-review-report-finalizer.md` | All | Report finalization — summary tables, executive summary, HTML generation |

## Installation

Copy the aio2-review folder into your agent's skills directory.

### Kiro
```bash
cp -r aio2-review /path/to/your/project/.kiro/skills/
```

### Cursor
```bash
cp -r aio2-review /path/to/your/project/.cursor/skills/
```

### Claude Code
```bash
cp -r aio2-review /path/to/your/project/.claude/skills/
```

### VS Code / GitHub Copilot
```bash
cp -r aio2-review /path/to/your/project/.github/skills/
```

### Windsurf
```bash
cp -r aio2-review /path/to/your/project/.windsurf/skills/
```

### Generic Cross-Platform
```bash
cp -r aio2-review /path/to/your/project/.agents/skills/
```

## Usage

Start a review by telling your agent:

> "Run a GenAI review of my solution"

The orchestrator will ask two questions:
1. **Review Scope** — Code Review, Cloud Review, or Full Review
2. **Framework Selection** — AWS Well-Architected, NIST AI RMF, FinOps for AI, or All

Then provide input based on scope:
- **Code Review**: Run from within the solution's code workspace
- **Cloud Review**: Provide a Bedrock Agent ARN, CloudFormation Stack ARN, AppRegistry Application ARN, or Resource Group ARN
- **Full Review**: Both of the above

## What It Reviews

| Framework | Checks | Source |
|-----------|:------:|--------|
| AWS Well-Architected | 100+ | WA Tool API (dynamic) + hardcoded fallback |
| NIST AI RMF | 36 | Versioned YAML (nist-ai-rmf-checks.yaml) |
| FinOps for AI | 20 | Versioned YAML (finops-ai-checks.yaml) |
| **Total** | **156+** | |

## Safety

All skills perform READ-ONLY operations only. AWS CLI commands are limited to
`get-*`, `list-*`, `describe-*`, `head-*`, `lookup-*`, `select-*`. No resources are created, modified, or deleted.
The only files written are the review reports.

## Minimum IAM Permissions

The skill requires **84 read-only API actions across 30 AWS services**. You can either:
1. Attach the AWS-managed **`ReadOnlyAccess`** policy (simplest, covers all calls including dynamic evidence collection)
2. Use the minimum custom policy below (strict least-privilege for hardcoded calls)

### Option 1: AWS-Managed Policy (Recommended)

```
arn:aws:iam::aws:policy/ReadOnlyAccess
```

### Option 2: Minimum Custom Policy

<details>
<summary>Click to expand full IAM policy JSON (84 actions)</summary>

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BedrockReadOnly",
      "Effect": "Allow",
      "Action": [
        "bedrock:GetGuardrail",
        "bedrock:GetInferenceProfile",
        "bedrock:GetModelInvocationLoggingConfiguration",
        "bedrock:ListCustomModels",
        "bedrock:ListEvaluationJobs",
        "bedrock:ListFoundationModels",
        "bedrock:ListGuardrails",
        "bedrock:ListInferenceProfiles",
        "bedrock:ListModelCustomizationJobs",
        "bedrock:ListProvisionedModelThroughputs"
      ],
      "Resource": "*"
    },
    {
      "Sid": "BedrockAgentReadOnly",
      "Effect": "Allow",
      "Action": [
        "bedrock:GetAgent",
        "bedrock:GetDataSource",
        "bedrock:GetFlow",
        "bedrock:GetKnowledgeBase",
        "bedrock:GetPrompt",
        "bedrock:ListAgentActionGroups",
        "bedrock:ListAgentAliases",
        "bedrock:ListAgentKnowledgeBases",
        "bedrock:ListAgentVersions",
        "bedrock:ListDataSources",
        "bedrock:ListFlowAliases",
        "bedrock:ListFlows",
        "bedrock:ListPrompts"
      ],
      "Resource": "*"
    },
    {
      "Sid": "BedrockAgentCoreReadOnly",
      "Effect": "Allow",
      "Action": [
        "bedrock:GetAgentRuntime",
        "bedrock:GetMemory",
        "bedrock:GetWorkloadIdentity",
        "bedrock:ListAgentRuntimes",
        "bedrock:ListGateways",
        "bedrock:ListMemories",
        "bedrock:ListPolicies",
        "bedrock:ListPolicyEngines",
        "bedrock:ListWorkloadIdentities"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CloudFormationReadOnly",
      "Effect": "Allow",
      "Action": [
        "cloudformation:GetTemplate",
        "cloudformation:ListStackResources"
      ],
      "Resource": "*"
    },
    {
      "Sid": "IAMReadOnly",
      "Effect": "Allow",
      "Action": [
        "iam:GetRole",
        "iam:GetRolePolicy",
        "iam:ListAttachedRolePolicies",
        "iam:ListRolePolicies"
      ],
      "Resource": "*"
    },
    {
      "Sid": "LambdaReadOnly",
      "Effect": "Allow",
      "Action": [
        "lambda:GetFunctionConfiguration"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CloudTrailReadOnly",
      "Effect": "Allow",
      "Action": [
        "cloudtrail:DescribeTrails",
        "cloudtrail:GetTrailStatus"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CloudWatchReadOnly",
      "Effect": "Allow",
      "Action": [
        "cloudwatch:DescribeAlarms",
        "cloudwatch:ListDashboards",
        "cloudwatch:ListMetrics"
      ],
      "Resource": "*"
    },
    {
      "Sid": "LogsReadOnly",
      "Effect": "Allow",
      "Action": [
        "logs:DescribeLogGroups"
      ],
      "Resource": "*"
    },
    {
      "Sid": "EC2ReadOnly",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeSubnets",
        "ec2:DescribeVpcEndpoints",
        "ec2:DescribeVpcs"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CognitoReadOnly",
      "Effect": "Allow",
      "Action": [
        "cognito-idp:ListUserPools"
      ],
      "Resource": "*"
    },
    {
      "Sid": "S3ReadOnly",
      "Effect": "Allow",
      "Action": [
        "s3:GetBucketEncryption",
        "s3:GetBucketPolicy",
        "s3:GetLifecycleConfiguration",
        "s3:ListAllMyBuckets"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SageMakerReadOnly",
      "Effect": "Allow",
      "Action": [
        "sagemaker:DescribeEndpoint",
        "sagemaker:DescribeEndpointConfig",
        "sagemaker:ListEndpoints",
        "sagemaker:ListMlflowTrackingServers"
      ],
      "Resource": "*"
    },
    {
      "Sid": "STSReadOnly",
      "Effect": "Allow",
      "Action": [
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ResourceGroupsReadOnly",
      "Effect": "Allow",
      "Action": [
        "resource-groups:GetGroup",
        "resource-groups:ListGroupResources"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AppRegistryReadOnly",
      "Effect": "Allow",
      "Action": [
        "servicecatalog:GetApplication",
        "servicecatalog:ListAssociatedResources"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CostExplorerReadOnly",
      "Effect": "Allow",
      "Action": [
        "ce:GetAnomalyMonitors",
        "ce:GetAnomalySubscriptions",
        "ce:GetCostAndUsage",
        "ce:ListCostAllocationTags"
      ],
      "Resource": "*"
    },
    {
      "Sid": "BudgetsReadOnly",
      "Effect": "Allow",
      "Action": [
        "budgets:ViewBudget"
      ],
      "Resource": "*"
    },
    {
      "Sid": "GuardDutyReadOnly",
      "Effect": "Allow",
      "Action": [
        "guardduty:GetDetector",
        "guardduty:ListDetectors"
      ],
      "Resource": "*"
    },
    {
      "Sid": "OrganizationsReadOnly",
      "Effect": "Allow",
      "Action": [
        "organizations:DescribePolicy",
        "organizations:ListPolicies"
      ],
      "Resource": "*"
    },
    {
      "Sid": "MiscReadOnly",
      "Effect": "Allow",
      "Action": [
        "apigateway:GET",
        "application-autoscaling:DescribeScalableTargets",
        "config:DescribeConfigurationRecorders",
        "events:ListRules",
        "events:ListTargetsByRule",
        "route53:ListHealthChecks",
        "servicequotas:ListRequestedServiceQuotaChangeHistory",
        "sns:ListSubscriptions",
        "sns:ListTopics",
        "states:ListStateMachines",
        "wafv2:ListWebACLs",
        "xray:GetSamplingRules"
      ],
      "Resource": "*"
    }
  ]
}
```

</details>

### Services Accessed (30)

| # | Service | Actions | Purpose |
|---|---------|:-------:|---------|
| 1 | Amazon Bedrock | 10 | Guardrails, models, inference profiles, invocation logging |
| 2 | Bedrock Agents (deprecated) | 13 | Agent config, KBs, flows, prompts, action groups |
| 3 | Bedrock AgentCore | 9 | Runtimes, gateways, identities, memory, policies |
| 4 | CloudFormation | 2 | Stack resources and templates |
| 5 | IAM | 4 | Role policies and permissions |
| 6 | Lambda | 1 | Function configuration |
| 7 | CloudTrail | 2 | Trail status and config |
| 8 | CloudWatch | 3 | Alarms, dashboards, metrics |
| 9 | CloudWatch Logs | 1 | Log group discovery |
| 10 | EC2 | 4 | VPC endpoints, security groups, subnets |
| 11 | Cognito | 1 | User pool discovery |
| 12 | S3 | 4 | Bucket encryption, policies, lifecycle |
| 13 | SageMaker | 4 | Endpoints and tracking servers |
| 14 | STS | 1 | Caller identity |
| 15 | Resource Groups | 2 | Group membership |
| 16 | Service Catalog AppRegistry | 2 | Application resources |
| 17 | Cost Explorer | 4 | Cost, anomalies, allocation tags |
| 18 | Budgets | 1 | Budget thresholds |
| 19 | GuardDuty | 2 | Threat detection config |
| 20 | Organizations | 2 | SCPs and policies |
| 21 | API Gateway | 1 | REST API discovery |
| 22 | Application Auto Scaling | 1 | Scalable targets |
| 23 | Config | 1 | Configuration recorders |
| 24 | EventBridge | 2 | Rules and targets |
| 25 | Route 53 | 1 | Health checks |
| 26 | Service Quotas | 1 | Quota change history |
| 27 | SNS | 2 | Topics and subscriptions |
| 28 | Step Functions | 1 | State machine discovery |
| 29 | WAFv2 | 1 | Web ACL discovery |
| 30 | X-Ray | 1 | Sampling rules |

> **Note:** The `dynamic-cli.sh` helper can call additional read-only APIs at runtime
> (constrained to `get-*`, `list-*`, `describe-*` verb prefixes). If using the custom
> policy and a check fails with `AccessDenied`, either add the specific action or switch
> to the managed `ReadOnlyAccess` policy.

## Source Frameworks

- [AWS Well-Architected Generative AI Lens](https://docs.aws.amazon.com/wellarchitected/latest/generative-ai-lens/generative-ai-lens.html)
- [NIST AI Risk Management Framework 1.0](https://airc.nist.gov/airmf-resources/airmf/5-sec-core/) + [GenAI Profile AI 600-1](https://airc.nist.gov/Docs/1)
- [FinOps Foundation — FinOps for AI Asset Library](https://www.finops.org/assets/) (CC BY 4.0)
- [AgentCore Enterprise Best Practices](https://aws.amazon.com/blogs/machine-learning/ai-agents-in-enterprises-best-practices-with-amazon-bedrock-agentcore/)

## Attribution

### NIST AI Risk Management Framework

The NIST checks (`nist-ai-rmf-assessment.md`, `nist-ai-rmf-checks.yaml`) are derived from
publications of the U.S. National Institute of Standards and Technology, a federal agency:

- [AI Risk Management Framework (AI RMF 1.0)](https://airc.nist.gov/airmf-resources/airmf/5-sec-core/)
- [Generative AI Profile (NIST AI 600-1)](https://airc.nist.gov/Docs/1)

NIST publications are U.S. Government works. This skill's checks are an original
interpretation of the Govern/Map/Measure/Manage functions and GenAI Profile for the
purpose of automated review — they are not verbatim reproductions of NIST text.

### FinOps Foundation — FinOps for AI

The FinOps checks (`finops-ai-assessment.md`, `finops-ai-checks.yaml`) are adapted from
the FinOps Foundation's FinOps for AI asset library:

- [FinOps for AI Overview](https://www.finops.org/wg/finops-for-ai-overview/)
- [AI Technology Category](https://www.finops.org/framework/technology-categories/ai/)
- [Token Economics for SaaS](https://www.finops.org/wg/token-economics-saas/)
- [How to Use the FinOps Framework](https://www.finops.org/introduction/how-to-use/)

These assets are the work of the **FinOps Foundation** and are licensed under
[Creative Commons Attribution 4.0 International (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/):

> © FinOps Foundation, a Series of LF Projects, LLC. Licensed under CC BY 4.0.

Changes were made to the original material. The source guidance has been adapted into
discrete, machine-checkable review items (`finops-ai-checks.yaml`) and narrative guidance
(`finops-ai-assessment.md`) for use by an AI coding agent, and does not reproduce the
original assets verbatim.

This attribution does not imply that the FinOps Foundation endorses this skill or any
specific review produced by it.

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.
