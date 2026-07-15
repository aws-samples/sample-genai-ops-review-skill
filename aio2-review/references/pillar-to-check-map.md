
# The Six Pillars → Check Mapping

**Six Pillars** for an Operations GenAI Strategy:

| # | Pillar | Core Focus |
|---|--------|------------|
| 1 | **Governance and Compliance** | Data cataloguing/classification, data lineage, data quality, data freshness, GenAI operating boundaries, real-time governance (Guardrails, AgentCore Policy), human accountability, logging/audit trails, responsible AI & ethics |
| 2 | **Operational Reliability** | AgentOps (version control, CI/CD for prompts), quality monitoring/evaluation, model upgrades, performance testing & quota management, disaster recovery, incident response for agent-caused issues, agent lifecycle management, multi-agent observability |
| 3 | **Data Access and Integration** | MCP servers as shared infrastructure, tool versioning, staged rollouts, integration patterns |
| 4 | **Cost Management** | Token economics, cost visibility & tagging, optimization strategies (prompt caching, model routing, prompt trimming), budget controls, DevOps Agent cost model |
| 5 | **Security and Forensics** | Forensic traceability, audit trails, threat detection & anomaly monitoring, prompt injection defence, security architecture (infrastructure/application/user layers), credential security, zero-trust |
| 6 | **Organisational Readiness** | Centre of Excellence, training & skills, hackathon enablement, measuring ROI, customer satisfaction metrics, platform hosting decisions, Agent Registry |

---
---

## PILLAR 1: Governance and Compliance

*Data cataloguing/classification, data lineage, data quality, data freshness, GenAI operating boundaries, real-time governance (Guardrails, AgentCore Policy), human accountability, logging/audit trails, responsible AI & ethics*

### DUP-05: Guardrails / Safety Controls

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| GENSEC02_BP01 | WA Security | Pillar 1, Pillar 5 | Are guardrails implemented (content/topic/word/sensitive-info filters)? |
| RAI_SAFETY | WA Responsible AI | Pillar 1, Pillar 5 | Are safety guardrails implemented to reduce harmful outputs and misuse? |
| INVOCATION_GUARDRAIL | WA Security (Resource) | Pillar 1, Pillar 5 | Is a guardrail attached to direct invocation calls? |
| MEASURE-2.6 | NIST | Pillar 1, Pillar 2 | AI system evaluated regularly for safety risks, can fail safely |

### DUP-06: Audit Logging / Invocation Monitoring

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| GENSEC03_BP01 | WA Security | Pillar 1, Pillar 5 | Is control plane and data plane monitoring implemented (CloudTrail, invocation logging)? |
| GENSEC01_BP04 | WA Security | Pillar 1, Pillar 5 | Is access monitoring implemented for gen AI services (CloudTrail, access logs)? |
| INVOCATION_LOGGING | WA Security (Resource) | Pillar 1, Pillar 5 | Is model invocation logging enabled? |

### DUP-07: Human Oversight / Kill Switches

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| GENSEC05_CONFIRM | WA Security | Pillar 1, Pillar 5 | Is user confirmation implemented for high-impact agent actions? |
| RAI_CONTROLLABILITY | WA Responsible AI | Pillar 1, Pillar 2 | Are mechanisms in place to monitor and steer agent behavior (human-in-the-loop, kill switches)? |
| MAP-3.5 | NIST | Pillar 1 | Human oversight processes defined and documented |
| MAP-2.2 | NIST | Pillar 1 | Knowledge limits and human oversight documented |
| MANAGE-2.4 | NIST | Pillar 2 | Mechanisms to disengage or deactivate AI systems with inconsistent performance |

### DUP-15: Governance Framework / Ethics

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| RAI_GOVERNANCE | WA Responsible AI | Pillar 1, Pillar 6 | Is an AI governance framework established (committee, documentation, review processes)? |
| GOVERN-1.2 | NIST | Pillar 1 | Trustworthy AI characteristics integrated into organizational policies |
| FIN-QBV-03 | FinOps | Pillar 1, Pillar 4, Pillar 6 | Cross-functional AI Investment Council aligns investments with strategic goals |

