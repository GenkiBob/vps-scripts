# 运行方法

Linux 环境需要 Bash、wget 和 mktemp。

下载并启动：

```bash
wget -O vps-start.sh https://raw.githubusercontent.com/GenkiBob/vps-scripts/main/start.sh && bash vps-start.sh
```

已下载完整项目时，在项目目录运行：

```bash
bash main.sh
```

输入菜单编号并回车执行，执行结束返回菜单，输入 `0` 退出。

在线启动只下载菜单；选中项目后下载对应脚本及其依赖，执行后清理临时文件。
