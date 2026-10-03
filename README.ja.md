# compact-plus

[English README](./README.md) | [アーキテクチャ](./docs/architecture.ja.md)

Claude Code・Codex・OpenCode の `/compact` 前後で作業状態を保存・復旧する透過型プラグイン。どの圧縮アルゴリズムも置き換えず、公式 hook 経路で圧縮前後を強化する。OpenCode 統合は **v1.18.32** を baseline として開発・テスト済みで、plugin API に破壊的変更がなければ v1.18.32 以降の v1 系でも動作することが期待できる。

## 何ができるか

- 圧縮前に transcript を backup し、LLM で 10 見出しの state file を書き出す
- 圧縮後に state file、plan file、原文再読 note を additionalContext として注入する
- transcriptで機械的に観測できたskillとcommandを復元する。Codexで観測できないskillは`Not verified`と記録する
- コンテキスト使用率がruntime別の指定閾値を超えたら、次のuser promptで`/compact`を推奨する通知を出す
- 通知と同時に state file の Active Plan / Current Phase / 直近 Session Decision を 3 行 additionalContext に注入し、圧縮直前まで agent が作業の大局を見失わないようにする (compact 動作そのものは変わらないが、warn 発火から実 `/compact` までの数ターンで agent が脱線するのを防ぐ focus 補助)
- `/compact-plus` skill で手動 state 保存もできる

## 使い方

インストール後は普通に `/compact` を実行するだけで動く。**追加の操作は不要**、完全透過型。

- 手動 `/compact` でも auto-compact でも同じ経路で hook が発火する
- 圧縮前: transcript backup と 10 見出し state file 生成が PreCompact hook で自動実行される
- 圧縮後: Claude CodeとCodexは最初のpost-compaction prompt前に`SessionStart(source=compact)`でstateを一度だけ自動注入する。OpenCodeでは`session.compacted` event後の最初のmodel turnで一度だけ注入する
- agent が特定 skill を呼ぶ必要も、事前に何かを実行する必要もない

任意で強化する場合:

- `/compact 重要な設計判断は必ず残して` のように引数を付けると、その内容が state 生成 LLM への priority guidance になる
- 復旧メモを厚く残したい時は圧縮直前に `/compact-plus` を明示的に呼ぶと、agent 自身が構造化 state を書く手動 fallback 経路に入る

## 前提

- Claude Code v2.x 以降、またはplugin compaction hook対応のCodex
- LLM backend として `claude -p` または `codex exec`
- default 構成では primary に `claude -p --model claude-sonnet-5 --effort medium`、fallback に `codex exec --model gpt-5.3-codex-spark` を使う
- fallback の Codex Spark は ChatGPT Pro が前提。`gpt-5.4` / `gpt-5.5` などへ切り替え可能

OpenCode 経路の前提:

- OpenCode v1.18.32(テスト済み baseline)。plugin API に破壊的変更がなければ v1.18.32 以降の v1 系でも動作することが期待できる
- `bash`、`jq`、Unix ファイルシステム意味論
- **`claude` / `codex` 実行ファイルは不要。** OpenCode の default backend は `scripts/opencode-core.sh` の決定論的 adapter。`COMPACT_PLUS_PRIMARY_BACKEND` / `COMPACT_PLUS_FALLBACK_BACKEND` を設定すれば従来の shell backend がそのまま使われる

## インストール

### Claude Code

このGitHub repositoryをmarketplaceとして追加し、そこからpluginをinstallする。

```bash
claude plugin marketplace add u-ichi/compact-plus --scope user
claude plugin install compact-plus@compact-plus
```

### Codex

同じGitHub repositoryをmarketplaceとして追加し、Codex pluginをinstallする。

```bash
codex plugin marketplace add u-ichi/compact-plus
codex plugin add compact-plus@compact-plus
```

Codexが確認を求めたらhook定義をreviewして信頼する。
install済みのpluginとhookを読み込ませるため、install後は新しいthreadを開始する。

### OpenCode

OpenCode は local plugin を `.opencode/plugins/`(project)または `~/.config/opencode/plugins/`(global)から読み込む。npm publish や marketplace は不要で、テスト済みの手順は clone した repository からの symlink である。