### DUP-17: Least-Privilege for Agents

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| GENSEC05_BP01 | WA Security | Pillar 1, Pillar 5 | Are least-privilege IAM roles and permission boundaries applied to agent execution roles? |
| GENSEC01_BP01 | WA Security | Pillar 5 | Is least-privilege access granted to foundation model endpoints? |
| GENSEC01_BP03 | WA Security | Pillar 5 | Are least-privilege permissions applied for FM access to data stores? |
| BP06_03 | WA AgentCore | Pillar 1, Pillar 5 | Is AgentCore Policy enforcing per-user, per-tool access control via Gateway interceptors? |

### DUP-18: Privacy / PII Handling

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| RAI_PRIVACY | WA Responsible AI | Pillar 1, Pillar 5 | Are data protection mechanisms in place (encryption, access controls, PII handling)? |
| MEASURE-2.10 | NIST | Pillar 1, Pillar 5 | Privacy risk of the AI system examined and documented |

### DUP-19: Bias / Fairness Evaluation

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| RAI_FAIRNESS | WA Responsible AI | Pillar 1 | Are impacts on different stakeholder groups considered, with bias testing across diverse user segments? |
| MEASURE-2.11 | NIST | Pillar 1, Pillar 6 | Fairness and bias evaluated and documented |

### DUP-21: Security & Adversarial Testing

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| RAI_VERACITY | WA Responsible AI | Pillar 1, Pillar 2 | Is the agent tested for correctness under normal and adversarial inputs (hallucination detection)? |
| GENSEC04_BP02 | WA Security | Pillar 5 | Are user inputs sanitized and validated (prompt injection prevention, input filtering)? |
| MEASURE-2.7 | NIST | Pillar 5 | AI system security and resilience evaluated and documented |

### DUP-25: Explainability / Reasoning Traces

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| RAI_EXPLAINABILITY | WA Responsible AI | Pillar 1, Pillar 5 | Can the agent's decisions be understood and explained (reasoning traces, attribution)? |
| RAI_TRANSPARENCY | WA Responsible AI | Pillar 1, Pillar 6 | Is it clearly communicated when/how AI is used, what data informs decisions, and what controls exist? |
| MEASURE-2.9 | NIST | Pillar 5, Pillar 6 | AI model explained, validated, documented; output interpreted in context |

### DUP-29: Agent Scoping / Boundaries

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| BP01_01 | WA AgentCore | Pillar 1 | Is there a written definition of what the agent should and should not do? |
| AGENT_AGENCY_SPECTRUM | WA Agentic | Pillar 1 | Has the degree of agency been deliberately chosen to match task complexity? |
| MAP-2.2 | NIST | Pillar 1 | Knowledge limits and human oversight documented |
| GOVERN-1.3 | NIST | Pillar 1 | Risk tolerance-based activity levels determined |

### Unique Checks — Pillar 1

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| GENSEC06_BP01 | WA Security | Pillar 1, Pillar 5 | Are data purification filters implemented for training/customization workflows? |
| KB_ACCESS_CONTROL | WA Security (Resource) | Pillar 1, Pillar 5 | Are resource policies configured to restrict KB access? |
| GOVERN-1.1 | NIST | Pillar 1 | Legal and regulatory requirements involving AI are understood, managed, and documented |
| GOVERN-1.5 | NIST | Pillar 1, Pillar 2 | Ongoing monitoring and periodic review of risk management planned |
| MANAGE-1.3 | NIST | Pillar 1 | Responses to high-priority AI risks developed and documented |
| LC_SCOPING | WA Lifecycle | Pillar 1, Pillar 6 | Has the business problem been defined with success metrics, risk profile, and cost considerations? |

---

## PILLAR 2: Operational Reliability

*AgentOps (version control, CI/CD for prompts), quality monitoring/evaluation, model upgrades, performance testing & quota management, disaster recovery, incident response for agent-caused issues, agent lifecycle management, multi-agent observability*

