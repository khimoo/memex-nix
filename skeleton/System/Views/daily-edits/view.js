const COPY = {
  "refresh": "更新",
  "loading": "Git の履歴を読み込んでいます…",
  "empty": "該当するファイルはありません。",
  "invalidDate": "日次ノートのファイル名を YYYY-MM-DD 形式にしてください。",
  "invalidKind": "一覧の種類には created または edited を指定してください。",
  "desktop": "この一覧はデスクトップ版の Obsidian で利用できます。",
  "missingGit": "Git が見つかりません。Obsidian から Git を実行できる環境か確認してください。",
  "notRepository": "Vault が Git リポジトリとして認識されていません。",
  "noHistory": "読み取れるコミット履歴がありません。",
  "timeout": "Git の実行がタイムアウトしました。「更新」ボタンで再試行できます。",
  "tooLarge": "Git の出力が上限を超えたため、一覧を作成できませんでした。",
  "parse": "Git の出力を解析できなかったため、一覧を作成できませんでした。",
  "git": "Git の履歴を取得できませんでした。",
  "unexpected": "予期しないエラーが発生したため、一覧を表示できませんでした。"
};

class HistoryError extends Error {
  constructor(kind) {
    super(kind);
    this.kind = kind;
  }
}

function dayBounds(day) {
  if (typeof day !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(day)) {
    throw new HistoryError("invalidDate");
  }
  const start = Date.parse(`${day}T00:00:00+09:00`);
  if (!Number.isFinite(start) || new Date(start + 9 * 3600000).toISOString().slice(0, 10) !== day) {
    throw new HistoryError("invalidDate");
  }
  return [start / 1000, start / 1000 + 86400];
}

function parseCommitLog(output) {
  if (!output) return [];
  return output.replace(/\n$/, "").split("\n").map(line => {
    const match = /^([0-9a-f]{40}|[0-9a-f]{64})\0(-?\d+)$/.exec(line);
    if (!match || !Number.isSafeInteger(Number(match[2]))) throw new HistoryError("parse");
    return {hash: match[1], authorTime: Number(match[2])};
  });
}

function parseNameStatus(output) {
  if (!output) return [];
  if (!output.endsWith("\0")) throw new HistoryError("parse");
  const tokens = output.slice(0, -1).split("\0");
  const changes = [];
  for (let index = 0; index < tokens.length;) {
    const status = tokens[index++];
    if (!/^(?:[AMDTUXB]|[RC]\d{1,3})$/.test(status)) throw new HistoryError("parse");
    const first = tokens[index++];
    if (!first) throw new HistoryError("parse");
    if (status.startsWith("R") || status.startsWith("C")) {
      const next = tokens[index++];
      if (!next) throw new HistoryError("parse");
      changes.push({status: status[0], oldPath: first, path: next});
    } else {
      changes.push({status, path: first});
    }
  }
  return changes;
}

function inScope(path) {
  return /^(?:Inbox|Knowledge|LifeState)\//.test(path)
    || ["Home.md", "README.md", "CLAUDE.md", "AGENTS.md"].includes(path);
}

function classifyChanges(commits) {
  const created = new Map();
  const edited = new Map();
  for (const changes of commits) {
    for (const change of changes) {
      if (change.status === "D") {
        created.delete(change.path);
        edited.delete(change.path);
        continue;
      }
      if (change.status === "R" && created.has(change.oldPath)) {
        created.delete(change.oldPath);
        edited.delete(change.oldPath);
        if (inScope(change.path)) created.set(change.path, {path: change.path});
        continue;
      }
      if (!inScope(change.path)) continue;
      if (change.status === "A") {
        created.set(change.path, {path: change.path});
        edited.delete(change.path);
      } else if (change.status === "M" && !created.has(change.path)) {
        if (!edited.has(change.path)) edited.set(change.path, {path: change.path});
      } else if (change.status === "R" && !created.has(change.path)) {
        const previous = edited.get(change.oldPath);
        edited.delete(change.oldPath);
        edited.set(change.path, {path: change.path, oldPath: previous?.oldPath || change.oldPath});
      }
    }
  }
  for (const path of created.keys()) edited.delete(path);
  const sorted = entries => [...entries.values()].sort((a, b) => a.path < b.path ? -1 : a.path > b.path ? 1 : 0);
  return {created: sorted(created), edited: sorted(edited)};
}

function gitError(error) {
  if (error instanceof HistoryError) return error;
  if (error.code === "ENOENT") return new HistoryError("missingGit");
  if (error.code === "ERR_CHILD_PROCESS_STDIO_MAXBUFFER") return new HistoryError("tooLarge");
  if (error.killed || error.code === "ETIMEDOUT") return new HistoryError("timeout");
  if (/not a git repository/i.test(error.stderr || "")) return new HistoryError("notRepository");
  if (/unknown revision|bad revision|needed a single revision/i.test(error.stderr || "")) {
    return new HistoryError("noHistory");
  }
  return new HistoryError("git");
}

