# 前后端 Kubernetes 多环境配置

业务源码：[backend](https://github.com/shuimuwen/backend) / [frontend](https://github.com/shuimuwen/frontend)。本仓库只管理部署配置，不存放业务源码、镜像、kubeconfig 或凭据。

## 目录：公共配置只维护一次

```text
base/
  kustomization.yaml
  backend-deployment.yaml
  backend-service.yaml
  frontend-deployment.yaml
  frontend-service.yaml
  nginx.conf
  config.js
overlays/
  dev/
    kustomization.yaml
    namespace.yaml
  prod/
    kustomization.yaml
    namespace.yaml
deploy.sh
```

base 维护两个 Deployment、两个 Service、公共探针、容器安全设置、前端配置与反向代理。overlays 只记录命名空间、镜像版本、APP_ENV 和相对 base 的资源/副本差异。原来重复的 dev.yaml、prod.yaml 已移除，使用 Kustomize 渲染完整 YAML。

| 配置 | dev | prod |
| --- | --- | --- |
| 命名空间 | login-demo-dev | login-demo-prod |
| APP_ENV | dev | prod |
| 前端副本 | 继承 base：1 | 覆盖：2 |
| 后端副本 | 继承 base：1 | 继承 base：1 |
| 容器资源上限 | 继承 base：500m / 256Mi | 覆盖：1000m / 512Mi |
| 镜像版本 | overlays/dev/kustomization.yaml | overlays/prod/kustomization.yaml |

前端监听 8080，同域 /api/ 由 Nginx 保留路径代理到 backend:8000。Service 为 ClusterIP，域名和 Ingress 按集群情况加入对应 overlay。
当前后端使用内存会话，保持单副本和 Recreate；更新或重启会中断并丢失登录。prod 配置不代表模拟登录已满足真实生产认证要求。

## 渲染检查（不连接集群）

kubectl 自带 Kustomize：

```bash
kubectl kustomize overlays/dev
kubectl kustomize overlays/prod
```

不要直接部署 base，因为镜像、命名空间与环境参数由 overlay 提供。公共变更修改 base；只有确实不同的字段才放 overlay，不复制完整 Deployment。

## 配置真实镜像

两个业务项目需先构建为可拉取镜像。后端包含 Python 服务，监听 HOST=0.0.0.0/PORT=8000；前端包含 Nginx 和静态页面，页面目录为 /usr/share/nginx/html。
镜像需兼容 UID/GID 10001 和只读根文件系统。前端直接执行 `nginx -g 'daemon off;'`，临时目录使用挂载的 /tmp/nginx，不依赖启动时改写 /etc 的初始化脚本。

在目标 overlay 的 images 中，将 `newTag: SET_ME` 替换为 `digest: sha256:<实际64位摘要>`，并填写真实 newName；不要同时保留占位 newTag：

```yaml
images:
  - name: backend
    newName: ghcr.io/shuimuwen/backend
    digest: sha256:<实际64位摘要>
  - name: frontend
    newName: ghcr.io/shuimuwen/frontend
    digest: sha256:<实际64位摘要>
```

name 是 base 内的匹配名，不要更改。newName 可以来自 GHCR、GitLab Registry 或 Harbor。
CI 只修改 overlays/dev/kustomization.yaml 中对应组件的 newName/digest，提交 PR；不要顺带改 prod。
初始 SET_ME 不是真实镜像，脚本会拒绝发布，直到两个镜像都固定到 digest。

## 初始化命名空间和拉取凭据

```bash
kubectl config get-contexts
read -r -p '目标 Kubernetes context: ' KUBE_CONTEXT
kubectl --context "$KUBE_CONTEXT" apply -f overlays/dev/namespace.yaml
```

生产换为 overlays/prod/namespace.yaml。两个环境可以使用不同集群，脚本要求明确 context。
准备能读取两个镜像的只读 Docker 配置文件，再创建 Secret：

```bash
read -r -p '只读镜像凭据 config.json 绝对路径: ' REGISTRY_CONFIG
kubectl --context "$KUBE_CONTEXT" -n login-demo-dev create secret generic registry-pull \
  --type=kubernetes.io/dockerconfigjson \
  --from-file=.dockerconfigjson="$REGISTRY_CONFIG"
```

配置文件应包含 Registry 的 auths/auth，不能只引用本机 credential helper；不要提交到 Git。生产在 login-demo-prod 创建独立 Secret。

## 发布和验收

替换镜像并审核提交后：

```bash
bash deploy.sh dev "$KUBE_CONTEXT" --dry-run
bash deploy.sh dev "$KUBE_CONTEXT"
kubectl --context "$KUBE_CONTEXT" -n login-demo-dev port-forward service/frontend 18080:8080
```

脚本依次渲染 overlay、检查镜像 digest/命名空间/Secret、server dry-run、apply、检查 rollout。未自动连接或部署任何集群。
浏览器打开 http://127.0.0.1:18080 ，验证 demo/demo123 登录、错误密码和退出；服务就绪不能代替业务验收。
完成前提检查后也可使用：

```bash
kubectl --context "$KUBE_CONTEXT" apply -k overlays/dev
kubectl --context "$KUBE_CONTEXT" apply -k overlays/prod
```

## 晋级、回滚和公共配置变更

- dev 验收后，将相同镜像 digest 更新到 prod overlay，审核后发布，不重新构建。
- 回滚时恢复对应 overlay；如果 base 也有变更，恢复与该次成功发布一致的 base，再发布。
- base 变更会影响两套配置。分阶段部署时，应分别选定已审核的 Git 提交；使用 Argo CD 时分别固定到对应提交，避免两个环境同时追踪 main 自动更新。
- ConfigMap 由 configMapGenerator 生成并保留内容 hash，配置变更会自动更新引用及 Pod 模板、触发滚动更新，因此部署脚本无需每次强制重启前端。
- 不要关闭 ConfigMap hash。kubectl apply 不会自动清理旧 ConfigMap；确认没有旧 Pod 引用后按运维流程清理，避免跨命名空间批量 prune。

已完成 dev/prod Kustomize 渲染及重构前资源等价检查，未在真实集群部署。