### DUP-08: Prompt Versioning & Rollback

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| GENOPS03_BP01 | WA Ops Excellence | Pillar 2 | Is a versioned prompt template management system implemented? |
| GENREL04_BP01 | WA Reliability | Pillar 2 | Is a prompt catalog with version control and rollback implemented? |
| GENSEC04_BP01 | WA Security | Pillar 2, Pillar 5 | Is a secure prompt catalog implemented with access controls and versioning? |
| BP08_04 | WA AgentCore | Pillar 2 | Are automated rollback mechanisms in place? |

### DUP-09: Production Monitoring / Observability

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| GENOPS02_BP01 | WA Ops Excellence | Pillar 2 | Is comprehensive monitoring implemented across all application layers? |
| GENOPS02_BP02 | WA Ops Excellence | Pillar 2 | Are foundation model metrics monitored continuously? |
| GENOPS03_BP02 | WA Ops Excellence | Pillar 2, Pillar 5 | Is tracing enabled for agent reasoning steps and RAG workflows? |
| GENPERF01_BP02 | WA Performance | Pillar 2 | Are performance metrics collected (latency, throughput, quality, utilization)? |
| MEASURE-2.4 | NIST | Pillar 2 | AI system functionality and behavior monitored in production |
| BP02_01 | WA AgentCore | Pillar 2, Pillar 5 | Is AgentCore Observability enabled with trace-level debugging? |
| BP08_03 | WA AgentCore | Pillar 2 | Is drift detection configured with automated alerts? |

### DUP-10: Evaluation / Ground Truth Testing

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| GENOPS01_BP01 | WA Ops Excellence | Pillar 2 | Is functional performance periodically evaluated using stratified sampling and ground truth data? |
| BP04_01 | WA AgentCore | Pillar 2 | Are AgentCore Evaluations configured (on-demand and/or online)? |
| BP01_03 | WA AgentCore | Pillar 2 | Does a ground truth evaluation dataset exist with common queries and edge cases? |
| BP04_03 | WA AgentCore | Pillar 2 | Is evaluation run automatically on every prompt, tool, or model change? |
| BP08_01 | WA AgentCore | Pillar 2 | Is there an automated regression test suite? |
| GENPERF01_BP01 | WA Performance | Pillar 2 | Is a ground truth dataset defined for performance benchmarking? |
| LC_DEVELOPMENT | WA Lifecycle | Pillar 2, Pillar 3 | Has the model been integrated with all components and tested end-to-end? |
| GOVERN-4.3 | NIST | Pillar 1, Pillar 2 | AI testing, incident identification, and information sharing practices established |
| MEASURE-2.1 | NIST | Pillar 2, Pillar 5 | Test sets, metrics, and TEVV tools documented |

### DUP-11: Timeouts / Stopping Conditions

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| GENCOST05_BP01 | WA Cost | Pillar 2, Pillar 4 | Are stopping conditions and timeouts configured for agentic workflows? |
| GENREL03_BP02 | WA Reliability | Pillar 2, Pillar 4 | Are timeout mechanisms implemented on agentic workflows? |
| AGENT_LOOP_CONTROL | WA Agentic | Pillar 2, Pillar 4 | Does the agent loop have a defined stop reason with enforced stopping conditions? |

### DUP-12: Model Catalog / Version Management

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| GENREL04_BP02 | WA Reliability | Pillar 2, Pillar 6 | Is a model catalog implemented to standardize and version FMs? |
| LC_MODEL_SELECTION | WA Lifecycle | Pillar 4, Pillar 6 | Has model selection considered modality, size, accuracy, pricing, context window, and latency? |
| LC_CUSTOMIZATION | WA Lifecycle | Pillar 2 | Has the customization approach been determined with iterative evaluation? |
| GENOPS05_BP01 | WA Ops Excellence | Pillar 2, Pillar 6 | Is there a documented decision framework for when to customize models? |
| MANAGE-3.2 | NIST | Pillar 2 | Pre-trained models monitored for version changes and deprecation |

### DUP-13: CI/CD & IaC for Agents

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| GENOPS04_BP01 | WA Ops Excellence | Pillar 2 | Is infrastructure defined and managed as code with CI/CD? |
| GENOPS04_BP02 | WA Ops Excellence | Pillar 2 | Is a GenAIOps/LLMOps pipeline implemented? |
| LC_DEPLOYMENT | WA Lifecycle | Pillar 2 | Is deployment managed via CI/CD with IaC, version control, and rollback? |

