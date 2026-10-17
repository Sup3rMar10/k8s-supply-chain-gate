# k8s-supply-chain-gate

![ci](https://github.com/Sup3rMar10/k8s-supply-chain-gate/actions/workflows/ci.yml/badge.svg)

A pipeline that scans, builds, **signs** (keyless, with Sigstore) and attaches an **SBOM** to a container image, followed by a test that a Kubernetes admission policy actually **admits the signed image and rejects an unsigned one**.

> **What is verified.** On 2026-10-17, after the fixes listed below, the whole pipeline ran green on GitHub Actions: the negative control, build/scan/sign/verify, and the admission job on a kind cluster with Kyverno, **9 of 9 checks**. It uses the public Sigstore services (Fulcio and Rekor), nothing private.

## The flow

1. **Negative control:** scan an old image (`alpine:3.12`); the job fails if the scanner does *not* fail. A gate that never fails proves nothing.
2. **Build and gate:** build the image, run Trivy, fail on fixable `CRITICAL` vulnerabilities, before anything is pushed.
3. **Publish (main and manual runs only; pull requests stop after the scan):** push the image, plus a second image that is deliberately left unsigned.
4. **Sign and attest:** `cosign sign` the image **by digest** using the job's OIDC token (no keys to manage), generate an SPDX SBOM with Syft, attach it as a signed attestation, then `cosign verify` as a consumer would.
5. **Admission test:** install Kyverno on kind, apply `policy/verify-images.yaml.tmpl`, and check:

| Case | Expected | Result |
|---|---|---|
| signed image, by digest | admitted, pod Ready, Kyverno annotation records `pass` | pass |
| unsigned image from the same repository | rejected, message is about image verification | pass |
| signed image referenced by tag | admitted and pinned to the verified digest | pass |
| unrelated public image | untouched (the policy only covers this repository's images) | pass |

The policy requires **both** a signature and an SPDX SBOM attestation, signed by this repository's `ci.yml` on `main` via GitHub's OIDC issuer.

## Things that went wrong, and what they taught me

- **The vulnerability gate failed my first real build.** It found a fixable `CRITICAL` OpenSSL CVE in the nginx base image. The fix is `apk upgrade` in the Dockerfile, not weakening the gate. Consequence worth knowing: this pipeline can go red on a new CVE with no code change.
- **`cosign-installer` has no floating `v4` tag**, so it is pinned to `v4.1.2`.
- **Signed images were rejected as "no signatures found"** with the default cosign (3.x). Pinning cosign to **2.6.5** made them verify. My explanation is that cosign 3 stores signatures in the newer Sigstore bundle format and Kyverno 1.14 only looks for the classic `<digest>.sig` tag; I confirmed that pinning fixes it, but I did not inspect the registry layout to prove the mechanism.
- **Policy apply failed once with "connection refused"**: `helm install --wait` returns when pods are Ready, slightly before the Kyverno webhook serves. The test now retries.
- My assertion on the tag case was too strict: Kyverno rewrites to `image:tag@sha256:...`, it does not replace the tag.

## Honest limits

- **Kyverno is pinned to chart 3.4.6 (Kyverno 1.14.5).** The latest chart is 3.9.x (Kyverno 1.19); I did not test whether `ClusterPolicy` `verifyImages` still works there, and newer Kyverno versions push toward a different policy type.
- **Only "no signature" is tested as a rejection.** An image signed by a *different* identity (another repository's workflow) should also be rejected by the `subject` match, but I did not test it.
- `failurePolicy: Fail` means that if Kyverno is down, pod creation in scope is blocked. Production needs replicas, a PodDisruptionBudget and an exception process; here it is one replica.
- Depends on public Sigstore infrastructure being reachable from both the pipeline and the cluster.
- The registry is private, so the test creates pull secrets from `GITHUB_TOKEN`; real clusters would use a proper pull-secret setup.
- Keyless signing proves *which workflow built it*, not that the code is safe. The SBOM is attached and its presence is required, but its contents are not evaluated against any policy.
- Trivy's database is downloaded at run time, so results change over time; the Trivy version shown in logs was 0.70.0 and the action said 0.76.0 was available.
- Scanning covers the image's packages only, not the application's dependencies (there are none here).
