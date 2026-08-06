import grp
import os
import pwd
import queue
import re
import subprocess
import threading
import time
from collections import deque
from typing import NamedTuple


# pip install "mcp[cli]>=2,<3" "uvicorn[standard]" "starlette"
import uvicorn
from mcp.server.mcpserver import MCPServer
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import JSONResponse
from mcp.server.transport_security import TransportSecuritySettings

TOKEN = "the_token"
MAX_CHARS = 10_000
END_COMMAND_STR : str = "[[[END]]]"
# MAX_COMMAND_TIMEOUT = 36000  # 上限,免得模型传个天文数字把 session 永久占死
# 不用了，占死了 LLM 自己结束这个 shell 窗口

# 即使 server 以 root 启动,命令也降权到这个用户执行。
RUN_AS_USER = "mcpagent"

mcp = MCPServer("execute_command")



SHELL_PATH = "/bin/bash" if os.path.exists("/bin/bash") else "/bin/sh"
MAX_SHELL_SESSIONS = 16
SHELL_STARTUP_TIMEOUT = 15.0 # venv要久一点
MAX_BUFFER_CHARS = 10 * 1024 * 1024  # 每个 session 的输出缓冲上限,超了从头丢
_IDENTIFIER_RE = re.compile(r"^[A-Za-z0-9_.\-]{1,64}$")


class OutputSlice(NamedTuple):
    """read_output 的结果。start/end/total 都是相对于本条命令输出开头的字符偏移。"""

    text: str
    start: int  # 实际起点,可能因为旧内容被丢弃而大于请求的起点
    end: int
    total: int  # 这条命令到目前为止产出的总字符数(含已丢弃的)
    discarded: int  # 已经从缓冲头部丢掉的字符数