function execGit(root, args) {
  return new Promise((resolve, reject) => {
    require("child_process").execFile("git", args, {
      cwd: root,
      encoding: "utf8",
      timeout: 15000,
      maxBuffer: 16 * 1024 * 1024,
      windowsHide: true,
      shell: false,
      env: {...process.env, GIT_OPTIONAL_LOCKS: "0"}
    }, (error, stdout, stderr) => {
      if (error) {
        error.stderr = stderr;
        reject(gitError(error));
      } else {
        resolve(stdout);
      }
    });
  });
}

// 一覧の日付は、コミットの author date を日本時間で見た日で、実際に編集した日とは限らない。
// 手動でまとめてコミットすると、前の日の編集もコミットした日に出る。まだコミットしていない変更と、
// マージコミットの中だけで直した変更（競合の解決）は出ない。
function createReader(runGit = execGit) {
  const roots = new Map();
  return async (root, day, refresh = false) => {
    const [start, end] = dayBounds(day);
    let state = roots.get(root);
    if (!state) {
      state = {probe: null, head: null, commits: null, days: new Map()};
      roots.set(root, state);
    }
    if (!state.probe) {
      state.probe = runGit(root, ["rev-parse", "--verify", "HEAD"])
        .finally(() => { state.probe = null; });
    }
    const head = (await state.probe).trim();
    if (!/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/.test(head)) throw new HistoryError("parse");
    if (refresh || state.head !== head || !state.commits) {
      state.head = head;
      state.days = new Map();
      const pending = runGit(root, ["log", "HEAD", "--no-merges", "--format=%H%x00%at"])
        .then(parseCommitLog);
      state.commits = pending;
      pending.catch(() => {
        if (state.commits === pending) state.commits = null;
      });
    }
    const days = state.days;
    if (!days.has(day)) {
      const pending = state.commits.then(async commits => {
        const selected = commits.filter(commit => commit.authorTime >= start && commit.authorTime < end).reverse();
        const changes = [];
        for (const commit of selected) {
          changes.push(parseNameStatus(await runGit(root,
            ["show", "--format=", "--name-status", "-z", "-M", commit.hash, "--"])));
        }
        return classifyChanges(changes);
      });
      days.set(day, pending);
      pending.catch(() => {
        if (days.get(day) === pending) days.delete(day);
      });
    }
    return days.get(day);
  };
}

async function render(dv, input) {
  const container = dv.container.createDiv({cls: "daily-edits"});
  const kind = input?.kind;
  const fail = error => {
    container.replaceChildren();
    container.createEl("p", {text: COPY[error.kind] || COPY.unexpected, cls: "daily-edits-error"});
  };
  let day;
  let root;
  try {
    if (!["created", "edited"].includes(kind)) throw new HistoryError("invalidKind");
    day = dv.current()?.file?.name;
    dayBounds(day);
    if (typeof require !== "function" || typeof dv.app.vault.adapter.getBasePath !== "function") {
      throw new HistoryError("desktop");
    }
    root = dv.app.vault.adapter.getBasePath();
  } catch (error) {
    fail(error);
    return;
  }
  const button = container.createEl("button", {text: COPY.refresh});
  const result = container.createDiv();
  const key = Symbol.for("memex.daily-edits");
  const version = dv.app.vault.getAbstractFileByPath("System/Views/daily-edits/view.js")?.stat.mtime;
  if (!globalThis[key] || globalThis[key].version !== version) {
    globalThis[key] = {version, read: createReader()};
  }
  const read = globalThis[key].read;
  let generation = 0;
  const appendPath = async (target, path) => {
    if (dv.app.vault.getAbstractFileByPath(path)) {
      await dv.api.renderValue(dv.fileLink(path, false, path), target, dv.component, dv.currentFilePath, true);
    } else {
      target.appendText(path);
    }
  };
  const update = async refresh => {
    const current = ++generation;
    button.disabled = true;
    result.replaceChildren();
    result.createEl("p", {text: COPY.loading});
    try {
      const entries = (await read(root, day, refresh))[kind];
      if (current !== generation || !container.isConnected) return;
      result.replaceChildren();
      if (!entries.length) {
        result.createEl("p", {text: COPY.empty});
      } else {
        const list = result.createEl("ul");
        for (const entry of entries) {
          if (current !== generation || !container.isConnected) return;
          const item = list.createEl("li");
          if (entry.oldPath) {
            await appendPath(item, entry.oldPath);
            item.appendText(" → ");
          }
          await appendPath(item, entry.path);
        }
      }
    } catch (error) {
      if (current === generation && container.isConnected) {
        result.replaceChildren();
        result.createEl("p", {text: COPY[error.kind] || COPY.unexpected, cls: "daily-edits-error"});
      }
    } finally {
      if (current === generation) button.disabled = false;
    }
  };
  dv.component.registerDomEvent(button, "click", () => { void update(true); });
  await update(false);
}

if (typeof dv !== "undefined") {
  return render(dv, typeof input === "undefined" ? {} : input);
} else if (typeof module !== "undefined") {
  module.exports = {HistoryError, dayBounds, parseCommitLog, parseNameStatus, inScope,
    classifyChanges, gitError, execGit, createReader, render, COPY};
}
