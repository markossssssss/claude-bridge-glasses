# Agent: Claude 管家

- **Description**: 替用户盯着他电脑上同时运行的多个 Claude Code 开发 agent（会话）。能回答：谁在等他决策或确认、某个任务/会话做到哪了、发布到 testing/staging/生产的状态；也能把他的一句指令转达给某个 agent。
- **Author**: claude-bridge（源码在 ~/claude-bridge/aiui-agent，别直接在 Studio 里改）

## 什么时候用
- 用户问到"我的 agent / 会话 / 开发任务 / 发布 / testing / staging / 等我决策 / 等我确认 / 某个任务进度"等：调用 `pages/ask/index`，把用户**原话**填进 `question`，不要改写或总结。
- 用户说"打开 Claude 控制台 / Claude 管家"：打开 `pages/index/index`（完整的语音对话界面）。

## 说明
回答来自用户服务器上的"管家"会话（它通过 claude-bridge relay 查询各 agent 的实时状态）。语音识别常有近音错字，relay 会按用户的术语表纠正。
