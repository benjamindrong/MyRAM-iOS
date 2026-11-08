# MYR-233 Verification fixture identity setup

The persistent sync identity is owned by `MyRAMSyncDeviceIdentityStore`. iOS
`MyRAMDeviceIdentity` and `MacSyncDeviceIdentityProvider` both resolve it before
constructing peer IDs or local batch origins. Mac incoming recovery matches
persisted batch origins to authenticated peer IDs before rebinding ACK ownership.

External preference-file replacement does not establish the runtime defaults
owner's value reliably. Do not use preference-file injection for this fixture.

After verifying the approved recovered fixture archive and all its manifest file
hashes, pass its extracted `fixture-manifest.json` to the existing creator:

```sh
bash Scripts/create-myram-verification-worktree.sh \
  --path /absolute/disposable/Verification \
  --fixture-manifest /absolute/staging/fixture/fixture-manifest.json
```

The creator writes each platform's captured device ID only into its generated
Verification app plist and records both IDs and the input manifest SHA-256 in the
generated identity manifest. The source checkout remains unchanged. UUIDs must
be valid and distinct; malformed input fails before transformation.

The shared runtime owner accepts fixture configuration only for the exact iOS or
Mac Verification bundle ID, establishes it with `UserDefaults.set`, and uses the
same configured ID on every subsequent reader and relaunch. Other bundles reject
fixture configuration without mutating defaults. With no fixture configuration,
existing production identity behavior is preserved, including iOS ID spelling.

Build and prove the exact generated app identities before setup. Establish the
empty Verification pair's trust after its fixture identities are configured;
verify persistent identities and stable transport before stopping Verification
writers and transferring fixture data. Preserve those Verification preferences
and pairing through transfer and the no-edit replay. Do not modify an identity
or re-pair after acceptance begins. This setup performs no fixture transfer and
does not itself establish physical acceptance.
