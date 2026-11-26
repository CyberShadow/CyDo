import json
import re
import shlex

start_all()
machine.wait_for_unit("user@1000.service")
machine.wait_for_unit("mock-api.service")
machine.wait_for_open_port(9000)


def alice(command):
    return "su -l alice -c " + shlex.quote(
        "export XDG_RUNTIME_DIR=/run/user/1000; " + command
    )


def ctl(command):
    return alice("systemctl --user " + command)


def value(command):
    return machine.succeed(command).strip()


def properties(unit, *names):
    options = " ".join(f"-p {name}" for name in names)
    return dict(line.split("=", 1) for line in value(ctl(f"show {unit} {options}")).splitlines())


def client(*args):
    return json.loads(value(alice(shlex.join([
        "python3", "/etc/cydo-vm/cydo-client.py", *map(str, args)
    ]))))


def journal(*match):
    entries = value(shlex.join(["journalctl", "--no-pager", "--all", "-o", "json", *match]))
    return [json.loads(line) for line in entries.splitlines()]


def timestamp(entries, fragment):
    return max(int(entry["__MONOTONIC_TIMESTAMP"]) for entry in entries
               if fragment in str(entry.get("MESSAGE")))


def assert_graceful_shutdown(logs, after, tid):
    entries = journal(logs, f"--after-cursor={after}")
    assert any("shutdown() complete" in str(entry.get("MESSAGE")) for entry in entries)
    assert not any(f"onExit: tid={tid} " in str(entry.get("MESSAGE")) for entry in entries)


def service_pid():
    return value(ctl("show cydo.service -p MainPID --value"))


def wait_scope_collected(scope):
    machine.wait_until_succeeds(
        alice(f'test "$(systemctl --user show {scope} -p LoadState --value)" = not-found'),
        timeout=30,
    )


def wait_agent_gone(scope, pid):
    wait_scope_collected(scope)
    machine.fail(f"kill -0 {pid}")


def scope_in_instance_slice(cgroup):
    assert re.fullmatch(re.escape("0::" + slice_group) + r"/run-[^/]+\.scope", cgroup), cgroup
    return cgroup.rsplit("/", 1)[-1]


def session_scope():
    pid = int(value("pgrep -f '^([^ ]*/)?claude .*--input-format stream-json( |$)'"))
    assert value(f"readlink /proc/{pid}/exe").rsplit("/", 1)[-1] == "claude"
    cgroup = value(f"cat /proc/{pid}/cgroup")
    scope = scope_in_instance_slice(cgroup)
    group = cgroup.removeprefix("0::")
    expected = {
        "MemoryMax": "1073741824",
        "MemoryHigh": "infinity",
        "MemorySwapMax": "0",
        "OOMPolicy": "continue",
        "BindsTo": "cydo.service",
        "StopPropagatedFrom": "cydo.service",
        "Slice": slice_name,
    }
    actual = properties(scope, *expected, "Before")
    assert "cydo.service" in actual.pop("Before").split(), actual
    assert actual == expected, actual
    return pid, group, scope


def task_status(tid):
    return value(shlex.join([
        "sqlite3", "/home/alice/.local/share/cydo/cydo.db",
        f"SELECT status FROM tasks WHERE tid = {tid}",
    ]))


machine.succeed(alice("""set -eu
mkdir -p ~/.claude ~/.config/cydo ~/ws/proj
cat > ~/.claude/settings.json <<'JSON'
{"hasCompletedOnboarding":true,"theme":"dark","skipDangerousModePermissionPrompt":true,"autoUpdates":false}
JSON
cat /etc/cydo-vm/config-base.yaml > ~/.config/cydo/config.yaml
cat >> ~/.config/cydo/config.yaml <<'YAML'
  memory: {max: 1G, high: 768M, swap_max: 0}
default_agent: claude
log_level: trace
workspaces:
  local:
    root: /home/alice/ws
    sandbox:
      memory: {high: infinity}
total_agent_memory: {max: 3G, high: 2560M}
YAML
cd ~/ws/proj
git init -q
git -c user.name=Test -c user.email=test@test commit -q --allow-empty -m init
"""))

