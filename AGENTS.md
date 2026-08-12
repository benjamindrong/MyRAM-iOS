1. Read the current `main` version files from /project-blacksmith-instructions
    * 00-overall-agent-instructions-outline.md
    * 01-coding-skill-outline.md
    * 03-software-review-skill-outline.md
2. Select the primary workflow:
    * Coding: implementing, fixing, refactoring, testing, remediating, or preparing repository changes.
    * PR Review: independently reviewing implemented changes in a pull request.
    * Implementation Review: reviewing an implementation procedure, plan, or remediation proposal before coding.
3. For Coding tasks:
    * Follow the Coding skill as the primary workflow.
    * Apply relevant Software Review readiness and evidence standards before declaring completion.
4. For PR and Implementation Reviews:
    * Follow the Software Review skill as the primary workflow.
    * Apply relevant Coding skill requirements as review criteria.
    * Do not perform implementation steps unless the user also requests remediation or coding.
5. Before substantive work, read:
    * The relevant Jira ticket and acceptance criteria.
    * Repository instructions such as AGENTS.md.
    * Linked implementation procedures and existing review findings.
    * The current repository, branch, or PR state.
6. Report the instruction-repository commit SHA used.
7. Follow the required scope, Git safety, verification, severity, evidence, traceability, and readiness standards from the selected workflow.
8. In MyRAM, call any feature or code named **pinned thought** by the approved term **pinned text**.