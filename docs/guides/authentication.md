# 身份认证

Producer 使用 `Credentials` 保存访问密钥和可选的 STS token。SDK 在签名请求时使用凭证，
不会主动获取、续期或持久化凭证。

## 推荐方式

移动端和桌面客户端推荐从业务服务获取短期 STS 凭证：

```swift
let credentials = Credentials(
    accessKeyID: sts.accessKeyID,
    accessKeySecret: sts.accessKeySecret,
    securityToken: sts.securityToken
)

let producer = try await Producer.open(
    configuration: configuration,
    credentials: credentials,
    onSendResult: handleSendResult
)
```

App 源码、资源文件、`UserDefaults`、日志或崩溃信息中保存长期 AK/SK 会扩大凭据泄漏面。

## 刷新临时凭证

业务层可记录临时凭证过期时间，并在过期前获取新凭证。获取成功后通过以下方式原子替换整组凭证：

```swift
let refreshed = Credentials(
    accessKeyID: response.accessKeyID,
    accessKeySecret: response.accessKeySecret,
    securityToken: response.securityToken
)

try producer.updateCredentials(refreshed)
```

`updateCredentials` 以 AK、SK 和 token 为整组更新单位；分开维护这些字段会产生不一致，更新失败时
SDK 保留旧凭证。

在凭证有效期剩余一段安全窗口时刷新，并为获取凭证的业务请求设置独立重试，有助于降低过期
窗口。SDK 不会代替业务层访问身份服务。

## 凭证过期时的数据处理

`unauthorizedPolicy` 决定收到明确的 401/403 响应后如何处理待发送数据：

| 策略 | 行为 | 适用场景 |
|---|---|---|
| `.retain` | 保留数据，等待 `updateCredentials` 后继续发送 | 默认；优先保证可恢复性 |
| `.drop` | 收到未授权响应后丢弃对应数据 | 数据过期价值低，且不希望持续占用缓冲区 |

使用 `.retain` 时，凭证长期无法刷新可能使内存缓冲或 WAL 持续增长。业务层可监控
`ProducerError.auth`、缓冲区拒绝和凭证刷新结果。

## 错误处理

- `Producer.open` 或 `updateCredentials` 收到空字段、换行或 NUL 字符时抛出
  `ProducerError.configuration`。
- 远端明确拒绝认证时，批次结果为 `ProducerError.auth`。
- DNS、TLS 握手和连接失败属于 `ProducerError.transport`，不能据此判断凭证无效。

## 安全要求

- 仅使用 HTTPS endpoint。
- `Credentials` 的字段不写入输出或错误文本；这些字段会暴露凭据。
- 自定义 `URLProtocol`、网络调试代理或自定义日志记录 Authorization 头会暴露凭据。
- 凭证更新完成后释放不再需要的旧凭证副本，可减少敏感数据驻留时间。
- 服务端查询或消费凭证应与写入凭证按最小权限原则分别管理。

完整错误处理见 [API 与错误码](../reference/api-and-errors.md)。