class ShellSession:
    """一个常驻 shell 进程。cwd / 环境变量 / 后台任务在多次调用之间保持。"""

    def __init__(self, identifier: str):
        self.identifier = identifier
        self.output: "queue.Queue[str | None]" = queue.Queue()

        self.lock = threading.Lock()  # 只保护下面这几个字段
        self.busy = False  # 有命令在跑(可能已经转到后台了)
        self.last_command: "str | None" = None  # 最近一次写进 shell 的命令
        # 它的 (完整输出, 退出码);命令还在跑的时候是 None
        self.last_execution_result: "tuple[str, str] | None" = None
        self.buffer: "deque[str]" = deque()  # 当前命令到目前为止收到的输出行
        self.buffer_chars = 0  # buffer 里现存的字符数
        self.discarded = 0  # 因为超上限从头丢掉的字符数
        self.cursor = 0  # 已经交给调用方的字符偏移,避免重复返回

        self.process = subprocess.Popen(
            [SHELL_PATH],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,  # 合流,保证 stdout/stderr 的先后顺序
            cwd="/",
            text=True,
            bufsize=1,  # 行缓冲
            **DROP_PRIVILEGE_KWARGS,
        )

        # 必须一直把 stdout 抽干,管道写满了 shell 会直接卡死
        self._reader = threading.Thread(target=self._pump, daemon=True)
        self._reader.start()

        try:
            self._probe(SHELL_STARTUP_TIMEOUT)
        except Exception:
            self.close()
            raise

    def _pump(self) -> None:
        assert self.process.stdout is not None
        for line in self.process.stdout:
            self.output.put(line)
        self.output.put(None)  # EOF 哨兵

    def write(self, data: str) -> None:
        assert self.process.stdin is not None
        self.process.stdin.write(data)
        self.process.stdin.flush()

    def _probe(self, timeout: float) -> None:
        """跑一条 echo 确认 shell 真的活着且能执行命令。"""
        marker = f"[[[READY-{os.urandom(8).hex()}]]]"
        self.write(f"echo '{marker}'\n")

        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"shell did not respond within {timeout}s")
            try:
                line = self.output.get(timeout=remaining)
            except queue.Empty:
                continue
            if line is None:
                raise RuntimeError(
                    f"shell exited immediately (code {self.process.poll()})"
                )
            if marker in line:
                return

    def try_begin(self) -> bool:
        """占住这个 session。已经有命令在跑(含后台)就返回 False。"""
        with self.lock:
            if self.busy:
                return False
            self.busy = True
            return True

    def peek_last_command(self) -> str:
        with self.lock:
            return self.last_command or "(none)"

    def is_busy(self) -> bool:
        with self.lock:
            return self.busy

    def _append_locked(self, line: str) -> None:
        """往缓冲里塞一行,超上限就从头丢。调用方需持有 self.lock。"""
        self.buffer.append(line)
        self.buffer_chars += len(line)

        while self.buffer_chars > MAX_BUFFER_CHARS and len(self.buffer) > 1:
            dropped = self.buffer.popleft()
            self.buffer_chars -= len(dropped)
            self.discarded += len(dropped)

        # 单独一行就超上限的情况(比如 base64 -w0 出来的一整坨),砍掉它的前半截
        if self.buffer_chars > MAX_BUFFER_CHARS:
            only = self.buffer.pop()
            kept = only[len(only) - MAX_BUFFER_CHARS :]
            self.discarded += len(only) - len(kept)
            self.buffer_chars = len(kept)
            self.buffer.append(kept)

    def take_new_output(self) -> str:
        """取走还没交出去过的那部分输出,并推进 cursor。"""
        with self.lock:
            text = "".join(self.buffer)
            total = self.discarded + len(text)
            start = max(self.cursor, self.discarded)
            self.cursor = total
            return text[start - self.discarded :]

    def read_output(self, start: int, limit: int) -> OutputSlice:
        """按字符偏移读当前命令的输出。

        纯读,可以反复调用,不会消费掉内容;只是把 cursor 往前推到已经交出去的位置。
        缓冲超上限时开头的内容会被丢弃,请求的 start 落在丢弃区里就自动抬到还留着的
        最早位置 —— 所以返回的 start 可能大于传进来的。
        """
        with self.lock:
            text = "".join(self.buffer)
            total = self.discarded + len(text)
            start = max(0, min(start, total))
            start = max(start, self.discarded)  # 丢掉的部分要不回来了
            end = min(start + limit, total)
            self.cursor = max(self.cursor, end)
            offset = start - self.discarded
            return OutputSlice(
                text=text[offset : offset + (end - start)],
                start=start,
                end=end,
                total=total,
                discarded=self.discarded,
            )

    def _collect(self, marker: str, deadline: float) -> str:
        """读到 marker 为止,返回退出码;输出边读边追加到 self.buffer。

        到点还没读到 marker 就抛 TimeoutError —— 注意已读到的部分留在 buffer 里,
        不会丢。
        """
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError
            try:
                line = self.output.get(timeout=remaining)
            except queue.Empty:
                continue
            if line is None:
                raise RuntimeError(f"shell exited (code {self.process.poll()})")
            if marker in line:
                return line.split(marker, 1)[1].strip()
            with self.lock:
                self._append_locked(line)

    def run(
        self, command: str, waittime: float, timeout: float
    ) -> tuple[str, str]:
        """跑一条命令,返回 (status, 退出码)。调用方必须先 try_begin() 成功。

        输出不从这里返回,用 read_output() 按偏移取 —— 两种 status 下都已经在 buffer 里。

        status = "done"        waittime 内跑完了,buffer 里是这条命令的全部输出
        status = "background"  还没跑完,buffer 里是目前已经收到的那部分;命令继续在
                               后台跑,由后台线程接着往 buffer 里追加,最多等到
                               timeout,到点就把整个 session 杀掉。

        shell 中途死掉会抛异常 —— 此时残留输出会污染后续命令,调用方必须丢弃 session。
        """
        with self.lock:
            self.last_command = command
            self.last_execution_result = None  # 新命令开跑,上一条的结果作废
            self.buffer = deque()
            self.buffer_chars = 0
            self.discarded = 0
            self.cursor = 0

        # 每条命令一个随机 marker,命令自己的输出撞上的概率可以忽略
        marker = f"{END_COMMAND_STR}{os.urandom(8).hex()}"
        # 开头的 \n 保证 marker 独占一行(上条命令可能没以换行结尾)
        self.write(f"{command}\nprintf '\\n%s %s\\n' '{marker}' \"$?\"\n")

        started = time.monotonic()

        try:
            exit_code = self._collect(marker, started + waittime)
        except TimeoutError:
            # 已经写进 shell 的命令收不回来了,只能让它继续跑,交给后台线程收尾。
            # 已收到的部分留在 self.buffer 里,调用方自己去读。
            threading.Thread(
                target=self._finish_in_background,
                args=(marker, started + timeout),
                daemon=True,
            ).start()
            return "background", ""

        with self.lock:
            self.last_execution_result = ("".join(self.buffer), exit_code)
            self.busy = False
        return "done", exit_code

    def _finish_in_background(self, marker: str, deadline: float) -> None:
        try:
            exit_code = self._collect(marker, deadline)
        except TimeoutError:
            # 硬超时。没有 PTY 也没开 job control,没法只杀那条命令,
            # 只能连 shell 一起杀 —— 反正它已经不可用了。
            _discard_session(self.identifier, self)
            return
        except Exception:
            _discard_session(self.identifier, self)
            return

        with self.lock:
            self.last_execution_result = ("".join(self.buffer), exit_code)
            self.busy = False

    def is_alive(self) -> bool:
        return self.process.poll() is None

    def close(self) -> None:
        if self.process.stdin is not None and not self.process.stdin.closed:
            try:
                self.process.stdin.close()
            except OSError:
                pass
        if self.is_alive():
            self.process.kill()
        self.process.wait(timeout=5)