### DUP-14: Graceful Failure / Fallback

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| GENREL03_BP01 | WA Reliability | Pillar 2 | Is logic implemented for graceful failure recovery (retry, backoff, circuit breakers)? |
| GOVERN-6.2 | NIST | Pillar 1, Pillar 2 | Contingency processes for third-party AI failures |
| BP03_04 | WA AgentCore | Pillar 2 | Are error handling and retry behaviors documented per tool? |

### DUP-26: Feedback Loops / Continuous Improvement

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| GENOPS01_BP02 | WA Ops Excellence | Pillar 2, Pillar 6 | Is user feedback collected and monitored? |
| LC_CONTINUOUS_IMPROVEMENT | WA Lifecycle | Pillar 2, Pillar 6 | Is there an ongoing process for monitoring, feedback, and iteration? |
| MANAGE-2.2 | NIST | Pillar 2, Pillar 6 | Mechanisms to sustain value of deployed AI systems |

### DUP-27: Auto-Scaling / Quota Management

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| GENOPS02_BP03 | WA Ops Excellence | Pillar 2 | Are rate limiting, throttling, and auto-scaling mechanisms implemented? |
| GENSUS01_BP01 | WA Sustainability | Pillar 2 | Are auto-scaling and serverless architectures used? |
| GENREL01_BP01 | WA Reliability | Pillar 2 | Are FM throughput quotas monitored with scaling/load-balancing? |

### DUP-32: Multi-Agent Decomposition

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| AGENT_MULTI_AGENT | WA Agentic | Pillar 2 | For multi-agent systems: are task queues, auto-scaling, and async execution patterns used? |
| BP05_01 | WA AgentCore | Pillar 2, Pillar 6 | If >10 tools or diverse domains, has decomposition been considered? |
| BP05_03 | WA AgentCore | Pillar 2 | Are handoff failures between agents monitored? |

### DUP-36: VPC / Private Networking

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| GENSEC01_BP02 | WA Security | Pillar 5 | Is private network communication implemented (VPC endpoints, PrivateLink)? |
| SM_VPC_CONFIG | WA Security (Resource) | Pillar 5 | Is the SageMaker endpoint deployed in a VPC? |
| GENREL02_BP01 | WA Reliability | Pillar 2 | Are redundant network connections implemented? |

### DUP-37: Decommissioning / Retirement

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| GOVERN-1.7 | NIST | Pillar 2 | Decommissioning processes in place for AI systems |
| MANAGE-2.4 | NIST | Pillar 2 | Mechanisms to disengage or deactivate AI systems with inconsistent performance |

### Unique Checks — Pillar 2

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| GENPERF02_BP01 | WA Performance | Pillar 2 | Are model endpoints load-tested under expected and peak traffic? |
| GENREL05_BP01 | WA Reliability | Pillar 2 | Are inference requests load-balanced across regions? |
| GENREL05_BP02 | WA Reliability | Pillar 2, Pillar 3 | Is embedding data replicated across regions for RAG? |
| GENREL05_BP03 | WA Reliability | Pillar 2 | Are agent capabilities verified across all target regions? |
| GENREL06_BP01 | WA Reliability | Pillar 2 | Are distributed compute tasks fault-tolerant with checkpointing? |
| BP02_03 | WA AgentCore | Pillar 2 | Is observability data exported to the organization's existing monitoring system? |
| BP07_01 | WA AgentCore | Pillar 2 | Are calculations and validations handled by deterministic code? |
| BP08_02 | WA AgentCore | Pillar 2 | Is A/B testing or traffic splitting used for major changes? |
| MANAGE-4.1 | NIST | Pillar 2 | Post-deployment monitoring with incident response and recovery |
| AGENT_PATTERN_SELECTION | WA Agentic | Pillar 2, Pillar 6 | Is the agentic pattern appropriate (LLM-augmented / autonomous ReACT / hybrid)? |

---

## PILLAR 3: Data Access and Integration

*MCP servers as shared infrastructure, tool versioning, staged rollouts, integration patterns, knowledge base connectivity*