```bash
mkdir -p ~/.config/opencode/plugins ~/.config/opencode/commands
ln -s "$HOME/src/github.com/sasasin/compact-plus/opencode/plugins/compact-plus.js" ~/.config/opencode/plugins/compact-plus.js
ln -s "$HOME/src/github.com/sasasin/compact-plus/opencode/commands/compact-plus.md" ~/.config/opencode/commands/compact-plus.md
```

plugin は自分の real path から repository root を解決するので、symlink は clone した repository を指していること。project 側 (`<repo>/.opencode/plugins/compact-plus.js`) でも同じ。
install 後に新しい OpenCode session を開始して plugin を読み込ませる。

手動 fallback は `/compact-plus` command(`opencode/commands/compact-plus.md`)。既存の `skills/compact-plus/SKILL.md` は OpenCode が discovery する skill path にないため、skill 形式も使いたい場合は `~/.config/opencode/skills/compact-plus/SKILL.md` または `.opencode/skills/compact-plus/SKILL.md` へ symlink する。

### 更新

GitHub marketplaceのsnapshotを更新してから、pluginを更新または再installする。

```bash
# Claude Code
claude plugin update compact-plus@compact-plus

# Codex
codex plugin marketplace upgrade compact-plus
codex plugin add compact-plus@compact-plus
```

ローカル開発では、marketplace追加commandの`u-ichi/compact-plus`をこのrepositoryの絶対pathへ置き換える。
plugin参照は`compact-plus@compact-plus`のまま変えない。

## 設定

Claude Code plugin の標準に従い、`~/.claude/settings.json` の `env` block に env var を書く。session ごとの一時上書きは shell の `export` でもよい。

### backend 上書き

primary / fallback を丸ごと差し替える env var は 2 個。

| env var | 意味 |
|---|---|
| `COMPACT_PLUS_PRIMARY_BACKEND` | primary で実行する shell コマンド全体。空文字列 (`""`) で primary skip |
| `COMPACT_PLUS_FALLBACK_BACKEND` | fallback で実行する shell コマンド全体。空文字列で fallback skip |

コマンド内で参照できる env var:

- `$SYSTEM_PROMPT`: LLM 用 system prompt (`prompts/state-summary.md` の内容)
- `$SESSION_ID`: Claude Code session id
- `$TRANSCRIPT_PATH`: transcript JSONL path
- `$MAX_OUTPUT_TOKENS`: LLM 出力上限

デフォルト値は `hooks/precompact-state-summary.sh` に直書きしている。

`~/.claude/settings.json` 例。Haiku で安く済ませたい場合:

```json
{
  "env": {
    "COMPACT_PLUS_PRIMARY_BACKEND": "claude -p --model claude-haiku-4-5-20251001 --effort low --permission-mode dontAsk --output-format text --no-session-persistence --system-prompt \"$SYSTEM_PROMPT\""
  }
}
```

primary を Codex Spark に差し替える例 (ChatGPT Pro 前提、Cerebras 経由で高速):

```json
{
  "env": {
    "COMPACT_PLUS_PRIMARY_BACKEND": "tmp=$(mktemp \"${TMPDIR:-/tmp}/compact-plus-codex.XXXXXX\"); { printf \"%s\\n\\n\" \"$SYSTEM_PROMPT\"; cat; } | codex exec --model gpt-5.3-codex-spark --sandbox read-only --skip-git-repo-check --dangerously-bypass-hook-trust --ignore-user-config --ephemeral --output-last-message \"$tmp\" - >/dev/null && cat \"$tmp\"; status=$?; rm -f \"$tmp\"; exit \"$status\""
  }
}
```

Codex 経路は stdout に preamble が混ざる場合があるため、`--output-last-message "$tmp"` で最終メッセージだけ取り出す必要がある (これは default fallback の実装と同じ形)。

fallback を無効化する例:

```json
{
  "env": {
    "COMPACT_PLUS_FALLBACK_BACKEND": ""
  }
}
```

### transcript / squash / two-pass のチューニング env