_sessions_lock = threading.Lock()
list_of_alive_shells : dict[str, (str, ShellSession)] = {} # id, notes, session
list_of_temp_shells : list[str] = [] # 运行完指令就删掉的窗口


def _reap_dead_sessions() -> None:
    """清掉已经退出的 shell(比如模型在里面打了 exit)。调用方需持有 _sessions_lock。"""
    for identifier, (_notes, session) in list(list_of_alive_shells.items()):
        if not session.is_alive():
            del list_of_alive_shells[identifier]

    for temp_id in list(list_of_temp_shells):
        if temp_id not in list_of_alive_shells:
            list_of_temp_shells.remove(temp_id)


def _discard_notice(sl: OutputSlice) -> str:
    """缓冲溢出丢掉了开头时,在返回内容前面说明一下。没丢就返回空串。"""
    if sl.discarded <= 0 or sl.start > sl.discarded:
        return ""
    return (
        f"[the first {sl.discarded} characters of this command's output were "
        f"discarded: only the most recent {MAX_BUFFER_CHARS} characters are kept. "
        f"The text below starts at character {sl.start}.]\n"
    )


def _truncation_notice(sl: OutputSlice) -> str:
    """输出被 MAX_CHARS 截断时,告诉调用方从哪儿接着读。没截断就返回空串。"""
    if sl.end >= sl.total:
        return ""
    return (
        f"\n[string truncated (length > {MAX_CHARS} chars): "
        f"starting_char={sl.start}, ending_char={sl.end}, total={sl.total}. "
        f"Call get_output with starting_char={sl.end} to read the rest.]"
    )


def _discard_session(identifier: str, session: ShellSession) -> None:
    """把 session 从表里摘掉并杀进程。close() 会 wait,所以不在锁里做。"""
    with _sessions_lock:
        list_of_alive_shells.pop(identifier, None)
        if identifier in list_of_temp_shells:
            list_of_temp_shells.remove(identifier)
    try:
        session.close()
    except Exception:
        pass


def _get_live_shell_sesssions_internal(
    use_lock: bool = True,
) -> dict[str, tuple[str, ShellSession]]:
    """{identifier: (notes, session)} 的快照。use_lock=False 表示调用方已经持有锁了。"""
    if use_lock:
        with _sessions_lock:
            _reap_dead_sessions()
            return dict(list_of_alive_shells)
    else:
        _reap_dead_sessions()
        return dict(list_of_alive_shells)



@mcp.tool()
def get_live_shell_sesssions() -> list[tuple[str, str]]:
    """
    Get every live shell session, so you can reuse an existing one instead of creating another.

    :return: A list of (identifier, notes) pairs, one per live session. If there are no live sessions, returns an empty list.
    """
    snapshot = _get_live_shell_sesssions_internal(use_lock=True)
    return [(identifier, notes) for identifier, (notes, _s) in snapshot.items()]