### DUP-16: Tool Definitions / MCP Clarity

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| BP01_02 | WA AgentCore | Pillar 3 | Are tool definitions unambiguous with explicit parameters, return formats, and error conditions? |
| BP03_01 | WA AgentCore | Pillar 3 | Do tool descriptions include clear name, explicit parameters, return format, error conditions? |
| BP03_02 | WA AgentCore | Pillar 3 | Is MCP used for tool interoperability via AgentCore Gateway? |
| AGENT_TOOL_PROTOCOL | WA Agentic | Pillar 3 | Are tools connected via MCP with clear descriptions, and is the system prompt well-defined? |

### DUP-28: Vector Store Optimization

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| GENPERF04_BP02 | WA Performance | Pillar 3, Pillar 4 | Are vector sizes optimized for the use case? |
| GENCOST04_BP01 | WA Cost | Pillar 4 | Are vector lengths reduced to optimize storage and query costs? |

### DUP-30: RAG / Knowledge Base Quality

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| AGENT_RETRIEVAL | WA Agentic | Pillar 1, Pillar 3 | If RAG is used, is the knowledge base well-structured, regularly updated, and performance-tested? |
| GENPERF04_BP01 | WA Performance | Pillar 2, Pillar 3 | Are vector embeddings tested for latency and retrieval relevance? |

### DUP-31: Agent Memory Management

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| AGENT_MEMORY | WA Agentic | Pillar 3, Pillar 6 | Is the agent augmented with appropriate memory (short-term and/or long-term) via AgentCore Memory? |
| BP05_02 | WA AgentCore | Pillar 3 | Is AgentCore Memory used for shared context across agent handoffs? |
| BP06_04 | WA AgentCore | Pillar 3, Pillar 5 | Is AgentCore Memory namespaced per user for personalization? |

### DUP-38: Third-Party Risk Management

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| GOVERN-6.1 | NIST | Pillar 1, Pillar 5 | Third-party AI risk policies in place including IP rights |
| MAP-4.1 | NIST | Pillar 1, Pillar 3 | Third-party component risk mapping for all components |
| MANAGE-3.2 | NIST | Pillar 2 | Pre-trained models monitored for version changes and deprecation |

### Unique Checks — Pillar 3

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| BP03_03 | WA AgentCore | Pillar 3, Pillar 5, Pillar 6 | Is there a centralized, security-reviewed tool catalog? |
| GENREL05_BP02 | WA Reliability | Pillar 2, Pillar 3 | Is embedding data replicated across regions for RAG? |
| MAP-1.1 | NIST | Pillar 1, Pillar 3 | Intended purposes, deployment context, and beneficial uses documented |
| MAP-2.1 | NIST | Pillar 3 | Specific AI tasks and methods defined |

---

## PILLAR 4: Cost Management

*Token economics, cost visibility & tagging, optimization strategies (prompt caching, model routing, prompt trimming), budget controls, DevOps Agent cost model*

### DUP-01: Model Right-Sizing

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| GENCOST01_BP01 | WA Cost | Pillar 4 | Is the model right-sized for task complexity? |
| FIN-OPT-01 | FinOps | Pillar 4 | Model right-sized for task complexity (smaller for simple, larger for complex) |
| GENPERF02_BP03 | WA Performance | Pillar 4, Pillar 6 | Has the appropriate model been selected and customized for the use case? |
| GENSUS03_BP01 | WA Sustainability | Pillar 4 | Are smaller models and optimized inference techniques leveraged? |

### DUP-02: Prompt Token Optimization

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| GENCOST03_BP01 | WA Cost | Pillar 4 | Are prompt token lengths optimized? |
| FIN-OPT-02 | FinOps | Pillar 4 | Prompts optimized for token efficiency |

### DUP-03: Prompt Caching

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| GENCOST03_BP03 | WA Cost | Pillar 4 | Is prompt caching implemented to reduce redundant token costs? |
| FIN-OPT-03 | FinOps | Pillar 4 | Prompt caching enabled for repeated or similar prompts |

### DUP-04: Content Pre-Filtering for Cost

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| GENCOST03_BP04 | WA Cost | Pillar 1, Pillar 4 | Is cost-aware content filtering implemented to pre-filter inputs? |
| FIN-OPT-07 | FinOps | Pillar 1, Pillar 4 | Content pre-filtering/guardrails block unnecessary requests before consuming tokens |

