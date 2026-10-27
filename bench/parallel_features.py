"""Benchmark: real features on a real repo, built by headless Claude Code workers in Docker Sandboxes.

  parallel  one clone-mode sandbox per feature, all dispatched at once
  serial    one sandbox, the same features one after another (the baseline)
  onebox    one sandbox, all agents at once, each in its own git worktree (shares one VM and ~/.m2)

Truth comes from git refs and `claude -p --output-format json` (cost, turns, duration), never from
the agent's prose. The host merges every worker branch into `integration-<mode>` and runs the full
build there. Usage:
  python parallel_features.py <repo> --tasks tasks.json --mode parallel|serial|onebox [--model sonnet] [--keep]
  python parallel_features.py --selfcheck
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

PROMPT = """You are a worker on a team building features in parallel on this Java 25 / Maven repo.
Read AGENTS.md first and follow its conventions. Your one feature:

{task}

Rules:
- Change only what this feature needs. Do not refactor unrelated code. Do not edit docs/spec.md.
- Test first: add or extend JUnit tests for the behaviour, then implement.
- Verify with: ./mvnw -q -B test -Dtest='{tests}' -Dsurefire.failIfNoSpecifiedTests=false
- Commit on the current branch with message: feat({name}): <summary>. Do not push.
Finish with one line: DONE <commit hash> <tests passed|failed>."""


def run(cmd: list[str], timeout: int = 3600, cwd: str | None = None, env: dict | None = None) -> tuple[int, str]:
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=cwd, env=env,
                       encoding="utf-8", errors="replace")
    return p.returncode, (p.stdout + p.stderr).strip()


CLASSIC_TLS = ("openssl_conf = openssl_init\n[openssl_init]\nssl_conf = ssl_sect\n[ssl_sect]\n"
               "system_default = tls_sect\n[tls_sect]\nGroups = X25519:secp256r1:secp384r1\n")
FIELDS = ("is_error", "num_turns", "duration_ms", "total_cost_usd", "result")


def parse_claude_json(out: str) -> dict:
    """The result object is the last JSON line with type=result; key order varies by version."""
    for line in reversed(out.splitlines()):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(d, dict) and d.get("type") == "result":
            return {k: d.get(k) for k in FIELDS}
    return {"parse_error": out[-300:]}


SBX = ["sbx"]  # ["sbx", "--cloud"] in cloud mode
CLOUD_REPO = "/home/agent/workspace/repo"  # cloud has no host workspace: workers clone from GitHub
CLOUD_ALLOW = ["api.anthropic.com", "github.com", "repo.maven.apache.org", "repo1.maven.org"]


def collect(repo: str, box: str, branch: str = "main", key: str | None = None) -> str | None:
    """Secure a worker's commits on the host right after its agent exits.

    Local: fetch the clone-mode remote while the sandbox still serves it (idle sandboxes stop).
    Cloud: the worker pushes a scratch branch to origin; the host fetches it, then deletes it."""
    for _ in range(3):
        if SBX[-1] == "--cloud":
            scratch = f"bench/{box}"
            code, _ = run(SBX + ["exec", box, "git", "-C", CLOUD_REPO, "push", "-q", "-f", "origin", f"HEAD:refs/heads/{scratch}"])
            if code == 0:
                code, _ = run(["git", "fetch", "-q", "origin", f"+{scratch}:refs/bench/{box}"], cwd=repo)
                run(["git", "push", "-q", "origin", "--delete", scratch], cwd=repo)
        else:
            code, _ = run(["git", "fetch", "-q", f"sandbox-{box}", f"+{branch}:refs/bench/{key or box}"], cwd=repo)
        if code == 0:
            return run(["git", "rev-parse", f"refs/bench/{key or box}"], cwd=repo)[1]
        time.sleep(5)
    return None


def dispatch(repo: str, sandbox: str, repo_in_vm: str, name: str, task: dict, model: str,
             classic_tls: bool, worktree: bool = False) -> dict:
    prompt = PROMPT.format(task=task["prompt"], tests=task["tests"], name=name)
    env = ""
    if classic_tls:  # shortcut: per-exec env, a kit mixin is the durable form
        run(SBX + ["exec", sandbox, "sh", "-c", 'printf "%s" "$0" > /tmp/classic-tls.cnf', CLASSIC_TLS])
        env = "export OPENSSL_CONF=/tmp/classic-tls.cnf; "
    workdir, branch, key = repo_in_vm, "main", sandbox
    if worktree:  # onebox: created up front by main(), one per agent
        workdir, branch, key = f"/tmp/wt-{name}", f"feat-{name}", f"{sandbox}-{name}"
    t = time.time()
    code, out = run(SBX + ["exec", sandbox, "sh", "-c",
                     f"{env}cd '{workdir}' && claude -p \"$0\" --model {model} --output-format json "
                     "--dangerously-skip-permissions", prompt])
    sha = collect(repo, sandbox, branch, key)
    return {"task": name, "sandbox": sandbox, "ref": f"refs/bench/{key}", "exit": code,
            "seconds": round(time.time() - t), "collected": sha, **parse_claude_json(out)}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("repo", nargs="?")
    ap.add_argument("--tasks")
    ap.add_argument("--mode", choices=["parallel", "serial", "onebox"], default="parallel")
    ap.add_argument("--model", default="sonnet")
    ap.add_argument("--cpus", default="4")
    ap.add_argument("--memory", default="4g")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--java-home", default=r"C:\Program Files\Amazon Corretto\jdk25.0.3_9")
    ap.add_argument("--classic-tls", action="store_true", help="offer only classic TLS groups in the VM")
    ap.add_argument("--pr", action="store_true", help="push each feature and open a draft PR on origin")
    ap.add_argument("--cloud", action="store_true", help="Docker Cloud Sandboxes: workers clone from origin")
    ap.add_argument("--selfcheck", action="store_true")
    a = ap.parse_args()
    sys.stdout.reconfigure(encoding="utf-8")  # logs are redirected; Windows would write cp1252
    if a.selfcheck:
        return selfcheck()

    global SBX
    SBX = ["sbx", "--cloud"] if a.cloud else ["sbx"]
    repo = str(Path(a.repo).resolve())
    origin = run(["git", "remote", "get-url", "origin"], cwd=repo)[1]
    # clone mode keeps the host path; cloud workers clone origin into their own workspace
    repo_in_vm = CLOUD_REPO if a.cloud else Path(repo).as_posix().replace("C:", "/c", 1)
    tasks = json.loads(Path(a.tasks).read_text(encoding="utf-8"))
    tag = time.strftime("%H%M%S")
    boxes = {n: (f"p{tag}-{n}" if a.mode == "parallel" else f"{a.mode[0]}{tag}") for n in tasks}
    t0 = time.time()

    def create(box: str) -> str:
        t = time.time()
        if a.cloud:
            allow = [x for h in CLOUD_ALLOW for x in ("--allow-network", h)]
            code, out = run(SBX + ["create", "--name", box, "--cpus", a.cpus, "--memory", a.memory, "--ttl", "2h",
                                   "--on-timeout", "delete", "--no-progress", *allow, "claude"], timeout=600)
            if code == 0:
                code, out = run(SBX + ["exec", box, "sh", "-c",
                                       f"git clone -q {origin} {CLOUD_REPO} && cd {CLOUD_REPO} && "
                                       "git config user.name sbx-agent && git config user.email sbx-agent@users.noreply.github.com"])
        else:
            code, out = run(SBX + ["create", "--name", box, "--clone", "--cpus", a.cpus,
                                   "--memory", a.memory, "claude", repo], timeout=600)
        return f"{box}: create exit {code} in {round(time.time() - t)}s" + ("" if code == 0 else f" {out[-200:]}")

    print(f"== {'cloud' if a.cloud else 'local'} mode={a.mode} model={a.model} tasks={list(tasks)} sandbox={a.cpus}cpu/{a.memory}")
    unique = list(dict.fromkeys(boxes.values()))
    with ThreadPoolExecutor(len(unique)) as ex:
        for line in ex.map(create, unique):
            print("  ", line)
    if a.mode == "onebox":  # sequential: concurrent `git worktree add` races on the repo's lock files
        for n in tasks:
            code, out = run(SBX + ["exec", boxes[n], "git", "-C", repo_in_vm, "worktree", "add", "-q",
                                   "-b", f"feat-{n}", f"/tmp/wt-{n}", "main"])
            print(f"   worktree {n}: exit {code} {out[-120:]}")
    t_created = time.time()

    go = lambda n: dispatch(repo, boxes[n], repo_in_vm, n, tasks[n], a.model, a.classic_tls,  # noqa: E731
                            worktree=a.mode == "onebox")
    if a.mode in ("parallel", "onebox"):
        with ThreadPoolExecutor(len(tasks)) as ex:
            results = list(ex.map(go, tasks))
    else:
        results = [go(n) for n in tasks]
    t_agents = time.time()
    for r in results:
        print(f"   {r['task']}: exit {r['exit']} {r['seconds']}s turns={r.get('num_turns')} "
              f"cost=${r.get('total_cost_usd')} collected={r['collected']} — "
              f"{str(r.get('result') or r.get('parse_error'))[-120:]}")

    print("== merge collected work into integration branch")
    branch = f"integration-{a.mode}-{tag}"
    run(["git", "checkout", "-q", "-B", branch, "main"], cwd=repo)
    merged = 0
    uncollected = {r["sandbox"] for r in results if not r["collected"]}
    for r in results:
        if not r["collected"]:
            print(f"   {r['task']}: NOT COLLECTED — sandbox {r['sandbox']} kept for recovery")
    for ref in dict.fromkeys(r["ref"] for r in results if r["collected"]):  # serial: one ref for all tasks
        code, out = run(["git", "merge", "--no-edit", "-q", ref], cwd=repo)
        n_commits = run(["git", "rev-list", "--count", f"main..{ref}"], cwd=repo)[1]
        print(f"   merge {ref}: {'ok' if code == 0 else 'CONFLICT/FAIL ' + out[-160:]} ({n_commits} commits)")
        if code == 0:
            merged += 1
        else:
            run(["git", "merge", "--abort"], cwd=repo)
    if a.pr:
        for r in results:
            if not r["collected"]:
                continue
            feature = f"agent/{r['task']}-{tag}"
            code, out = run(["git", "push", "-q", "origin", f"{r['ref']}:refs/heads/{feature}"], cwd=repo)
            if code == 0:
                code, out = run(["gh", "pr", "create", "--draft", "--head", feature, "--base", "main",
                                 "--title", f"[sbx agent experiment] {r['task']}",
                                 "--body", f"Built by a headless Claude Code worker ({a.model}) inside a Docker "
                                           f"Sandbox, mode={a.mode}, run {tag}. Experiment evidence — not for merge "
                                           f"without review.\n\nAgent's own summary: {str(r.get('result'))[-400:]}"],
                                cwd=repo)
            r["pr"] = out.splitlines()[-1] if out else None
            print(f"   PR {r['task']}: {r['pr']}")
    t = time.time()
    # not "bash": on Windows it resolves to WSL's bash, which cannot see the Windows JDK
    code, out = run(["cmd", "/c", str(Path(repo) / "mvnw.cmd"), "-q", "-B", "verify"], cwd=repo, timeout=1800,
                    env={**os.environ, "JAVA_HOME": a.java_home})
    verify = {"exit": code, "seconds": round(time.time() - t), "tail": out[-400:]}
    print(f"== full verify on {branch}: {'PASS' if code == 0 else 'FAIL'} in {verify['seconds']}s")
    if code:
        print(verify["tail"])
    run(["git", "checkout", "-q", "main"], cwd=repo)

    summary = {"mode": a.mode, "model": a.model, "tag": tag, "branch": branch,
               "create_s": round(t_created - t0), "agents_s": round(t_agents - t_created),
               "total_s": round(time.time() - t0), "merged": merged, "boxes": len(unique),
               "cost_usd": round(sum(r.get("total_cost_usd") or 0 for r in results), 2),
               "results": results, "verify": verify}
    out_file = Path(__file__).parent / f"run-{a.mode}-{tag}.json"
    out_file.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(f"== create {summary['create_s']}s, agents {summary['agents_s']}s, total {summary['total_s']}s, "
          f"cost ${summary['cost_usd']} -> {out_file.name}")
    if not a.keep:
        for box in unique:
            if box not in uncollected:  # never remove a sandbox holding uncollected work: rm deletes its remote
                run(SBX + ["rm", "-f", box])


def selfcheck() -> None:
    # key order as Claude Code 2.1 prints it: "type" is not first
    noise = 'warning: x\n{"result":"DONE abc passed","is_error":false,"type":"result","num_turns":7,"duration_ms":1200,"total_cost_usd":0.42}'
    d = parse_claude_json(noise)
    assert d["num_turns"] == 7 and d["total_cost_usd"] == 0.42 and d["result"].startswith("DONE"), d
    assert "parse_error" in parse_claude_json("no json here")
    assert "{tests}" not in PROMPT.format(task="t", tests="ATest", name="n")
    print("selfcheck ok")


if __name__ == "__main__":
    main()