@mcp.tool()
def get_shell_session_notes(identifier: str) -> str:
    """
    Get the notes of a live shell session by its identifier.

    :param identifier: The identifier of the shell session to read the notes of.

    :return: The notes of the session. If the session does not exist, returns an empty string.
    """
    with _sessions_lock:
        _alive_shells = _get_live_shell_sesssions_internal(use_lock=False)
        if identifier in _alive_shells:
            return _alive_shells[identifier][0]
        else:
            return ""


@mcp.tool()
def update_shell_session_notes(identifier: str, notes: str, mode: str) -> str:
    """
    Update the notes of a live shell session by its identifier.

    :param identifier: The identifier of the shell session to update.
    :param notes: The text to append to, or to replace, the current notes with.
    :param mode: Either 'append' to add the text to the end of the existing notes, or 'overwrite' to replace them entirely.

    :return: If succeed, returns string "Succeed". If the session does not exist or the mode is invalid, returns the reason.
    """
    supported_modes = ["append", "overwrite"]
    if mode not in supported_modes:
        return f"Invalid mode. Use {', '.join(supported_modes)}."

    
    with _sessions_lock:
        _alive_shells = _get_live_shell_sesssions_internal(use_lock=False)
        if identifier not in _alive_shells:
            return "Shell session with this identifier does not exist."

        match mode:
            case "append":
                list_of_alive_shells[identifier] = (
                    _alive_shells[identifier][0] + notes,
                    _alive_shells[identifier][1],
                )
            case "overwrite":
                list_of_alive_shells[identifier] = (
                    notes,
                    _alive_shells[identifier][1],
                )
            case _:
                return f"Unknown mode while passed the mode list check. This should never happen."

    return "Succeed"


@mcp.tool()
def create_shell_session(identifier: str, notes: str, keep_session: bool, sudo: bool) -> str:
    """
    Create a new shell session with a string identifier and notes.

    A session is a long lived shell process. Its working directory, environment variables and background jobs persist across commands, so run related commands in one session instead of creating a new one each time.

    :param identifier: A unique identifier for the shell session. It must be 1-64 characters long and can only contain letters, numbers, underscores, hyphens, and periods.
    :param notes: Notes for the shell session, describing what it is being used for. It can be any string, including an empty one.
    :param keep_session: If true, the shell session will be kept alive after the first command execution. If false, the shell session will be closed after the first command execution. Use false when a single command is all you need.
    :param sudo: If true, the shell session will be created with sudo privileges. If false, the shell session will be created with normal permissions. Sudo sessions are not implemented yet, so passing true currently fails. Keep in mind to use this parameter with caution.

    :return: If succeed, returns string "Succeed". If creation failed, returns the reason.
    """

    if sudo:
        return "sudo sessions are not implemented yet; call again with sudo=false."

    if not _IDENTIFIER_RE.match(identifier):
        return "Invalid identifier: 1-64 characters from [A-Za-z0-9_.-] only."


    if(len(identifier) > 256):
        return "Identifier is too long: length must be <= 256 characters."


    with _sessions_lock:
        _ids = _get_live_shell_sesssions_internal(False)

        if identifier in _ids:
            return "Shell with this identifier already exists and it's still alive."

        if len(list_of_alive_shells) >= MAX_SHELL_SESSIONS:
            return (
                f"Too many live sessions (limit {MAX_SHELL_SESSIONS}). "
                "Close an existing one first."
            )

        try:
            list_of_alive_shells[identifier] = (notes, ShellSession(identifier))

            if not keep_session:
                list_of_temp_shells.append(identifier)
            
        except Exception as e:
            return f"Failed to start shell: {e}"

    return "Succeed"