### DUP-20: Compute / Resource Optimization

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| GENCOST02_BP02 | WA Cost | Pillar 4 | Is resource consumption optimized to minimize hosting costs? |
| FIN-OPT-04 | FinOps | Pillar 4 | GPU/compute resources right-sized with utilization monitored |

### DUP-22: Cost Attribution / Tagging

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| FIN-UND-01 | FinOps | Pillar 4 | AI workloads identified, tagged, and tracked with granular cost attribution |
| FIN-UND-05 | FinOps | Pillar 4 | AI workloads identified and distinguished from non-AI workloads |
| BP09_03 | WA AgentCore | Pillar 4, Pillar 6 | Is centralized cost and usage monitoring configured across agents? |

### DUP-23: Cost Tracking / Visibility Dashboards

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| FIN-UND-04 | FinOps | Pillar 4 | Dedicated AI cost and usage tracking mechanism in place |
| FIN-UND-02 | FinOps | Pillar 4 | Token consumption tracked per model, per application, and per team |
| FIN-MGT-02 | FinOps | Pillar 4 | Budget controls, quotas, and anomaly detection for AI spending |
| BP02_02 | WA AgentCore | Pillar 2, Pillar 4 | Are production dashboards configured for token usage, latency, error rates, and tool invocation patterns? |
| GENOPS02_BP02 | WA Ops Excellence | Pillar 2 | Are foundation model metrics monitored continuously? |

### DUP-24: ROI / Business Value Measurement

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| FIN-QBV-01 | FinOps | Pillar 4, Pillar 6 | AI unit economics defined and tracked (cost per query, per transaction, per outcome) |
| FIN-QBV-02 | FinOps | Pillar 4, Pillar 6 | AI ROI measured against business value with clear metrics at each lifecycle stage |
| BP04_02 | WA AgentCore | Pillar 4, Pillar 6 | Are both technical metrics and business metrics tracked? |

### DUP-33: Pricing / Capacity Strategy

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| GENCOST02_BP01 | WA Cost | Pillar 4 | Is the inference pricing paradigm optimized (on-demand vs provisioned vs batch)? |
| FIN-OPT-05 | FinOps | Pillar 4 | Capacity commitment strategy in place (pay-as-you-go vs provisioned) |

### DUP-39: Response Length / Inference Parameters

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| GENCOST03_BP02 | WA Cost | Pillar 4 | Are model response lengths controlled via max token limits? |
| GENPERF02_BP02 | WA Performance | Pillar 2, Pillar 4 | Are inference parameters (temperature, top-p, max tokens) optimized? |

### Unique Checks — Pillar 4

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| FIN-UND-03 | FinOps | Pillar 4 | Team understands token pricing nuances (context window creep, input/output asymmetry) |
| FIN-MGT-03 | FinOps | Pillar 4 | AI cost forecasting accounts for non-linear scaling |
| FIN-MGT-04 | FinOps | Pillar 4, Pillar 6 | Incremental funding with frequent fail-fast reviews |

---

## PILLAR 5: Security and Forensics

*Forensic traceability, audit trails, threat detection & anomaly monitoring, prompt injection defence, security architecture (infrastructure/application/user layers), credential security, zero-trust*

### DUP-05: Guardrails / Safety Controls

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| GENSEC02_BP01 | WA Security | Pillar 1, Pillar 5 | Are guardrails implemented (content/topic/word/sensitive-info filters)? |
| RAI_SAFETY | WA Responsible AI | Pillar 1, Pillar 5 | Are safety guardrails implemented to reduce harmful outputs and misuse? |
| INVOCATION_GUARDRAIL | WA Security (Resource) | Pillar 1, Pillar 5 | Is a guardrail attached to direct invocation calls? |
| MEASURE-2.6 | NIST | Pillar 1, Pillar 2 | AI system evaluated regularly for safety risks, can fail safely |