listen_log = "CyDo server listening on"

with subtest("user service and instance slice"):
    assert value("loginctl show-user alice -p Linger") == "Linger=yes"
    machine.succeed(ctl("start cydo.service"))
    machine.wait_for_open_port(3940)
    machine.succeed(ctl("is-active cydo.service"))
    assert value(f"cat /proc/{service_pid()}/cgroup").endswith("app.slice/cydo.service")
    service_logs = "journalctl --no-pager -o cat _SYSTEMD_USER_UNIT=cydo.service"
    listen_line = f"{listen_log} http://localhost:3940"
    machine.wait_until_succeeds(service_logs + " | grep -Fq " + shlex.quote(listen_line), timeout=30)
    messages = value(service_logs)
    match = re.search(r"Agent memory limits use (cydo-[a-f0-9]{12}\.slice) \(bound to cydo\.service\)", messages)
    assert match, messages
    slice_name = match[1]
    assert properties(slice_name, "MemoryMax", "MemoryHigh", "MemorySwapMax") == {
        "MemoryMax": "3221225472", "MemoryHigh": "2684354560", "MemorySwapMax": "infinity"
    }

with subtest("session and one-shot scopes"):
    literal = "${HOME} $$ vm-ok"
    created = client("create-and-send", "local", "/home/alice/ws/proj", f'reply with "{literal}"')
    tid = created["tid"]
    assert created["assistant_text"] == literal, created
    assert created["title"] == literal, created
    slice_group = properties(slice_name, "ControlGroup")["ControlGroup"]
    assert slice_group.endswith(f"/user@1000.service/cydo.slice/{slice_name}"), slice_group
    pid, group, scope = session_scope()
    pids = sorted(map(int, value(f"cat /sys/fs/cgroup{group}/cgroup.procs").split()))
    executables = [value(f"basename \"$(readlink /proc/{member}/exe)\"") for member in pids]
    assert executables[0] == "bwrap" and "systemd-run" not in executables, executables
    one_shots = created["one_shot_cgroups"]
    assert one_shots.keys() == {"title", "suggestions"}, one_shots
    one_shot_scopes = {scope_in_instance_slice(cgroup) for cgroup in one_shots.values()}
    assert len(one_shot_scopes) == 2 and scope not in one_shot_scopes, one_shots
    for one_shot_scope in sorted(one_shot_scopes):
        wait_scope_collected(one_shot_scope)
    listed = f"find /sys/fs/cgroup{slice_group} -mindepth 1 -maxdepth 1 -name '*.scope' -printf '%f\\n'"
    machine.wait_until_succeeds(f'test "$({listed})" = {scope}', timeout=30)


with subtest("OOM containment and live reload"):
    response = client("send", tid,
        'run command head -c 2G /dev/zero | tail -n 1 >/dev/null; echo "hog-exit=$?"')
    assert response["assistant_text"] == "Done.", response
    assert "hog-exit=137" in json.dumps(response["tool_outputs"]), response
    assert session_scope() == (pid, group, scope)
    machine.succeed(ctl(f"is-active {scope}"))
    events = dict(line.split() for line in value(f"cat /sys/fs/cgroup{group}/memory.events").splitlines())
    assert int(events["oom_kill"]) >= 1, events
    assert client("send", tid, 'reply with "still-alive"')["assistant_text"] == "still-alive"
    assert session_scope() == (pid, group, scope)
    logs = "_SYSTEMD_USER_UNIT=cydo.service"
    before_reload = journal(logs)[-1]["__CURSOR"]
    machine.succeed(alice("sed -i 's/max: 3G/max: 2G/' ~/.config/cydo/config.yaml"))
    machine.wait_until_succeeds(
        alice(f'test "$(systemctl --user show {slice_name} -p MemoryMax --value)" = 2147483648'),
        timeout=30,
    )
    reload_logs = shlex.join([
        "journalctl", "--no-pager", "-o", "cat", logs, f"--after-cursor={before_reload}",
    ])
    machine.wait_until_succeeds(reload_logs + " | grep -q 'Config reloaded successfully'", timeout=30)
    assert "Config reload rejected" not in value(reload_logs)
    assert properties(scope, "MemoryMax")["MemoryMax"] == "1073741824"

