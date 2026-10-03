# code-server + SSH 开发镜像

基于 `ubuntu:26.04` 的 [code-server](https://github.com/coder/code-server) 开发镜像，内置 OpenSSH 服务器，可通过浏览器（8080）和 SSH（22）两种方式访问。

> **定位**：供**可信内网**使用的开发环境。镜像内预置了弱口令、**root 不允许 SSH 登录**、`coder` 拥有免密 sudo —— 详见[安全](#安全)。不要把它暴露到公网。

## 快速开始

```bash
docker build -t code-server-ssh .
docker run --name code-server -p 8080:8080 -p 2222:22 \
  -v "$PWD:/home/coder/project" code-server-ssh
```

- 浏览器打开 <http://127.0.0.1:8080>，密码见 [code-server 登录密码](#code-server-登录密码)。
- `ssh -p 2222 coder@localhost`，密码 `coder`。

## 构建镜像

### 前置条件

1. 仓库根目录的 `release-packages/` 下存在 code-server 的 deb 包（如 `code-server_4.140.0_amd64.deb`）。`Dockerfile` 用 glob 匹配，文件名中的版本号可以不同。
2. 需要 **BuildKit**。`Dockerfile` 里的 `RUN --mount=from=packages,...` 依赖它，用 `DOCKER_BUILDKIT=1` 或 Docker 23+ 的默认构建器。

### 命令

```bash
docker build -t code-server-ssh .
```

### 构建参数（`--build-arg`）

| 参数 | 默认值 | 说明 |
|---|---|---|
| `BASE` | `ubuntu:26.04` | 基础镜像。`docker-bake.hcl` 通过它切换发行版 |
| `CODER_PASSWORD` | `coder` | 构建期写入的 `coder` 密码，也是唯一的 SSH 登录口令 |

```bash
docker build -t code-server-ssh --build-arg CODER_PASSWORD=yyy .
```

注意：`--build-arg` 的值会留在镜像的构建历史里（`docker history` 可见）。内网镜像通常无所谓，但不要把它当作保密手段。

### 关于 docker-bake.hcl

该文件面向上游的 `ci/release-image/` 目录结构编写，引用的 `dockerfile` 路径在本仓库中不存在（相关文件已平铺到根目录），因此本仓库请直接使用 `docker build`。

## 使用镜像

### 启动

```bash
docker run --name code-server -p 8080:8080 -p 2222:22 \
  -v "$PWD:/home/coder/project" code-server-ssh
```

`-e` 等所有 docker 选项必须写在**镜像名之前**。写在镜像名后面的内容会被当成容器内要执行的命令参数，透传给 `code-server`：

```bash
# 错误：SSH_USER_PASSWORD 不会生效，反而会成为 code-server 的命令行参数
docker run ... code-server-ssh -e SSH_USER_PASSWORD=coder

# 正确
docker run ... -e SSH_USER_PASSWORD=coder code-server-ssh
```

### 挂载建议

只挂 `$PWD` 时，code-server 的扩展和配置存放在容器可写层里，`docker rm` 重建即丢失。长期使用建议按官方做法再挂两个目录：

```bash
mkdir -p ~/.config
docker run --name code-server -p 8080:8080 -p 2222:22 \
  -v "$HOME/.local:/home/coder/.local" \
  -v "$HOME/.config:/home/coder/.config" \
  -v "$PWD:/home/coder/project" \
  code-server-ssh
```

### 登录凭据

| 入口 | 用户名 | 默认密码 | 运行时覆盖 |
|---|---|---|---|
| SSH | `coder` | `coder` | `-e SSH_USER_PASSWORD=xxx` |
| SSH | `root` | 不可登录 | —— |
| code-server (8080) | 不适用 | 见下方说明 | 改 `~/.config/code-server/config.yaml` |

root 不允许通过 SSH 登录（`PermitRootLogin no`，且 root 账户无密码）。需要 root 权限时先以 `coder` 登录，再借助它的免密 sudo，例如 `sudo -i`。

#### code-server 登录密码

与 SSH 密码无关，是 code-server 自己生成的。首次启动时会写入 `$HOME/.config/code-server/config.yaml` 并打印在容器日志里：

```bash
docker logs code-server | grep -i password
```

未挂载 `~/.config` 时，容器重建后该密码会重新随机生成。

### 用户与权限

容器默认以 uid 1000 的 `coder` 运行，`coder` 有 `NOPASSWD:ALL` 的 sudo。传入 `-e DOCKER_USER=$USER` 可将 `coder` 改名并对齐你自己的 uid，方便 bind mount 的目录权限（详见 `install.md`）。

### 启动时执行自定义脚本

`${HOME}/entrypoint.d` 下的可执行文件会在容器启动时被依次执行（见 `Dockerfile` 中的 `ENTRYPOINTD`）：

```bash
docker run ... -v "$PWD/entrypoint.d:/home/coder/entrypoint.d" code-server-ssh
```

## 镜像参数

### 环境变量（运行时可通过 `-e` 覆盖）

| 变量 | 默认值 | 说明 |
|---|---|---|
| `ENABLE_SSH` | `1` | 设为 `0` 则不启动 sshd，只跑 code-server |
| `SSHD_LOG` | `/var/log/sshd.log` | sshd 日志文件路径，可指向挂载卷以便长期保留 |
| `SSH_USER_PASSWORD` | 空 | 非空时覆盖 `coder`（或 `DOCKER_USER`）密码 |
| `DOCKER_USER` | 空 | 非空时将 `coder` 改名为该用户名 |
| `ENTRYPOINTD` | `$HOME/entrypoint.d` | 启动脚本目录 |
| `LANG` | `en_US.UTF-8` | 由 `locale-gen` 生成 |
| `USER` | `coder` | 与 `USER 1000` 配套 |

### 端口与用户

| 项 | 值 |
|---|---|
| `EXPOSE` | `22`（sshd）、`8080`（code-server） |
| `USER` | `1000` |
| `WORKDIR` | `/home/coder` |
| `ENTRYPOINT` | `/usr/bin/entrypoint.sh --bind-addr 0.0.0.0:8080 .` |

`ENTRYPOINT` 是 exec 形式，在镜像名之后追加的参数会作为额外参数传给 `code-server`（上面的 `-e` 误用就是被这样吞掉的）。

### 进程模型

`code-server` 是容器的 PID 1（经 `dumb-init`）。sshd 由 `entrypoint.sh` 通过 `sudo` 在后台拉起，**不是** PID 1 —— 这样 SSH 出问题不会连带容器一起挂掉。相应地，sshd 不会随容器优雅退出，停止容器时被直接终止。

## 安全

**这个镜像的默认配置是按"内网、不考虑安全"的口径设定的**，具体包括：

- `coder` 有预置的**弱口令**，且可通过构建参数固化进镜像；
- sshd 启用了 `PasswordAuthentication yes`（`/etc/ssh/sshd_config.d/99-code-server.conf`），口令登录即可进入；
- `coder` 拥有免密 sudo，**一旦口令被猜出就等于拿到 root** —— 禁止 root 直接登录并不改变这一点；
- 同时暴露 SSH 和 HTTP 两个入口。

因此：**不要把它发布到公网，也不要把 22 端口映射到公网可达的地址。**

### 加固清单

按需选择，改动越小越好：

1. **关闭 SSH**：`-e ENABLE_SSH=0`，只用 code-server。
2. **换掉默认密码**：`--build-arg CODER_PASSWORD` 或运行时的 `SSH_USER_PASSWORD`。
3. **只绑本机**：`-p 127.0.0.1:8080:8080 -p 127.0.0.1:2222:22`，避免监听所有网卡。
4. **改用密钥登录**：把 `/etc/ssh/sshd_config.d/99-code-server.conf` 里的 `PasswordAuthentication` 改为 `no`，并在构建期把公钥写入目标用户的 `~/.ssh/authorized_keys`（注意 `authorized_keys` 路径在 `DOCKER_USER` 改名后仍为 `/home/coder/.ssh`）。
5. **收掉免密 sudo**：删除 `Dockerfile` 中写入 `/etc/sudoers.d/nopasswd` 的那一行（会影响 `entrypoint.sh` 里启动 sshd 的方式，需同步调整）。
6. **恢复 root SSH 登录**（不建议）：把 `/etc/ssh/sshd_config.d/99-code-server.conf` 里的 `PermitRootLogin` 改回 `yes`。镜像同时做了 `passwd -l root`，所以密码登录还需要再执行 `passwd root` 设一个口令；若走密钥登录，则配上 `authorized_keys` 即可，无需口令。

## 日志与排障

| 现象 | 原因与处理 |
|---|---|
| `Conflict. The container name "/code-server" is already in use` | 同名容器已存在。`docker rm -f code-server`，或换 `--name` |
| SSH 提示密码错误 | 检查 `-e` 是否写在了镜像名之前；未生效时用的是构建期默认密码 `coder` |
| 以 `root` 登录被拒绝 | 预期行为。改用 `coder` 登录后 `sudo -i` |
| `exec: "/usr/bin/entrypoint.sh": permission denied` | 构建上下文没有可执行位。`Dockerfile` 中已有 `chmod +x`，若改动过请勿删除该行 |
| 提示符前出现 `08;start=...;machineid=...;type=shell;cwd=...` | Ubuntu 26.04 的 systemd OSC 3008 shell 集成。`Dockerfile` 已通过删除 `/etc/profile.d/80-systemd-osc-context.sh` 并屏蔽对应 tmpfiles 规则关闭 |
| 8080 无法访问但 SSH 正常 | sshd 在 `exec code-server` 之前启动。查 `docker logs code-server` 确认 code-server 自身的报错（常见于误传了命令行参数） |

sshd 的日志在独立文件里，不进容器日志：

```bash
docker exec code-server tail -f /var/log/sshd.log
```

登录失败、连接被拒等信息都在这里。code-server 自身的输出仍走 `docker logs`。

## 与上游镜像的差异

除新增 SSH 外，为能在本仓库直接构建做了两处调整：

- `COPY entrypoint.sh`：上游为 `COPY ci/release-image/entrypoint.sh`，本仓库没有 `ci/` 目录，文件在根目录。
- 禁止 root 通过 SSH 登录（`PermitRootLogin no` 加 `passwd -l root`），登录一律走 `coder`。
- 新增 `.gitattributes`，强制 `*.sh` 与 `Dockerfile` 使用 LF 换行 —— Windows 上 checkout 出 CRLF 会破坏 shebang 和 Dockerfile 的续行。