| env var | default | 意味 |
|---|---|---|
| `COMPACT_PLUS_TRANSCRIPT_MODE` | `incremental` | `incremental` / `head-tail` / `tail` |
| `COMPACT_PLUS_TRANSCRIPT_HEAD_TURNS` | `5` | head 側で切り出す turn 数 |
| `COMPACT_PLUS_TRANSCRIPT_TAIL_TURNS` | `25` | tail 側で切り出す turn 数 |
| `COMPACT_PLUS_TRANSCRIPT_HEAD_KB` | `10` | head 側 byte cap (KB) |
| `COMPACT_PLUS_TRANSCRIPT_TAIL_KB` | `40` | tail 側 byte cap (KB) |
| `COMPACT_PLUS_RAW_DELTA_FACTOR` | `20` | incremental で squash 前に読む raw 差分の上限 (`TAIL_KB * N`)。`0` で無制限 |
| `COMPACT_PLUS_INCREMENTAL_REFRESH` | `10` | N 回に 1 回全再構築。`0` で無効 |
| `COMPACT_PLUS_MAX_OUTPUT_TOKENS` | `4096` | LLM 出力上限。backend が参照する場合に使う |
| `COMPACT_PLUS_BACKEND_TIMEOUT` | `80` | backend 1 つあたりの timeout (秒)。primary と fallback は hook 全体の 180 秒の中で直列に走る。`0` で無効 |
| `COMPACT_PLUS_SQUASH_ENABLED` | `1` | tool_result squash on/off |
| `COMPACT_PLUS_SQUASH_READ_LINES` | `100` | Read tool `> N` 行で `[Read: N lines from path]` に置換 |
| `COMPACT_PLUS_SQUASH_BASH_CHARS` | `500` | Bash tool `> N` chars で `[Bash: exit code, N chars output]` に置換 |
| `COMPACT_PLUS_TWO_PASS` | `1` | 2-pass self-critique on/off |

### warn 閾値

Claude CodeとCodexは別設定を使う。

| runtime | env var | default | 取得元 |
|---|---|---:|---|
| Claude Code | `COMPACT_WARN_THRESHOLD` | base repository設定 | `home/hooks/claude/statusline.sh`がmarkerを生成 |
| Codex | `COMPACT_PLUS_CODEX_WARN_THRESHOLD` | `75` | 現在threadのrolloutにある最新token-count event |
| OpenCode | `COMPACT_PLUS_OPENCODE_WARN_THRESHOLD` | `75` | 直近assistant messageのtoken使用率をmodel context limitに対して計算する (OpenCode v1 plugin APIが渡す実測値。v1.18.32でテスト済み) |

どちらもコンテキスト**使用率**。片方の変更はもう片方へ影響しない。Codexは表示と同じ実効window基準を使い、現在の固定baseline 12,000 tokenを分子・分母から除外する。rolloutの`session_meta.id`と現在の`session_id`の一致も確認し、欠損・不正・不一致なら通知しない。

OpenCode の値は `直近 assistant message の total tokens / model context limit * 100`。これは v1 plugin API が渡す実測 metric で (v1.18.32 で確認)、推定値ではない。通知は compaction cycle ごとに 1 回、cooldown marker で制御され、compaction 完了時にリセットされる。

### `/compact` 引数

`/compact 重要な設計判断は必ず残して` のように任意の自然文引数を渡すと、state 生成 LLM に priority guidance として反映される。

OpenCode v1 plugin API (v1.18.32 で確認) ではこれは**サポートされない**。plugin API は compaction 単位の user instructions を公開していない (`/compact` は command-service command ではなく、compaction hook は `sessionID` しか受け取らない)。state prompt には `(none)` として記録される。優先事項は圧縮前に会話または state file へ書いておく。

## 動作フロー

1. **PreCompact hook**
   - `precompact-transcript-backup.sh` が transcript JSONL を `~/.claude/backups/transcripts/` または `${CODEX_HOME:-$HOME/.codex}/backups/transcripts/` にコピーする
   - `precompact-state-summary.sh` が transcript を semantic chunking + tool output squash 後、primary / fallback backend で LLM を呼び、10 見出しの state file を書く
2. **PostCompact hook**
   - `compaction-recovery.sh` が warn cooldown をリセットし、`SessionStart` が残した注入済み印があればそれを consume し、無ければ recovery marker を書く
