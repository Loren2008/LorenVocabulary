# Contributing to LorenVocabulary

感谢你参与 LorenVocabulary。贡献可以是代码、测试、文档、设计或可复现的问题报告。

## 开始之前

1. 搜索现有 Issues，避免重复工作。
2. 大型功能或会改变数据格式的改动，请先创建 Issue 讨论。
3. 不要在 Issue、PR、提交历史或测试夹具中加入 API Key、个人数据、真实考试文本或来源不明的词典内容。
4. 参与本项目即表示你有权提交这些内容，并同意按 MIT License 发布你的贡献。

## 本地开发

```bash
git clone https://github.com/Loren2008/LorenVocabulary.git
cd LorenVocabulary
swift test
python3 -m unittest discover -s Tests -p 'test_expansion_pipeline.py'
```

需要 DeepSeek 时，请将配置放在 `~/.ielts-vocab/Config.plist` 或使用 `DEEPSEEK_API_KEY` 环境变量。不要创建可被 Git 跟踪的真实配置文件。

## Pull Request 要求

- 一个 PR 聚焦一个主题，并说明动机、行为变化和验证方法。
- 用户可见变化应提供截图或录屏；崩溃修复应提供可复现步骤。
- 新逻辑需要相应测试，所有现有测试必须通过。
- 涉及数据库时，说明 schema、迁移、来源、许可证和真实性标记。
- AI 生成的 IELTS 语境必须标为 `AI-generated IELTS-style example`，不得声称来自真实考试。
- 不得绕过粘贴板完整保存/恢复、稳定签名或数据库发布门禁。

## 代码风格

- Swift 保持现有 SwiftUI/AppKit 结构和清晰的 `MARK` 分区。
- Python 遵循标准库优先、可恢复执行和原子发布原则。
- 注释解释“为什么”，避免重复代码本身。
- 不提交构建产物、虚拟环境、生成数据、个人路径或本机签名材料。

## 数据贡献规则

词头、释义、例句、搭配和语料必须具有清晰可核验的来源及再分发许可。商业词典文本、macOS 系统词典输出和真实 IELTS 试题不能仅因为能在本机访问就提交到仓库。详细规则见 [docs/DATA_AND_LICENSING.md](docs/DATA_AND_LICENSING.md)。

## 报告安全问题

安全问题不要创建公开 Issue。请按照 [SECURITY.md](SECURITY.md) 使用 GitHub Private Vulnerability Reporting。
