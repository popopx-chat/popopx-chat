# POPOPX node packages — how they are built and published

Ruling 1 asked for two things: fix the publishing identity of the Node packages, and write down the
method for building and publishing them. This file is the method. It also records why the fix is a
repository setting rather than a source edit — which is the shape upstream's own release tooling
already has.

## The four packages

| directory | npm name as committed | what it is |
|---|---|---|
| `packages/popopx-chat-client/types/typescript` | `@simplex-chat/types` | generated TypeScript/Python API types |
| `packages/popopx-chat-nodejs` | `simplex-chat` | the Node add-on (`popopx-chat-nodejs-<platform>.node`) + JS wrapper |
| `packages/popopx-chat-mcp` | `@simplex-chat/mcp` | the MCP server |
| `packages/popopx-chat-webrtc` | `@simplex-chat/webrtc` | the WebRTC transport |
| `packages/popopx-chat-client/typescript` | `@simplex-chat/webrtc-client` | the browser client (not in the release script) |

## The identity is applied at publish time, not in the manifests

`scripts/ci/packages_release.py` has a `test-names` command whose docstring is "rename the packages
to NPM_SCOPE and PYPI_PROJECT (test repositories)". `.github/workflows/build.yml:1807` runs it on the
publish job, before `npm publish`:

```
python3 scripts/ci/packages_release.py test-names
```

With `NPM_SCOPE=@popopx-chat` it rewrites, in the working copy only:

- every `name` to `NPM_SCOPE/<basename>` (`registry_name`, `packages_release.py:165`) — so
  `simplex-chat` → `@popopx-chat/simplex-chat`, `@simplex-chat/types` → `@popopx-chat/types`;
- every `repository.url` to `git+https://github.com/<GITHUB_REPOSITORY>.git`, which npm provenance
  requires to be the repository of the publishing workflow;
- the cross-package dependencies to **`npm:` aliases**
  (`packages_release.py:902,913`): `simplex-chat`'s dependency on the types package becomes
  `npm:@popopx-chat/types@<pin>`, and the MCP's two pins likewise.

That alias step is why the committed manifests keep the upstream spellings. `MCP_PINNED`
(`packages_release.py:47`) and `unreleased_pins()` (`:588`) read the *committed* names to decide which
versions are already published; `check-pins` compares them against the published releases. Editing the
manifests by hand would move one side of that pair and leave the alias generation with nothing to
alias — the release tooling would then compute "unpublished" for packages that are published, and
`npm install` would try to fetch artifacts that exist in no registry.

So the fix for the publishing identity is to set the values below. Nothing in this repository has to
change.

## What has to exist before a publish works

1. **The npm scope `@popopx-chat`.** Either an npm organization of that name with a publishing token,
   or a scoped-user namespace. The two scoped packages declare `publishConfig.access: public`; the
   unscoped `simplex-chat` and the Python distribution declare no `publishConfig` at all.
2. **The PyPI project `popopx-chat`** (or whatever `PYPI_PROJECT` is set to). The Python package is
   `packages/popopx-chat-python` and its committed distribution name is
   `name = "simplex-chat"` (`pyproject.toml:6`), which `PYPI_PROJECT` overrides at release time.
3. **A `-libs` repository next to this one.** `build.yml` uses `LIBS_REPOSITORY: ${{ github.repository
   }}-libs`, so for `popopx-chat/popopx-chat` it resolves to **`popopx-chat/popopx-chat-libs`** with no
   configuration. That repository holds the prebuilt library archives
   (`popopx-chat-libs-<os>-<arch>.zip`, six of them, listed at `packages_release.py:104`) and the
   `releases.toml` that `record` writes. The asset names are still upstream's; they are filenames of
   releases this fork has not made, so they move with the first real release, not before it.
4. **Two repository variables** (Settings → Secrets and variables → Actions → Variables), consumed by
   `packages.yml:21` and `build.yml:255`:

   | variable | value for this fork |
   |---|---|
   | `NPM_SCOPE` | `@popopx-chat` |
   | `PYPI_PROJECT` | `popopx-chat` |
   | `PYPI_URL` | leave unset for pypi.org; set only to point at an index you control |

   Neither can be set from a working copy — they are GitHub repository settings, and `vars.*` is only
   readable inside a workflow run.

## The commands, in the order a release uses them

```
python3 scripts/ci/packages_release.py core-release    # set core + types versions for a library release
python3 scripts/ci/packages_release.py claim-core      # claim the libs release for a commit
python3 scripts/ci/packages_release.py release-status  # published / draft / absent for a libs release
python3 scripts/ci/packages_release.py latest-libs     # newest published library release
python3 scripts/ci/packages_release.py prepare         # update pins and versions of the packages
python3 scripts/ci/packages_release.py publish-plan    # versions not published yet
python3 scripts/ci/packages_release.py test-names      # apply NPM_SCOPE / PYPI_PROJECT (publish job only)
python3 scripts/ci/packages_release.py publish-release # publish a draft release that has every asset
python3 scripts/ci/packages_release.py record          # write releases.toml in the -libs repository
python3 scripts/ci/packages_release.py check-pins      # package pins vs published releases
python3 scripts/ci/packages_release.py download        # fetch a release asset, verify its digest
python3 scripts/ci/packages_release.py download-pinned # fetch a pinned asset, verify its pin
```

`GH_TOKEN` is read for anything that touches the `-libs` repository; without it the API calls are
unauthenticated and drafts are invisible (`libs_api`, `packages_release.py:607`).

Building the add-on itself is a separate path: the library archives come from the `build.yml` matrix,
`popopx-chat-libs-*.zip` is downloaded by `download-pinned`, and the platform add-on
`popopx-chat-nodejs-<platform>.node` (`ADDON_ASSETS`, `packages_release.py:119`) is produced from
`packages/popopx-chat-nodejs` with `npx tsc` after `npm install --ignore-scripts`
(`build.yml:1802,1867`).

## What is not possible from this machine

No publish has been attempted or verified here: there is no `gh` CLI, no GitHub token, no npm token,
and egress from this box is intercepted by a local proxy, so `npm install` cannot resolve even the
upstream names. Everything above is read from `scripts/ci/packages_release.py` and the two workflows
that call it. The first real publish has to run in GitHub Actions, where `vars.NPM_SCOPE` exists.