### DUP-06: Audit Logging / Invocation Monitoring

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| GENSEC03_BP01 | WA Security | Pillar 1, Pillar 5 | Is control plane and data plane monitoring implemented (CloudTrail, invocation logging)? |
| GENSEC01_BP04 | WA Security | Pillar 1, Pillar 5 | Is access monitoring implemented for gen AI services (CloudTrail, access logs)? |
| INVOCATION_LOGGING | WA Security (Resource) | Pillar 1, Pillar 5 | Is model invocation logging enabled? |

### DUP-17: Least-Privilege for Agents

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| GENSEC01_BP01 | WA Security | Pillar 5 | Is least-privilege access granted to foundation model endpoints? |
| GENSEC01_BP03 | WA Security | Pillar 5 | Are least-privilege permissions applied for FM access to data stores? |
| GENSEC05_BP01 | WA Security | Pillar 1, Pillar 5 | Are least-privilege IAM roles and permission boundaries applied to agent execution roles? |
| BP06_03 | WA AgentCore | Pillar 1, Pillar 5 | Is AgentCore Policy enforcing per-user, per-tool access control via Gateway interceptors? |

### DUP-18: Privacy / PII Handling

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| RAI_PRIVACY | WA Responsible AI | Pillar 1, Pillar 5 | Are data protection mechanisms in place (encryption, access controls, PII handling)? |
| MEASURE-2.10 | NIST | Pillar 1, Pillar 5 | Privacy risk of the AI system examined and documented |

### DUP-21: Security & Adversarial Testing

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| GENSEC04_BP02 | WA Security | Pillar 5 | Are user inputs sanitized and validated (prompt injection prevention, input filtering)? |
| MEASURE-2.7 | NIST | Pillar 5 | AI system security and resilience evaluated and documented |
| RAI_VERACITY | WA Responsible AI | Pillar 1, Pillar 2 | Is the agent tested for correctness under normal and adversarial inputs (hallucination detection)? |

### DUP-25: Explainability / Reasoning Traces

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| RAI_EXPLAINABILITY | WA Responsible AI | Pillar 1, Pillar 5 | Can the agent's decisions be understood and explained (reasoning traces, attribution)? |
| RAI_TRANSPARENCY | WA Responsible AI | Pillar 1, Pillar 6 | Is it clearly communicated when/how AI is used, what data informs decisions, and what controls exist? |
| MEASURE-2.9 | NIST | Pillar 5, Pillar 6 | AI model explained, validated, documented; output interpreted in context |

### DUP-35: Encryption at Rest

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| KB_DATA_SOURCE_ENCRYPTION | WA Security (Resource) | Pillar 5 | Is data source encryption enabled? |
| SM_ENCRYPTION | WA Security (Resource) | Pillar 5 | Is KMS encryption configured for model artifacts? |

### DUP-36: VPC / Private Networking

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| GENSEC01_BP02 | WA Security | Pillar 5 | Is private network communication implemented (VPC endpoints, PrivateLink)? |
| SM_VPC_CONFIG | WA Security (Resource) | Pillar 5 | Is the SageMaker endpoint deployed in a VPC? |
| GENREL02_BP01 | WA Reliability | Pillar 2 | Are redundant network connections implemented? |

### Unique Checks — Pillar 5

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| GENSEC06_BP01 | WA Security | Pillar 1, Pillar 5 | Are data purification filters implemented for training/customization workflows? |
| BP06_01 | WA AgentCore | Pillar 5 | Is session isolation enforced via AgentCore Runtime microVMs? |
| BP06_02 | WA AgentCore | Pillar 5 | Is AgentCore Identity integrated with an IdP (Cognito, Entra ID, Okta)? |
| KB_ACCESS_CONTROL | WA Security (Resource) | Pillar 1, Pillar 5 | Are resource policies configured to restrict KB access? |
| MEASURE-1.1 | NIST | Pillar 1, Pillar 5 | Risk measurement approaches selected for most significant risks |
| MAP-1.6 | NIST | Pillar 1, Pillar 5 | System requirements address socio-technical implications |
| MAP-5.1 | NIST | Pillar 1, Pillar 5 | Impact likelihood and magnitude assessed and documented |

---

## PILLAR 6: Organisational Readiness

*Centre of Excellence, training & skills, hackathon enablement, measuring ROI, customer satisfaction metrics, platform hosting decisions, Agent Registry*

