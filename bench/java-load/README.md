# Java load time per route on Docker Sandboxes (sbx), x86_64

Evidence for https://github.com/docker/sandbox-kit-spec/issues/172#issuecomment-6528410378

Host: Windows 11, x86_64. Local sandboxes. 30 Oct 2026. Two rounds per case.

| File | What it is |
|---|---|
| `m2.sh` | The script behind the posted numbers. It creates each sandbox, times `create`, the first `java -version`, a Temurin download and an apt install, then removes the sandbox. |
| `java-load-0501.log` | **Its output on sbx v0.50.1.** These are the numbers in the comment. |
| `measure.sh`, `java-load.log` | The first version, run on sbx v0.50.0. Here the download and apt routes failed because the default egress policy blocked them and apt was locked by the startup update. |
| `java-load-try1.log` | The very first v0.50.0 run, with two harness bugs: a login shell printed a banner that broke the `java -version` parse, and apt never ran. It is kept only as a record. The `sbx/claude:latest` failure in it is real. |

To reproduce: clone docker/sbx-kits-contrib with the `jdk/` mixin from PR #439, then run `bash m2.sh` with `K` set to that clone. `m2.sh` allows the download hosts (`api.adoptium.net`, `github.com`, `objects.githubusercontent.com`, `release-assets.githubusercontent.com`) on its own throwaway sandbox only, with `sbx policy allow network --sandbox`.