@mcp.tool()
def force_close_shell_session(identifier: str) -> str:
    """
    Force close a shell session by its identifier, killing its shell process.

    This interrupts whatever the session is currently running, including a command that is still running in the background, and discards any output that has not been read yet. Use it to free a session that is stuck, or that you no longer need.

    :param identifier: The identifier of the shell session to close.

    :return: If succeed, returns string "Succeed". If the session does not exist, or the shell process could not be killed, returns the reason.
    """
    with _sessions_lock:
        entry = list_of_alive_shells.get(identifier)

        if entry is None:
            return "Shell session with this identifier does not exist."

    # 故意不抢 session.lock —— force close 就是要能打断正在跑的命令。
    # 那条 execute_command 会读到 "shell exited",自己走清理分支。
    _notes, session = entry
    _discard_session(identifier, session)

    if session.is_alive():
        return "Error: the shell process is still alive after being killed."

    return "Succeed"




    # shell_id : str = ""
    # for i in range(100):
    #     _temp_shell_id : str = str(os.urandom(16).hex())
    #     if(len([s for s in get_live_shells() if s == _temp_shell_id]) == 0):
    #         shell_id = _temp_shell_id
    #         break
    # if shell_id == "":

    # return 


def _build_drop_privilege_kwargs() -> dict:
    """root 启动时返回降权用的 subprocess 参数;非 root 启动时返回空 dict。"""
    if os.geteuid() != 0:
        return {}  # 本来就不是 root,没权限也没必要降

    pw = pwd.getpwnam(RUN_AS_USER)
    # 只给 user= 的话附加组会原样继承 root 的,必须显式重算
    groups = {g.gr_gid for g in grp.getgrall() if RUN_AS_USER in g.gr_mem}
    groups.add(pw.pw_gid)

    return {
        "user": pw.pw_uid,
        "group": pw.pw_gid,
        "extra_groups": sorted(groups),
        "env": {
            "HOME": pw.pw_dir,
            "USER": RUN_AS_USER,
            "LOGNAME": RUN_AS_USER,
            "SHELL": pw.pw_shell,
            "PATH": "/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin",
            "LANG": os.environ.get("LANG", "C.UTF-8"),
        },
    }


DROP_PRIVILEGE_KWARGS = _build_drop_privilege_kwargs()




@mcp.tool()
def execute_command(shell_id: str, command: str, waittime: int, timeout: int) -> str:
    """
    Execute a command on a linux machine, inside an existing shell session.

    The command runs in the session's current working directory and inherits the environment variables it has accumulated, so 'cd' and 'export' from earlier commands still apply. Only one command can run per session at a time.

    :param shell_id: The identifier of the shell session to run the command in. Create one with create_shell_session first.
    :param command: The command to execute. Avoid commands that read from standard input, such as a bare 'cat' or an interactive interpreter, because they will consume the session's control channel and break it.
    :param waittime: Seconds to wait for the command to finish. If it is still running at this point, the output produced so far is returned and the command keeps running in the background. It is NOT killed. Use get_output to collect the rest.
    :param timeout: Hard limit in seconds, counted from the start of the command. A command still running at this point is killed, together with its shell session. Must be greater than or equal to waittime.

    :return: The output of the command, with stdout and stderr interleaved. A non-zero exit code is reported at the end. Output longer than the length limit is truncated, and the notice at the end tells you the offset to resume from with get_output. If the session does not exist, is already running another command, or died while running this one, returns the reason instead.
    """
    if waittime <= 0 or timeout <= 0:
        return "waittime and timeout must be positive numbers of seconds."
    if waittime > timeout:
        return "waittime must be less than or equal to timeout."
    # if timeout > MAX_COMMAND_TIMEOUT:
    #     return f"timeout must be at most {MAX_COMMAND_TIMEOUT} seconds."

    with _sessions_lock:
        _reap_dead_sessions()
        entry = list_of_alive_shells.get(shell_id)

    if entry is None:
        return (
            "Shell session with this identifier does not exist. "
            "Create one with create_shell_session first."
        )

    _notes, session = entry

    # 同一个 session 一次只能跑一条命令,否则两边的输出会串在一起
    if not session.try_begin():
        return (
            "This shell session is still running an earlier command. "
            f"Last command: {session.peek_last_command()}\n"
            "Wait for it, or call force_close_shell_session to kill it."
        )

    # 上一条命令留下的、还没被 get_output 取走的输出,先带回去,免得被 run() 清掉
    prefix = ""
    leftover = session.take_new_output()
    if leftover:
        prefix = (
            f"[unread output of the previous command `{session.peek_last_command()}`]\n"
            f"{leftover}"
            "[end of previous output]\n"
        )

    try:
        status, exit_code = session.run(command, float(waittime), float(timeout))
    except Exception as e:
        # shell 挂了:残留输出会污染后续命令,这个 session 只能丢弃
        _discard_session(shell_id, session)
        return f"{prefix}{e}. The shell session has been closed; create a new one."

    sl = session.read_output(0, MAX_CHARS)
    out = _discard_notice(sl) + sl.text + _truncation_notice(sl)

    if status == "background":
        return (
            f"{prefix}{out}"
            f"\n[still running in the background after {waittime} seconds. The output "
            "above is only what it has produced so far; call get_output on this "
            f"session to collect the rest. It will be killed, along with its shell "
            f"session, if it has not finished {timeout} seconds after it started.]"
        )

    if exit_code != "0":
        out += f"\n[exit code: {exit_code}]"

    # 一次性 session:跑完就回收(转后台的不能回收,它还在跑)
    is_temp = False
    with _sessions_lock:
        is_temp = shell_id in list_of_temp_shells
    if is_temp:
        _discard_session(shell_id, session)

    return prefix + out