3. **復旧hook**
   - `sessionstart-compaction-recovery.sh` がClaude CodeとCodexの`SessionStart(source=compact)`を処理する
   - 保存済みstate本文、存在する場合のactive plan参照、original-source reminderを`additionalContext`へ注入する
   - 2つのruntimeはcompaction hookの発火順が違うため、固定の順序ではなくhook間のhandshakeで一度だけ注入する。Claude Codeは`SessionStart(source=compact)`を`PostCompact`より**先**に配送するので初回compactionではmarkerがまだ無い。この時はstate fileの存在を根拠に注入し、注入済み印を残す。後から走る`PostCompact`はその印をconsumeしてmarkerを書かない。Codexは`PostCompact`が**先**なのでmarkerが既にあり、`SessionStart`がそれをconsumeする。どちらの順でも注入はちょうど1回になる
   - `userpromptsubmit-compact-plus-reminder.sh` が warn marker 検知時に軽い notification と state 3 行 recitation を additionalContext に注入する
   - `userpromptsubmit-compaction-recovery.sh` は fallback channel として登録を維持する。Codexがstart hookを配送するのはroot threadだけであり、親がspawnしたsubagentには圧縮後のstart hookが来ないため、復旧は次の`UserPromptSubmit`で届く (親からの送信はsubagentにはuser inputとして入る)。markerは1度で消費されるので、`SessionStart`で復旧済みのthreadは次のpromptでは何もしない
4. **手動 fallback (`/compact-plus` skill)**
   - agent 自身が SKILL.md の 10 見出し手順に従って state file を書く

### OpenCode のフロー

OpenCode は plugin API が違うため、この統合は Claude/Codex hook script の移植ではなく adapter である。すべての判断は `scripts/opencode-core.sh` にあり、`opencode/plugins/compact-plus.js` は薄い edge adapter。

1. `experimental.session.compacting` が compaction を開始し、flag を立てる。この hook 内で plugin SDK を呼ぶと server へ再入して失敗することが v1.18.32 で確認済みなので、ここでは messages を fetch しない (v1 系で API が変わらない限り同じ設計が成り立つ)
2. `experimental.chat.messages.transform` が compaction request の messages を渡す。core が backup を書き、既存の head/tail/incremental 選択と tool output squash を適用して state prompt を組み立てる
3. state 生成: `COMPACT_PLUS_PRIMARY_BACKEND` / `COMPACT_PLUS_FALLBACK_BACKEND` が設定されていれば従来の shell backend、無ければ OpenCode ネイティブの決定論的 adapter が 10 見出し state file を書く。観測事実から導けない意味セクションは `Not verified`
4. `session.compacted` event が one-shot recovery marker を arm し、warn cooldown をリセットする
5. event 後の最初の `experimental.chat.system.transform` が marker を consume し、recovery payload (state 本文は 30720 byte で truncate、active plan pointer、saved-at staleness note、original-source reminder) をちょうど 1 回注入する。後続 turn は静か、2回目の compaction は再び復旧できる
6. `shell.env` が `OPENCODE_SESSION_ID` と `COMPACT_PLUS_OPENCODE_ROOT` を export し、手動 `/compact-plus` command が実 session identity を取得できる

OpenCode の storage は `opencode-*` directory と `${OPENCODE_DATA_DIR:-$HOME/.local/share/opencode}/backups/compact-plus/` を使い、`claude-*` / `codex-*` と衝突しない。

## state file 見出し構成

`# Compact Prep State` から始まる 10 見出し。SKILL.md 手動手順と LLM 生成の両方で同じ順序を使う。

1. `## Active Plan`
2. `## Current Phase`
3. `## TaskList Summary`
4. `## Session Decisions`
5. `## Constraints and Blockers`
6. `## Worker Topology`
7. `## Skills Invoked`
8. `## Editing Files`
9. `## Failed Attempts`
10. `## Recovery Notes`

## marker ファイル

