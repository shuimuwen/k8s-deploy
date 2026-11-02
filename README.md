# 前后端 Kubernetes 多环境配置

业务源码： [backend](https://github.com/shuimuwen/backend) / [frontend](https://github.com/shuimuwen/frontend)。
本仓库只管理部署 YAML，不存放业务源码、镜像、kubeconfig 或明文凭据。

## 文件与环境

| 文件 | 用途 |
| --- | --- |
| dev.yaml | 开发环境，命名空间 login-demo-dev |
| prod.yaml | 生产环境配置，命名空间 login-demo-prod |
| deploy.sh | 指定环境及集群 context，检查镜像和依赖后发布 |

每个环境包含 Namespace、前端运行时 ConfigMap、前后端各一个 Deployment 和 Service。
前端监听 8080；同域 /api/ 请求经 Nginx 原路径代理到 backend:8000。
后端 /health、前端 /healthz 用于探针。Service 为 ClusterIP，暂不假定域名和入口控制器。

dev 前后端各 1 副本；prod 前端 2 副本、后端 1 副本。两个环境使用独立命名空间；实际生产建议使用独立集群。
当前后端使用内存会话，因此采用 Recreate 单副本更新，重启/更新会中断并丢失登录。prod 配置不表示模拟登录已达到真实生产认证要求。

## 第一次部署前必须完成

1. 将两个业务项目构建为可拉取的容器镜像。本仓库不会自动构建源码或产生镜像。
2. 后端镜像应包含 Python 服务，尊重 HOST=0.0.0.0 和 PORT=8000；前端镜像应包含 Nginx 和静态页面，页面位于 /usr/share/nginx/html。
3. 镜像需兼容 UID/GID 10001、只读根文件系统；前端启动命令应为 `nginx -g 'daemon off;'`，临时文件使用挂载的 /tmp/nginx，避免依赖启动时修改 /etc 的初始化脚本。
4. 将对应 YAML 中两处 `image: ghcr.io/shuimuwen/...:SET_ME` 替换成实际镜像引用，例如 `image: ghcr.io/shuimuwen/backend@sha256:<实际64位摘要>`。尖括号示例不能直接部署。
5. 准备集群 kubeconfig，并在对应命名空间创建 registry-pull 镜像拉取 Secret。

镜像可以来自 GHCR、GitLab Registry 或 Harbor，只需使用真实地址并配置对应只读拉取凭据。

## 初始化命名空间与凭据

选择明确的 context，不依赖默认当前集群：

```bash
kubectl config get-contexts
read -r -p '目标 Kubernetes context: ' KUBE_CONTEXT
kubectl --context "$KUBE_CONTEXT" create namespace login-demo-dev
```

命名空间已存在时跳过 create。生产环境换成 login-demo-prod。
先用专用只读镜像凭据生成 Docker 配置文件，再创建 Secret，避免将密码放入 Git：

```bash
read -r -p '已有只读镜像凭据 Docker config.json 的绝对路径: ' REGISTRY_CONFIG
kubectl --context "$KUBE_CONTEXT" -n login-demo-dev create secret generic registry-pull \
  --type=kubernetes.io/dockerconfigjson \
  --from-file=.dockerconfigjson="$REGISTRY_CONFIG"
```

配置文件必须含真实 Registry 的 auths/auth 值，不能仅依赖本机 Docker credential helper；凭据需要能读取前后端两个镜像。不要提交该文件。生产环境重复创建独立 Secret。

## 发布与验收

替换真实镜像并提交 Git 后执行：

```bash
bash deploy.sh dev "$KUBE_CONTEXT" --dry-run
bash deploy.sh dev "$KUBE_CONTEXT"
kubectl --context "$KUBE_CONTEXT" -n login-demo-dev port-forward service/frontend 18080:8080
```

浏览器打开 http://127.0.0.1:18080，验证 demo/demo123 登录、错误密码提示、退出。
部署脚本检查服务就绪，不代替业务验收；当前仓库没有自动连接集群或配置 CI 凭据。

## 从 dev 晋级 prod

- dev 验收通过后，将同一组前后端镜像 digest 写入 prod.yaml，不重新构建镜像。
- 创建并审核 PR，确认生产 context 和 registry-pull Secret。
- 执行 `bash deploy.sh prod "$KUBE_CONTEXT" --dry-run`，通过后再去掉 --dry-run 发布。
- CI 后续可以仅更新 dev.yaml 中对应服务的 image 并提交 PR；生产版本由验收和审批决定。

## 回滚与配置修改

将目标环境 YAML 恢复为上一次成功提交并审核，然后重新执行 deploy.sh。
前端运行时配置通过 ConfigMap subPath 挂载，修改后必须重启前端 Pod，deploy.sh 已包含该步骤。
当前应用无数据库；未来有数据库迁移时，需另行设计数据恢复与版本兼容。

本仓库初始镜像是明确的 SET_ME 占位符。已校验 YAML 结构和环境隔离，尚未执行实际集群部署。
