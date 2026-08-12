# Trusted self-hosted Mac runner

This runner exists only for MYR-211 heavy verification. Ordinary public pull-request verification remains on GitHub-hosted runners.

## Security model

A self-hosted runner is a persistent execution environment, not a disposable GitHub-hosted VM. Treat any job it accepts as code execution on the Mac.

Required invariants:

- Never add `pull_request`, `pull_request_target`, `push`, `issue_comment`, `schedule`, `repository_dispatch`, or another automatic/external trigger to the heavy workflow.
- Never execute fork-provided code on this runner.
- Register the runner with `--no-default-labels`; it must have only the unique `myram-trusted-heavy` routing label.
- Target only `myram-trusted-heavy` from the workflow. Do not add `self-hosted`, `macOS`, `ARM64`, or another generic runner label.
- Keep workflow permissions at `contents: read` and do not add repository, environment, deployment, signing, App Store, SSH, cloud, or other secrets.
- Keep `persist-credentials: false` on every checkout.
- Keep the repository-owner dispatch gate unless a separate security review explicitly approves a different authorization model.
- Treat any change to triggers, permissions, secrets, runner scope, labels, or deployment capabilities as security-sensitive work requiring separate review.

The unique label is a routing isolation layer, not a substitute for the manual-only trigger and owner gate. All three controls are required.

## Host account

Use a dedicated standard macOS user such as `myram-runner`, not a personal or administrator account.

The runner account should not contain:

- personal iCloud data;
- Apple signing certificates or App Store credentials;
- personal SSH keys or GitHub PATs;
- cloud credentials, password-manager sessions, or unrelated development secrets;
- mounted personal/network shares that jobs do not require.

Install only what verification needs. The current workflow requires an active Xcode 26.6 installation, an available iOS Simulator runtime, Git, and the GitHub Actions runner. `xcodebuild -version` must report `Xcode 26.6` before a heavy job proceeds.

## Register the runner

1. In the MyRAM-iOS repository, open **Settings → Actions → Runners → New self-hosted runner**.
2. Select **macOS** and **ARM64** for the download instructions.
3. Sign in to the dedicated runner macOS account.
4. Run the download and extraction commands GitHub displays. Use the current commands from GitHub rather than copying a runner version from this document.
5. Configure the runner using the one-time registration token GitHub displays:

```sh
./config.sh \
  --url https://github.com/benjamindrong/MyRAM-iOS \
  --token <GITHUB-GENERATED-TOKEN> \
  --name myram-mac-mini \
  --no-default-labels \
  --labels myram-trusted-heavy
```

The registration token is temporary. Never commit it, paste it into Jira/PR comments, or save it in scripts.

6. Install and start the macOS runner service:

```sh
./svc.sh install
./svc.sh start
./svc.sh status
```

7. In **Settings → Actions → Runners**, confirm `myram-mac-mini` is online and has the `myram-trusted-heavy` label. It must not have the default `self-hosted`, `macOS`, or `ARM64` routing labels.

Do not run heavy verification until that label isolation is confirmed.

## Run heavy verification

Use **Actions → Heavy Verification (Trusted Self-Hosted Mac) → Run workflow**.

Select the trusted same-repository branch/ref to verify and exactly one profile:

- `ios`: complete `MyRAMTests` suite;
- `mac`: complete `MyRAMMacTests` suite;
- `ui`: complete `MyRAMUITests` suite.

The workflow refuses execution unless the dispatcher is the repository owner. It does not accept a repository or fork URL as input.

Only dispatch a ref whose code you trust. A manual dispatch is explicit authorization to execute that ref on the Mac.

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

Keep Xcode 26.6 selected for this workflow. Changing the required Xcode version is a workflow change and should be reviewed separately rather than silently changing the machine underneath recorded evidence.

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
