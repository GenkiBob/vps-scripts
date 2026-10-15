# VPS 脚本框架

面向 Linux VPS 的 Bash 菜单入口。当前只有无副作用的演示项目。

## 使用

仓库地址：https://github.com/GenkiBob/vps-scripts 。仓库公开且代码上传到 main 分支后，可在 Linux VPS 直接执行：

```bash
wget -O vps-start.sh https://raw.githubusercontent.com/GenkiBob/vps-scripts/main/start.sh && bash vps-start.sh
```

需要 Bash、wget、tar 和 mktemp，无需 Git 或 GitHub 登录。`&&` 确保入口下载成功后再执行。入口下载 main 分支的完整项目快照，在独立临时目录启动菜单；菜单退出后清理临时项目，下载的 vps-start.sh 保留。每次启动重新获取远端版本；下载、解压失败或项目缺失时停止运行。

子脚本需要长期保存的数据、日志或备份，不应放在这份临时项目目录中，应按功能约定保存到持久目录。

也可以在本地完整项目中运行：

需要 Bash，不能使用 `sh main.sh`。

```bash
bash main.sh
```

输入编号并回车执行项目；成功或失败后自动返回菜单。输入无效、空输入或对应文件缺失时提示错误，输入 `0` 退出，输入流结束时正常退出。编号精确匹配，`01`、带空格的编号不会当作 `1`。

支持从其他目录启动：`bash /path/to/vps-scripts/main.sh`。请保留完整项目目录；主入口依赖本地子脚本，不适合只下载 main.sh 后运行。

## 目录

```text
start.sh              远程下载入口
main.sh               菜单入口与唯一菜单注册表
scripts/example.sh    可运行的演示脚本
templates/script.sh   新功能模板，不显示在菜单中
tests/menu.sh         菜单回归验证，不执行真实运维功能
tests/start.sh        下载入口回归验证，使用模拟下载
AGENTS.md             AI 协作协议及项目开发约定
```

## 新增功能

1. 先读取 `AGENTS.md`，确认具体功能及系统影响。
2. 将 `templates/script.sh` 复制为 `scripts/功能名.sh`，文件名使用小写英文和下划线。
3. 实现功能；脚本应能单独通过 `bash scripts/功能名.sh` 运行。
4. 在 `main.sh` 的 `MENU_ITEMS` 中追加一行，例如：

   ```bash
   '2|功能显示名称|scripts/feature.sh'
   ```

5. 编号必须唯一，使用正整数；`0` 保留给退出，不随意调整已有编号。名称和路径不能包含分隔符 `|`，路径固定在项目 `scripts/` 内。
6. 更新本 README 的功能清单，运行语法检查及菜单回归测试。

主脚本只负责菜单、输入校验与调度，具体安装、配置等操作放在子脚本。子脚本成功返回 `0`，失败返回非零退出码；不要启动主菜单、使用 `exec` 替换菜单或结束父进程。交互输入使用 `read -r`，路径变量加双引号。子脚本的默认工作目录为项目根目录；定位自身资源仍应根据 `BASH_SOURCE[0]` 计算绝对路径。

框架不自动要求 root 或提权。各功能按需要检查 root、系统和依赖。新功能的重复执行、备份与恢复行为应按其需求明确设计，不由框架假定。

当前功能：

| 编号 | 名称 | 文件 | 系统影响 |
| --- | --- | --- | --- |
| 1 | 运行演示脚本 | scripts/example.sh | 无 |

## 验证

在项目根目录用 Bash 执行：

```bash
for file in start.sh main.sh scripts/*.sh templates/*.sh tests/*.sh; do
    bash -n "$file" || break
done
bash tests/menu.sh
bash tests/start.sh
```

回归测试在临时副本中验证非法输入、重复执行、子脚本失败、文件缺失、跨目录调用及 EOF 退出，不执行真实运维脚本。

## 上传 GitHub 仓库

1. 本项目使用 `GenkiBob/vps-scripts`；直接免认证下载要求仓库可见性为 **Public**。
2. 在本地项目目录执行以下命令；将远程地址替换为实际仓库地址：

   ```bash
   git init -b main
   git add .
   git commit -m "Initialize Bash menu framework"
   git remote add origin https://github.com/GenkiBob/vps-scripts.git
   git push -u origin main
   ```

3. 首次提交若提示缺少身份，先设置自己的 `git config user.name` 和 `git config user.email`，再提交；推送按 Git 的认证提示操作，不把令牌写入脚本或远程地址。
4. 后续修改完成后，使用 `git add`、`git commit`、`git push` 同步。

上传流程参考 [GitHub 官方文档](https://docs.github.com/en/migrations/importing-source-code/using-the-command-line-to-import-source-code/adding-locally-hosted-code-to-github)。公开仓库的启动入口及运行脚本均可被下载查看。

## 在其他 Codex 对话继续

在同一项目目录创建对话，或在另一台设备克隆仓库后打开该项目。规则通过文件随项目保存，不依赖此对话的聊天记录。Codex 的 [AGENTS.md 官方说明](https://learn.chatgpt.com/docs/agent-configuration/agents-md) 介绍了项目指令的读取规则。

建议新对话第一条消息：

> 请先读取项目根目录 AGENTS.md 和 README.md，沿用现有 Bash 菜单框架，为我添加【具体功能】；独立子脚本放在 scripts/，在 main.sh 注册菜单，更新功能清单并完成验证。

其他不支持 AGENTS.md 的工具，需要明确让其读取这些文件。多对话同时修改项目时应协调菜单编号和注册表，避免覆盖彼此修改。