with subtest("graceful stop preserves the task"):
    assert session_scope() == (pid, group, scope)
    status = task_status(tid)
    assert status == "alive", status
    logs = f"_PID={service_pid()}"
    before_stop = journal(logs)[-1]["__CURSOR"]
    machine.succeed(ctl("stop cydo.service"))
    # systemctl waits for the requested service job. With Before=cydo.service,
    # the propagated scope stop is ordered after that service stop job.
    wait_agent_gone(scope, pid)
    assert task_status(tid) == status
    assert_graceful_shutdown(logs, before_stop, tid)

with subtest("explicit restart stops the old scope"):
    machine.succeed(ctl("start cydo.service"))
    machine.wait_for_open_port(3940)
    assert client("send", tid, 'reply with "after-restart"')["assistant_text"] == "after-restart"
    pid, _, scope = session_scope()
    old_pid = service_pid()
    logs = f"_PID={old_pid}"
    before_restart = journal(logs)[-1]["__CURSOR"]
    machine.succeed(ctl("restart cydo.service"))
    machine.fail(f"kill -0 {pid}")
    machine.fail(ctl(f"is-active -- {scope}"))
    machine.succeed(ctl("is-active cydo.service"))
    assert service_pid() not in ("0", old_pid)
    wait_scope_collected(scope)
    assert task_status(tid) == status
    assert_graceful_shutdown(logs, before_restart, tid)
    machine.wait_for_open_port(3940)

with subtest("crash stops the bound scope before automatic restart"):
    assert client("send", tid, 'reply with "after-explicit-restart"')["assistant_text"] == "after-explicit-restart"
    pid, _, scope = session_scope()
    old_pid = service_pid()
    machine.succeed(ctl("kill --kill-whom=main --signal=SIGKILL cydo.service"))
    wait_agent_gone(scope, pid)
    machine.wait_for_open_port(3940)
    machine.succeed(ctl("is-active cydo.service"))
    assert service_pid() not in ("0", old_pid)
    # Both entries are from the same user systemd manager.
    scope_stop = timestamp(journal(f"USER_UNIT={scope}"), "Stopped ")
    service_start = timestamp(journal("USER_UNIT=cydo.service"), "Started ")
    assert scope_stop < service_start

environment = json.loads(value("cat /etc/cydo-vm/environment.json"))
with subtest("limits require a user service"):
    machine.succeed(ctl("stop cydo.service"))
    for prefix, expected in [
        ([], "systemd user service"),
        (["systemd-run", "--user", "--scope"], "scope, not a service"),
    ]:
        status, output = machine.execute(alice(shlex.join([
            "timeout", "15", *prefix, "env", *environment, "cydo",
        ]) + " 2>&1"))
        assert status not in (0, 124), output
        assert expected in output and "systemd-run" in output, output
        assert listen_log not in output, output
        assert value("ss -H -ltn 'sport = :3940'") == ""

with subtest("transient user service accepts limits"):
    dev_env = [arg for arg in environment if not arg.startswith("CYDO_LISTEN_PORT=")]
    machine.succeed(alice(shlex.join([
        "systemd-run", "--user", "--unit=cydo-dev", "--setenv=CYDO_LISTEN_PORT=3941",
        "--setenv=PATH=/run/current-system/sw/bin",
        *["--setenv=" + arg for arg in dev_env], "cydo",
    ])))
    machine.wait_for_open_port(3941, timeout=30)
    machine.succeed(ctl("is-active cydo-dev.service"))
    machine.succeed(ctl("stop cydo-dev.service"))
