# opencode rules — casino repo (OTel training)

You are editing the **casino** application in a training Codespace. This repo is
hosted on the in-cluster **Gitea** at `http://localhost:30001/casino/casino`.
Changes reach the running cluster through GitOps:

- edits under `k8s/**` → **Argo CD** auto-syncs them into the `casino` namespace.
- edits under `apps/casino/**` → the `.gitea/workflows/casino-images.yml` CI
  rebuilds the service image, which the next sync rolls out.

## The git loop you must follow

After you apply the requested change, **always** finish with this loop so the
attendee sees it deploy — never leave edits uncommitted:

1. **Branch** off `main`: `git switch -c opencode/<short-slug>`
2. **Commit** with a DCO sign-off:
   `git commit -s -m "<what changed and why>"`
   (the repo's `prepare-commit-msg` hook also adds `Signed-off-by:` automatically)
3. **Push**: `git push -u origin <branch>`
4. **Open a PR** against `main`. The simplest path is the helper:
   `bash ~/otel-training/gitops/opencode/gitea-pr.sh "<PR title>"`
   (or run it from this repo — it stages, commits, pushes and opens the PR for
   you, printing the PR URL). It needs no `tea` CLI.
5. Tell the attendee to **review and merge the PR in the Gitea UI**
   (`http://localhost:30001/casino/casino/pulls`). Merging `main` is what
   triggers the Argo CD sync / image rebuild — do **not** push straight to
   `main`.

## Conventions

- Credentials are already configured (`~/.git-credentials`, token from
  `~/.workshop-gitea.env`) — never print, echo, or commit the token.
- Every commit must carry `Signed-off-by:` (DCO) and, for agent commits,
  `Co-Authored-By: Paperclip <noreply@paperclip.ing>`.
- Keep changes minimal and scoped to what the exercise asks. Do not refactor
  unrelated manifests or services.
- If a push or PR fails because auth is missing, re-run
  `bash ~/otel-training/gitops/opencode/gitea-token.sh` to re-mint the token,
  then retry.
