# Install leaderboard plan

## Status: pending #177

As of 17 September 2026, neither installer PR has merged.

- [#177](https://github.com/omacom/omarchy-iso/pull/177) adds monotonic timing and the proposed duration display. It is implemented, tested and awaiting review. The PR includes screenshots.
- [#178](https://github.com/omacom/omarchy-iso/pull/178) is the draft follow-up for run IDs, class and hardware information, and signing. It needs to incorporate the latest #177 before review.
- The installed-system commands, submission flow, first-network offer and leaderboard service remain planned.

The next step is to settle and merge #177, then update and review #178. The display examples below describe the current proposal, not an approved format.

## Goal

Give Omarchy install times a leaderboard with comparable classes and results for each release. Keep the result locally during installation, then let the user check its position and choose whether to share it with hardware information.

The direction discussed with DHH on 27 August was full integration: store the install log, compare against the top ten in its class after network access becomes available, offer submission for a qualifying result, and include fastfetch data. Both checking the server and submitting results require user approval. Signing during installation was suggested as a possibility.

The implementation proposed on 29 August split this into small changes across the installer, installed Omarchy and a separate leaderboard service. That remains the approach. The detailed artifact, commands and service design below are proposals supporting that direction.

## Installer

Upstream already saves `/var/log/omarchy-install-timing.json` with wall-clock timestamps and per-phase durations. #177 improves that record; #178 adds the information needed for a leaderboard submission. Neither PR contacts a server.

### Timing and display — #177

Record the whole run and each phase with a monotonic clock. `total_elapsed_ns` measures from before the first phase to after the last, including the orchestrator's overhead. It is not the sum of the phases. Keep the existing wall-clock fields for compatibility, and add a schema version and stable phase IDs.

The current finish-screen proposal uses explicit units:

- Below one minute: `Installed Omarchy in 0 min 37.474 s`.
- From one minute: `Installed Omarchy in 1 min 37 s`.
- From one hour: `Installed Omarchy in 1 h 2 min 3 s`.

The display truncates to milliseconds below one minute and whole seconds otherwise. The file keeps nanosecond precision at every duration. Legacy state files remain readable, using whole seconds. `Reboot Now` remains the only finish-screen action.

### Classed, signed result — #178

Create a run ID before the first phase, then add:

- ISO identity: ref, mirror, offline database hash and available build information, plus the installed Omarchy release.
- Install class: full-disk or protected install, encryption, virtualisation and prefetch information.
- Hardware: vendor and model, CPU, memory, target disk and install medium. Exclude usernames, hostnames, serial numbers, MAC addresses and disk UUIDs.

The current draft calls the prefetch field `warm`, but it records whether prefetch was enabled, not how much data was actually cached. The field name and its use in ranking need agreement before the artifact contract is final.

Write the completed timing document to `/var/lib/omarchy/leaderboard/timing.json` and the existing timing log, with identical bytes. Generate an Ed25519 keypair in the live environment and sign the file on disk using OpenSSL. Save `timing.sig` and `install.pub` alongside it; never write the private key to the target. Copy the result into the btrfs `@factory` snapshot so a factory reset preserves it. Probes and signing are best-effort and must not fail an otherwise successful install.

The signature detects changes relative to the supplied public key. It does not prove that an official installer produced the result: someone can create a false document and a new keypair. Server-side checks and review are still needed. Hardware-backed attestation is outside the initial scope.

#178 also adds a short run code, the first eight characters of the run ID, beside the duration. A screenshot can then be matched to a submitted result. The code is not part of #177, and #178 still needs the updated duration format.

The artifact is the contract with the installed-system command and the service. Schema 1 timing from #177 alone is not the full result: readers must also check for the fields and signature files added by #178.

## Installed Omarchy

Add `omarchy leaderboard` in `omacom/omarchy`:

- `status`: inspect the saved result and signature locally.
- `preview`: show the result, class, phase timings and sanitised fastfetch information that would be submitted. `preview --json` produces the submission payload.
- `check`: with the user's approval, fetch the public top-ten results for the release and compare locally.
- `submit`: show the payload, ask for confirmation with the default set to No, and send it to the service.

Submission forwards the existing signed bytes and signature, with additional hardware metadata outside the signed document. It does not need a new signing key or a post-install sign helper. Whether a submission carries a handle, and how that handle is established, remains open.

After the first network connection, offer one quiet notification asking whether to check the result. Contact the service only after approval. If the result qualifies, offer submission; preview and confirmation still precede the upload. Do not repeat the offer or show it when there is no eligible artifact. There is no automatic submission or unapproved background check in this proposal.

Add a menu entry when the command exists. Follow `docs/file-layout.md`: binaries in `omarchy`; the user unit, fastfetch configuration and settings in `omarchy-settings`. Introduce the unit through a migration without starting it during the upgrade.

## Leaderboard service

The proposed implementation is Rails, Hotwire, SQLite and Kamal, following the plugin registry's deployment approach. The repository, name and hosting are still to be agreed.

Start with per-release class boards, a public top-ten endpoint and a result-submission endpoint. The service checks the artifact structure, signature, run ID, release and class information. Maintain an allow-list of published ISO identities and reject duplicate run IDs. Check install-time hardware against the submitted fastfetch data and flag implausible timings. These checks do not establish trusted provenance.

The original proposal also included sector bests, Geekbench-style machine pages and human review before a result becomes the top record in its class. The initial views and review process need agreement with whoever operates the service. Fixed throughput thresholds, review tiers and submission limits should be defined there, rather than treated as settled installer requirements. A public key generated for each install is not a stable identity for rate limiting.

## Delivery order

1. Review and merge #177: timing and duration display.
2. Bring #178 up to date, settle the artifact fields, and review the run ID, class, hardware and signing changes. Check compatibility with whichever installer changes land from #113, #145 or the bash/systemd work in #132.
3. Add offline `status` and `preview`, using the saved artifact. These can be developed before the service is available.
4. Build the service and complete a manual `check`/`submit` flow against it, with explicit approval and payload preview.
5. Add the menu entry and first-network offer once the complete flow works.

The first scored release needs the agreed full artifact and an ISO identity accepted by the service; schema 1 timing alone is insufficient. Earlier installs can still be shared as screenshots.

The proposed Quattro RS scope is the installer work in #177 and #178. Full integration remains the goal, delivered through subsequent PRs.

## Decisions still open

1. Name and hostname. Timing Tower and `tower.omarchy.org` were placeholders.
2. Service repository, hosting and ownership. The original offer was to build it in the contributor's account and transfer it to `omacom` if wanted.
3. Handles: free text, sign-in, or no handles for the first release. This was left open in the original proposal.
4. Final class definitions, including prefetch and whether RAM needs a separate ranking category.
5. Service submission limits, acceptance checks, review process and initial board views.