@mcp.tool()
def get_output(shell_id: str, starting_char: int = 0) -> tuple[bool, str]:
    """
    Read the output of the command a shell session is running, or has most recently run.

    Use this after execute_command reported that a command is still running in the background, and to page through output that was truncated for being too long.

    :param shell_id: The identifier of the shell session to read from.
    :param starting_char: The character offset to start reading at. Offsets are counted from the start of the current command's output and stay valid until the next command is started on this session. Defaults to 0, the beginning of that output.
    :return: A pair (finished, output). "finished" is true when the session is idle, meaning the command has completed and no further output will appear; poll this tool until it becomes true. The output is truncated if it exceeds the length limit, and the notice at the end reports starting_char, ending_char and the total length, so call this tool again with starting_char set to that ending_char to read the next piece. If the very oldest output was dropped because the command produced more than the buffer holds, a notice at the beginning says so. If the session was killed for exceeding its timeout it no longer exists, and this returns (true, error message).
    """
    with _sessions_lock:
        _reap_dead_sessions()
        entry = list_of_alive_shells.get(shell_id)

    if entry is None:
        return True, (
            "Shell session with this identifier does not exist. It may have been "
            "killed for exceeding its timeout."
        )

    _notes, session = entry

    # 先读 busy 再读输出:反过来的话,两次读之间产生的输出会被漏掉,
    # 而调用方看到 finished=True 就不会再来取了。
    finished = not session.is_busy()
    sl = session.read_output(starting_char, MAX_CHARS)
    truncated = _truncation_notice(sl)
    output = _discard_notice(sl) + sl.text + truncated

    # 只在读到末尾时报退出码,免得分页读到一半就显示"结束了"
    if finished and not truncated and session.last_execution_result is not None:
        exit_code = session.last_execution_result[1]
        if exit_code != "0":
            output += f"\n[exit code: {exit_code}]"

    # 一次性 session 的后台命令跑完了,在这里回收
    if finished:
        with _sessions_lock:
            is_temp = shell_id in list_of_temp_shells
        if is_temp:
            _discard_session(shell_id, session)

    return finished, output


class AuthMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request, call_next):
        # 期望 Authorization: Bearer my-secret-token
        if request.headers.get("authorization") != f"Bearer {TOKEN}":
            return JSONResponse({"error": "unauthorized"}, status_code=401)
        return await call_next(request)


app = mcp.streamable_http_app(
    transport_security=TransportSecuritySettings(
        enable_dns_rebinding_protection=True,
        allowed_hosts=[
            "example.com",      # 裸域名：https 走 443，Host 头不带端口
            "example.com:*",
            "127.0.0.1:*",
            "localhost:*",
        ],
        allowed_origins=[
            "https://example.com",
        ],
    ),
)

app.add_middleware(AuthMiddleware)

if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=1949)