### DUP-15: Governance Framework / Ethics

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| RAI_GOVERNANCE | WA Responsible AI | Pillar 1, Pillar 6 | Is an AI governance framework established (committee, documentation, review processes)? |
| GOVERN-1.2 | NIST | Pillar 1 | Trustworthy AI characteristics integrated into organizational policies |
| FIN-QBV-03 | FinOps | Pillar 1, Pillar 4, Pillar 6 | Cross-functional AI Investment Council aligns investments with strategic goals |

### DUP-24: ROI / Business Value Measurement

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| FIN-QBV-01 | FinOps | Pillar 4, Pillar 6 | AI unit economics defined and tracked (cost per query, per transaction, per outcome) |
| FIN-QBV-02 | FinOps | Pillar 4, Pillar 6 | AI ROI measured against business value with clear metrics at each lifecycle stage |
| BP04_02 | WA AgentCore | Pillar 4, Pillar 6 | Are both technical metrics and business metrics tracked? |

### DUP-26: Feedback Loops / Continuous Improvement

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| GENOPS01_BP02 | WA Ops Excellence | Pillar 2, Pillar 6 | Is user feedback collected and monitored? |
| LC_CONTINUOUS_IMPROVEMENT | WA Lifecycle | Pillar 2, Pillar 6 | Is there an ongoing process for monitoring, feedback, and iteration? |
| MANAGE-2.2 | NIST | Pillar 2, Pillar 6 | Mechanisms to sustain value of deployed AI systems |

### DUP-34: CoE / Platform Team / Org Roles

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| BP09_01 | WA AgentCore | Pillar 6 | Is there a platform team maintaining shared tools and standards? |
| BP09_02 | WA AgentCore | Pillar 3, Pillar 6 | Is cross-team tool sharing enabled via AgentCore Gateway? |
| BP03_03 | WA AgentCore | Pillar 3, Pillar 5, Pillar 6 | Is there a centralized, security-reviewed tool catalog? |
| GOVERN-1.6 | NIST | Pillar 1, Pillar 6 | AI system inventory mechanisms in place |
| GOVERN-2.1 | NIST | Pillar 1, Pillar 6 | Roles and responsibilities for AI risk management documented |
| GOVERN-2.2 | NIST | Pillar 6 | AI risk management training provided |
| FIN-MGT-01 | FinOps | Pillar 4, Pillar 6 | Clear ownership and accountability for AI spending established |
| FIN-MGT-05 | FinOps | Pillar 4, Pillar 6 | Teams trained on FinOps best practices for AI workloads |

### DUP-40: Managed Services / Infrastructure Strategy

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| GENPERF03_BP01 | WA Performance | Pillar 2, Pillar 6 | Are managed services used for hosting, customization, and data access? |
| GENSUS01_BP02 | WA Sustainability | Pillar 4, Pillar 6 | Are efficient managed customization services used? |
| FIN-OPT-06 | FinOps | Pillar 4, Pillar 6 | AI infrastructure model aligned with FinOps maturity |

### Unique Checks — Pillar 6

| Check ID | Source | Pillar | Description |
|----------|--------|--------|-------------|
| BP01_04 | WA AgentCore | Pillar 6 | Is the agent's tone and personality documented? |
| AGENT_PATTERN_SELECTION | WA Agentic | Pillar 2, Pillar 6 | Is the agentic pattern appropriate (LLM-augmented / autonomous ReACT / hybrid)? |
| GOVERN-2.3 | NIST | Pillar 1, Pillar 6 | Executive leadership takes responsibility for AI risk decisions |
| LC_SCOPING | WA Lifecycle | Pillar 1, Pillar 6 | Has the business problem been defined with success metrics, risk profile, and cost considerations? |
| MANAGE-1.1 | NIST | Pillar 1, Pillar 6 | Go/no-go determination made before deployment |
| MEASURE-3.1 | NIST | Pillar 1, Pillar 6 | Risk tracking mechanisms for emergent AI risks |
| FIN-MGT-04 | FinOps | Pillar 4, Pillar 6 | Incremental funding with frequent fail-fast reviews |
