# Trusted self-hosted Mac runner

This runner exists only for MYR-211 heavy verification. Ordinary public pull-request verification remains on GitHub-hosted runners.

## Security model

A self-hosted runner is a persistent execution environment, not a disposable GitHub-hosted VM. Treat any job it accepts as code execution on the Mac.

Required invariants:

- Never add `pull_request`, `pull_request_target`, `push`, `issue_comment`, `schedule`, `repository_dispatch`, or another automatic/external trigger to the heavy workflow.
- Never execute fork-provided code on this runner.
- Keep the dedicated `myram-trusted-heavy` runner label. Do not broaden the workflow to generic `self-hosted` runners.
- Keep workflow permissions at `contents: read` and do not add repository, environment, deployment, signing, App Store, SSH, cloud, or other secrets.
- Keep `persist-credentials: false` on every checkout.
- Keep the repository-owner dispatch gate unless a separate security review explicitly approves a different authorization model.
- Treat any change to triggers, permissions, secrets, runner scope, or deployment capabilities as security-sensitive work requiring separate review.

## Host account

Prefer a dedicated standard macOS user such as `myram-runner` rather than a personal or administrator account.

The runner account should not contain:

- personal iCloud data;
- Apple signing certificates or App Store credentials;
- personal SSH keys or GitHub PATs;
- cloud credentials, password-manager sessions, or unrelated development secrets;
- mounted personal/network shares that jobs do not require.

Install only what verification needs. For the current workflow that includes Xcode 26.6 at `/Applications/Xcode_26.6.app`, an available iOS Simulator runtime, Git, and the GitHub Actions runner.

## Register the runner

1. In the MyRAM-iOS repository, open **Settings → Actions → Runners → New self-hosted runner**.
2. Select **macOS** and **ARM64**.
3. Sign in to the dedicated runner macOS account.
4. Run the download and extraction commands GitHub displays. Use the current commands from GitHub rather than copying a runner version from this document.
5. Configure the runner using the one-time registration token GitHub displays:

```sh
./config.sh \
  --url https://github.com/benjamindrong/MyRAM-iOS \
  --token <GITHUB-GENERATED-TOKEN> \
  --name myram-mac-mini \
  --labels myram-trusted-heavy
```

The registration token is temporary. Never commit it, paste it into Jira/PR comments, or save it in scripts.

6. Install and start the macOS runner service:

```sh
./svc.sh install
./svc.sh start
./svc.sh status
```

7. In **Settings → Actions → Runners**, confirm `myram-mac-mini` is online and has all required labels: `self-hosted`, `macOS`, `ARM64`, and `myram-trusted-heavy`.

Do not run heavy verification until all four labels are present.

## Run heavy verification

Use **Actions → Heavy Verification (Trusted Self-Hosted Mac) → Run workflow**.

Select the trusted same-repository branch/ref to verify and exactly one profile:

- `ios`: complete `MyRAMTests` suite;
- `mac`: complete `MyRAMMacTests` suite;
- `ui`: complete `MyRAMUITests` suite.

The workflow refuses execution unless the dispatcher is the repository owner. It does not accept a repository or fork URL as input.

## Temporarily disable the runner

Stop the service when the machine should not accept work:

```sh
./svc.sh stop
./svc.sh status
```

Confirm the repository runner page shows it offline before treating it as disabled.

To resume:

```sh
./svc.sh start
./svc.sh status
```

## Updates

GitHub Actions runners normally manage runner application updates, but if GitHub requires manual intervention, stop the service first and follow the current instructions on the repository runner page or GitHub's official runner documentation.

Keep the Xcode version compatible with `DEVELOPER_DIR` in the workflow. Changing Xcode is a workflow change and should be reviewed separately rather than silently changing the machine underneath recorded evidence.

## Decommission safely

For permanent removal:

```sh
./svc.sh stop
./svc.sh uninstall
```

Then open **Settings → Actions → Runners**, choose `myram-mac-mini`, and use GitHub's **Remove** flow. Run the exact removal command/token GitHub generates. After GitHub confirms the runner is removed, delete the local runner directory.

If the machine is lost or inaccessible, force-remove the runner from GitHub immediately.

## Suspected compromise

If untrusted code may have run on the runner:

1. Stop the runner service immediately.
2. Remove the runner registration from GitHub.
3. Do not reuse the runner work directory or trust its cached state.
4. Wipe/recreate the dedicated runner account or machine execution surface before re-registering.
5. Rotate any credential that was ever accessible to that account, even though the intended configuration contains none.
6. Re-register with a new one-time token and re-verify the safety invariants above.