| path | writer | reader | 目的 |
|---|---|---|---|
| `${TMPDIR}/claude-compact-state/<session_id>.md` | `precompact-state-summary.sh` / `/compact-plus` skill | recovery hook / agent | 圧縮前 state |
| `${TMPDIR}/claude-compact-state-offset/<session_id>` | `precompact-state-summary.sh` | `precompact-state-summary.sh` | incremental 用 byte offset |
| `${TMPDIR}/claude-compact-state-counter/<session_id>` | `precompact-state-summary.sh` | `precompact-state-summary.sh` | refresh cycle counter |
| `${TMPDIR}/claude-compacted/<session_id>` | `compaction-recovery.sh` | `sessionstart-compaction-recovery.sh` / `userpromptsubmit-compaction-recovery.sh` | one-shot PostCompact marker |
| `${TMPDIR}/claude-compact-injected/<session_id>` | `sessionstart-compaction-recovery.sh` | `compaction-recovery.sh` | 注入済み印。`SessionStart`が注入済みなので`PostCompact`はmarkerを書かない |
| `${TMPDIR}/claude-compact-warn/<session_id>` | base repo `statusline.sh` | `userpromptsubmit-compact-plus-reminder.sh` | 閾値超過通知 |
| `${TMPDIR}/claude-compact-warned/<session_id>` | `userpromptsubmit-compact-plus-reminder.sh` | statusline / recovery hook | 通知 cooldown |
| `${TMPDIR}/claude-active-plan/<session_id>` | plan-management hook | recovery hook | active plan path |
| `${TMPDIR}/codex-compact-state/<thread_id>.md` | `precompact-state-summary.sh` / `/compact-plus` skill | Codex recovery hook / agent | Codex圧縮前state |
| `${TMPDIR}/codex-compacted/<thread_id>` | `compaction-recovery.sh` | `sessionstart-compaction-recovery.sh` / `userpromptsubmit-compaction-recovery.sh` | Codex one-shot recovery marker |
| `${TMPDIR}/codex-compact-injected/<thread_id>` | `sessionstart-compaction-recovery.sh` | `compaction-recovery.sh` | 同じhandshake用のCodex注入済み印 |
| `${TMPDIR}/codex-compact-warned/<thread_id>` | reminder hook | reminder / recovery hook | Codex通知cooldown |
| `${TMPDIR}/opencode-compact-state/<session_id>.md` | `scripts/opencode-core.sh` | recovery injection / agent | OpenCode圧縮前state |
| `${TMPDIR}/opencode-compact-state-offset/<session_id>` | `scripts/opencode-core.sh` | `scripts/opencode-core.sh` | OpenCode incremental message offset |
| `${TMPDIR}/opencode-compact-state-counter/<session_id>` | `scripts/opencode-core.sh` | `scripts/opencode-core.sh` | OpenCode refresh cycle counter |
| `${TMPDIR}/opencode-compacted/<session_id>` | `scripts/opencode-core.sh` (event) | `scripts/opencode-core.sh` (inject) | OpenCode one-shot recovery marker |
| `${TMPDIR}/opencode-compact-warned/<session_id>` | `scripts/opencode-core.sh` | reminder / recovery | OpenCode通知cooldown |
| `${TMPDIR}/opencode-active-plan/<session_id>` | plan-management hook | `scripts/opencode-core.sh` | OpenCode active plan path |
| `${OPENCODE_DATA_DIR:-$HOME/.local/share/opencode}/backups/compact-plus/<epoch>-<session_id>.jsonl` | `scripts/opencode-core.sh` | recovery injection / agent | OpenCode session backup (message JSONL)、sessionごとに新しい20件保持 |

Codexの`<thread_id>`は実際に圧縮したthreadを指す。hook入力の`session_id`はroot threadと全子孫で共有するidで、親がspawnしたsubagentにはさらに`agent_id`が付く。そのため成果物のキーは`agent_id`があればそれを使い、無い時だけ`session_id`を使う (`scripts/runtime-paths.sh`の`compact_plus_artifact_key`)。`session_id`だけで名前を付けると、subagentのstateが親の名前で保存され、親のstate fileを上書きしてしまう。

## Architecture

設計、Claude Code / Codex CLI の compact 仕様比較、marker file の所有関係は [docs/architecture.ja.md](./docs/architecture.ja.md) を参照。

## Development Checks

```bash
python3 -m json.tool .claude-plugin/plugin.json >/dev/null
python3 -m json.tool .claude-plugin/marketplace.json >/dev/null
python3 -m json.tool .codex-plugin/plugin.json >/dev/null
python3 -m json.tool .agents/plugins/marketplace.json >/dev/null
python3 -m json.tool hooks/hooks.json >/dev/null
bash -n hooks/*.sh scripts/*.sh tests/*.sh
bash tests/test-runtime.sh
bash tests/test-opencode.sh
bash tests/test-opencode-integration.sh   # OpenCode v1 の実行ファイルが必要 (v1.18.32でテスト済み)。無ければskip
```
