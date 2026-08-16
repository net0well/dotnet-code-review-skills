# Auditoria técnica — partes de segurança

**Data:** 2026-08-14
**Auditor:** especialista em segurança .NET (revisão de corretude técnica de documento, não de código)

## Escopo auditado

| Arquivo | Seções |
|---|---|
| `dotnet-code-review\designpatterns\references\dotnet-moderno.md` | Segurança; Erros na borda HTTP; Configuração e segredos; Logging e observabilidade (+ itens de segurança que vazaram para "Minimal APIs e ASP.NET Core" e "Entity Framework Core") |
| `dotnet-code-review\designpatterns-legacy\references\smells-legado.md` | Segurança; Exceções |

Nenhum arquivo auditado foi alterado.

## Resumo executivo — os 8 achados mais graves

1. **(c) XSS e output encoding não existem em nenhum dos dois documentos.** É a categoria OWASP mais frequente em code review real de ASP.NET, e a skill não tem nem uma linha sobre `Html.Raw`, `<%= %>`, `MarkupString` ou CSP. O documento legado usa `validateRequest="false"` como proxy de XSS — proxy fraco e bypassável.
2. **(c) Autorização vertical e multi-tenancy ausentes.** `[Authorize]` sem policy em operação administrativa, e leitura de identidade a partir de input do cliente (`X-User-Id`, `dto.UsuarioId`) em vez de `User.FindFirst(...)`, são bypass direto de authz e não estão catalogados.
3. **(c) JWT mal validado ausente por completo** no documento moderno (`ValidateIssuer/Audience/Lifetime = false`, audience confusion, `SignatureValidator` sobrescrito). É 🔴 e é o defeito de auth mais comum em API .NET moderna.
4. **(a/b) CORS: o mecanismo descrito está impreciso e o item aponta para a variante inexplorável.** `AllowAnyOrigin() + AllowCredentials()` gera `ACAO: *` com `ACAC: true`, e o **navegador rejeita** — falha fechada. A variante explorável (`SetIsOriginAllowed(_ => true) + AllowCredentials()`, reflexão de `Origin`) não está no documento.
5. **(a) `enableViewStateMac="false"` está desatualizado desde .NET Framework 4.5.2**: o runtime ignora o valor e sempre aplica MAC. O 🔴 real hoje é `<machineKey>` fixo/versionado (forja de ViewState = RCE) e ausência de `ViewStateUserKey`.
6. **(a) "senha ou connection string em `web.config` versionado *sem criptografia*"** — o qualificador está errado. Criptografar a seção com `aspnet_regiis -pe` e versionar continua sendo segredo versionado. O defeito é versionar.
7. **(c) SSRF, path traversal em upload, mass assignment, timing attack e ReDoS ausentes** nos dois documentos. Upload só tem "validação de tamanho 🟠", que é a preocupação menos grave do tema.
8. **(b) Rate limiting em 🟡 é subavaliado.** Em endpoint de autenticação/OTP/reset de senha, ausência de rate limit + lockout é 🔴 (credential stuffing, enumeração, amplificação de custo em SMS/e-mail).

---

# (a) Erros factuais e afirmações desatualizadas

## A1 — 🔴 CORS: mecanismo descrito de forma imprecisa

**Item auditado** (`dotnet-moderno.md`, Minimal APIs): `CORS com AllowAnyOrigin mais AllowCredentials | 🔴 (combinação inválida e insegura)`

**Veredito:** parcialmente correto, mecanismo impreciso, e aponta para a variante que **não** é explorável.

O que acontece de fato no ASP.NET Core 2.2+ (portanto em .NET 8/10): a política emite `Access-Control-Allow-Origin: *` junto de `Access-Control-Allow-Credentials: true`. Isso é uma resposta CORS **inválida pela spec**, e o navegador descarta a resposta. Ou seja: a requisição credenciada cross-origin simplesmente **falha** — é um defeito funcional que falha fechado, não um vazamento silencioso em produção. (Antes do 2.2 o comportamento era refletir a origem, que era de fato perigoso.)

A variante realmente explorável, que passa pelo navegador e não é detectada por nada, é a **reflexão de origem com credenciais**:

```csharp
// 🔴 explorável: reflete qualquer origem e ainda permite credenciais
policy.SetIsOriginAllowed(_ => true).AllowCredentials();

// 🔴 igualmente explorável: middleware manual
ctx.Response.Headers.AccessControlAllowOrigin = ctx.Request.Headers.Origin;
ctx.Response.Headers.AccessControlAllowCredentials = "true";

// 🟠 pattern excessivamente amplo
policy.WithOrigins("https://*.exemplo.com").SetIsOriginAllowedToAllowWildcardSubdomains()
```

**Correção sugerida para o documento** — trocar a linha por duas:

| Sinal | Gravidade |
|---|---|
| `SetIsOriginAllowed(_ => true)` ou reflexão do header `Origin` junto de `AllowCredentials` | 🔴 (qualquer site lê resposta autenticada do usuário) |
| `AllowAnyOrigin` mais `AllowCredentials` | 🟠 (resposta CORS inválida: o navegador rejeita; a política credenciada nunca funciona) |

Vale acrescentar a nota de que CORS **não é controle de autorização**: `AllowAnyOrigin` numa API pública sem credenciais não é vulnerabilidade, é decisão de design.

Fonte: [Enable CORS in ASP.NET Core — Set the allowed origins](https://learn.microsoft.com/aspnet/core/security/cors#set-the-allowed-origins); [Migrate 2.1 to 2.2 — Update CORS policy](https://learn.microsoft.com/aspnet/core/migration/21-to-22#update-cors-policy).

## A2 — 🔴 `enableViewStateMac="false"` está desatualizado

**Item auditado** (`smells-legado.md`, Segurança): `ViewState sem MAC ou com enableViewStateMac="false" | 🔴`

**Veredito:** desatualizado. Desde o .NET Framework 4.5.2 (e desde o update KB2905247 / Security Advisory 2905247 para 4.0/4.5/4.5.1), **o runtime ignora `enableViewStateMac="false"`** e aplica MAC em todas as requisições com ViewState embutido. Em qualquer `net4x` realista (4.7.2/4.8) o ajuste é inócuo. Manter isso como 🔴 gera achado falso.

**O que deveria ocupar esse 🔴 no legado:**

| Sinal | Gravidade | Por quê |
|---|---|---|
| `<machineKey>` com `validationKey`/`decryptionKey` fixos e versionados (ou publicados junto do deploy) | 🔴 | Com a chave, o atacante forja ViewState e ticket de Forms Auth. ViewState forjado é desserialização de `ObjectStateFormatter` = RCE (ysoserial.net/Blacklist3r). Também permite forjar cookie de autenticação. |
| `<machineKey validation="MD5">` ou `validation="SHA1"` | 🟠 | Usar `HMACSHA256`, `decryption="AES"` |
| `ViewStateUserKey` não definido em página com POST autenticado (Web Forms) | 🟠 | É o mecanismo anti-CSRF do Web Forms (`Page_Init`: `ViewStateUserKey = Session.SessionID`) |
| `ViewStateEncryptionMode` não `Always` quando ViewState carrega dado sensível | 🟠 | MAC garante integridade, não confidencialidade — ViewState é Base64 legível |
| `enableViewStateMac="false"` presente no config | 🟡 | Ignorado pelo runtime desde 4.5.2. Aponte como limpeza/sinal de tentativa antiga de contornar erro de MAC em web farm, não como vulnerabilidade ativa |

Nota importante de contexto para o revisor: o motivo pelo qual times fixam `<machineKey>` é web farm (nós diferentes precisam da mesma chave). A recomendação tem que vir emparelhada — **compartilhe a chave entre os nós sem versioná-la** (`configSource` fora do repo, variável de deploy, ou seção protegida gerada na máquina), senão o conselho é impraticável e será ignorado.

Fonte: [Runtime changes 4.5.x — "No longer able to set EnableViewStateMac to false"](https://learn.microsoft.com/dotnet/framework/migration-guide/runtime/4.5.x); [Security Advisory 2905247](https://learn.microsoft.com/security-updates/securityadvisories/2013/2905247); [What not to do in ASP.NET](https://learn.microsoft.com/aspnet/aspnet/overview/web-development-best-practices/what-not-to-do-in-aspnet-and-what-to-do-instead#security).

## A3 — 🔴 "sem criptografia" está logicamente errado

**Item auditado** (`smells-legado.md`): `Senha ou connection string em web.config versionado sem criptografia | 🔴`

**Veredito:** erro de enquadramento. O qualificador "sem criptografia" implica que criptografar a seção resolve. Não resolve: `aspnet_regiis -pe` (DPAPI ou provider RSA) protege o arquivo **na máquina**, contra leitura local por quem não tem a chave/container. Um `web.config` com seção `connectionStrings` criptografada e **versionado** continua sendo um segredo no histórico do Git, e quem tiver acesso à máquina de deploy (ou ao container RSA exportado) decripta.

**Correção sugerida:** `Senha, connection string ou chave em web.config/app.config versionado | 🔴 — remover do repositório e do histórico; injetar no deploy (transform, variável de ambiente, configSource fora do repo, Key Vault). aspnet_regiis -pe protege o arquivo na máquina, não o segredo no histórico. Rotacione o segredo que já foi commitado — ele deve ser considerado vazado.`

O ponto "rotacione, porque já vazou" está ausente nos dois documentos e é o que realmente muda o resultado de um review.

## A4 — 🟠 `validateRequest="false"` tratado como controle de XSS

**Item auditado** (`smells-legado.md`): `validateRequest="false" sem sanitização | 🔴` e `requestValidationMode reduzido para contornar erro | 🟠`

**Veredito:** tecnicamente defensável, conceitualmente enganoso. ASP.NET Request Validation é uma **blocklist coarse de defesa em profundidade** (dispara em `<` seguido de letra, `&#`, etc.), trivialmente contornável em contexto de atributo, contexto JS, e irrelevante para DOM XSS e stored XSS que entra por outro canal (importação, integração, banco). Marcar sua ausência como 🔴 **e não ter nenhum item sobre encoding de saída** ensina o controle errado: o revisor vai aprovar código com `@Html.Raw(Model.ComentarioDoUsuario)` desde que `validateRequest` esteja `true`.

Os dois itens também são inconsistentes entre si (🔴 vs 🟠) sendo o mesmo defeito — desligar a mesma proteção de defesa em profundidade.

**Correção sugerida:** nivelar ambos em 🟠 ("defesa em profundidade desligada — exige que o encoding de saída esteja comprovadamente correto no fluxo afetado") e criar o item 🔴 que falta, de XSS por sink real (ver C1). Acrescentar as correções viáveis e específicas de `net4x`:

- Escopo mínimo em vez de global: `[AllowHtml]` na propriedade (MVC 5), ou `validateRequest="false"` **por página**, em vez de `requestValidationMode="2.0"` no app inteiro.
- Sanitização de HTML que realmente precisa ser HTML: `HtmlSanitizer` (Ganss.XSS) ou AntiXSS.
- Encoder mais rigoroso em todo o app (net4x, uma linha): `<httpRuntime encoderType="System.Web.Security.AntiXss.AntiXssEncoder, System.Web" />`.

## A5 — 🟠 Hash de senha: recomendação incompleta e não portável entre os dois documentos

**Itens auditados:** moderno `Senha com hash próprio ou MD5/SHA1 | 🔴 (use IPasswordHasher, Argon2, bcrypt)`; legado `Senha com MD5, SHA1, ou hash sem salt | 🔴` (sem correção).

**Veredito:** direção correta, três imprecisões.

1. **O gatilho é estreito demais.** "MD5/SHA1" não pega `SHA256.HashData(senha)`, `SHA512(senha + salt)`, `HMACSHA256` com chave fixa, nem `Rfc2898DeriveBytes` com 1.000 iterações. Todos são igualmente quebrados para senha — o defeito é **hash rápido de propósito geral**, com ou sem salt, não a família do algoritmo. Um revisor seguindo a tabela literalmente aprova `SHA512 + salt`.
   **Reescrita sugerida:** `Senha com hash de propósito geral (MD5, SHA1, SHA256, SHA512, HMAC) ou com KDF de iteração baixa | 🔴`.
2. **`IPasswordHasher<TUser>` não é resposta equivalente nas duas plataformas.** No ASP.NET Core, `PasswordHasher<TUser>` em `IdentityV3` é PBKDF2-HMAC-SHA256 com `IterationCount` default **100.000** — aceitável. Mas: (i) se o app fixou `CompatibilityMode = IdentityV2`, cai para PBKDF2-HMAC-SHA1 com 1.000 iterações, e isso é 🔴 mesmo usando "a API certa"; (ii) no `net4x`, o análogo natural (`Microsoft.AspNet.Identity` / `System.Web.Helpers.Crypto.HashPassword`) é PBKDF2-**SHA1** com **1.000** iterações — muito abaixo do aceitável hoje. Recomendar "use `IPasswordHasher`" no documento legado levaria o autor exatamente para o hash fraco. Ver D1 para o caminho viável em `net4x`.
3. **Ordem de preferência.** Baseline OWASP atual: Argon2id (m≈19 MiB, t=2, p=1) → scrypt → bcrypt (cost ≥ 10) → PBKDF2-HMAC-SHA256 com ~600.000 iterações. Ou seja, o default do Identity (100k) é **abaixo** do baseline OWASP para PBKDF2-SHA256, e vale a nota "aceitável, mas se você pode escolher, prefira Argon2id". Nota prática que falta: **bcrypt trunca a senha em 72 bytes** — relevante quando o time aceita passphrase longa.

Fonte: [PasswordHasherOptions.IterationCount — "Default is 100,000"](https://learn.microsoft.com/dotnet/api/microsoft.aspnetcore.identity.passwordhasheroptions.iterationcount); [Configure ASP.NET Core Identity — Password Hasher options](https://learn.microsoft.com/aspnet/core/security/authentication/identity-configuration#password-hasher-options).

## A6 — 🟠 SQL injection: os dois itens do documento moderno se contradizem na leitura

**Itens auditados:** Segurança: `SQL concatenado ou interpolado sem parâmetro | 🔴`; EF Core: `SQL concatenado com interpolação em FromSqlRaw | 🔴 → FromSql com interpolação parametrizada`.

**Veredito:** individualmente corretos, juntos confusos. Lidos em sequência, "interpolado é 🔴" e "use interpolação parametrizada" parecem se contradizer. O fato preciso: `FromSql`/`FromSqlInterpolated`/`ExecuteSql` recebem `FormattableString` e **parametrizam** os holes; `FromSqlRaw`/`ExecuteSqlRaw`/`SqlQueryRaw` recebem `string` e a interpolação acontece **antes** da chamada — é aí que está a injeção. Vale explicitar isso em uma linha, porque é a confusão mais comum do tema em EF Core.

**Duas lacunas factuais relevantes no mesmo item:**

- **Parâmetro não protege identificador.** `ORDER BY {coluna}`, nome de tabela, `TOP {n}` e cláusula dinâmica não são parametrizáveis. A correção é allowlist (`switch` sobre valores conhecidos), não `SqlParameter`. Isso é fonte real de injeção em código que "usa parâmetros em tudo". Falta nos dois documentos.
- **`LIKE` com entrada do usuário** precisa escapar `%` e `_` — sem isso há tanto resultado incorreto quanto DoS de tabela cheia.

## A7 — 🟢 Itens verificados e corretos (sem ressalva)

Para registro, foram checados e estão factualmente corretos:

- `BinaryFormatter` desserializando dado externo = 🔴 RCE (legado). Correto e ainda vigente em `net4x`, onde `BinaryFormatter` funciona normalmente. Complemento útil: em .NET 5+ é obsoleto (`SYSLIB0011`) e lança em apps ASP.NET Core; a implementação in-box foi **removida no .NET 9** e sempre lança `PlatformNotSupportedException` — mas existe pacote de compatibilidade não suportado que reintroduz o risco, e vale citar como sinal 🔴 no documento moderno. ([removal](https://learn.microsoft.com/dotnet/core/compatibility/serialization/9.0/binaryformatter-removal))
- Cookie de autenticação sem `HttpOnly`/`Secure` = 🔴. Correto (ver D2 para viabilidade e para o `SameSite` que falta).
- Redirecionamento aberto = 🔴. Correto (mas ausente no documento moderno — ver C7).
- `<customErrors mode="Off" />` em produção = 🔴. Correto (ver D4).
- `ServicePointManager.SecurityProtocol = Ssl3` = 🔴. Correto (mas sem correção viável — ver D5).
- Ausência de anti-forgery em POST = 🔴. Correto para app com cookie/Forms Auth (ver D3 para nuance de Web API e Web Forms).
- IDOR = 🔴 nos dois documentos. Correto (ver B6 e C2 para o que falta de mecanismo).
- `catch (Exception ex) { throw ex; }` reseta stack trace = 🟠. Correto.
- `catch (ThreadAbortException)` como sintoma de `Response.End` = 🟡. Correto — e o documento acerta ao não afirmar que a exceção é engolida (em `net4x` ela é relançada automaticamente ao fim do `catch`, salvo `Thread.ResetAbort()`).
- `ProblemDetails` = RFC 9457 e `IExceptionHandler` a partir do .NET 8. Correto.

---

# (b) Severidade mal atribuída

| # | Item | Doc | Atual | Sugerido | Justificativa |
|---|---|---|---|---|---|
| B1 | Ausência de rate limiting em endpoint público de escrita | moderno | 🟡 | 🟠 geral / **🔴 em endpoint de autenticação, OTP, reset de senha, envio de e-mail/SMS** | Credential stuffing, enumeração de usuário e amplificação de custo. Em .NET 8+ não há desculpa de esforço: `AddRateLimiter` é nativo. Emparelhar com lockout do Identity (`MaxFailedAccessAttempts`) |
| B2 | Mensagem de erro detalhada para o cliente | moderno | 🟠 | 🔴 quando é stack trace / `UseDeveloperExceptionPage` em produção / `detail = ex.Message`; 🟠 quando é só mensagem de negócio verbosa | Hoje está 🟠 no moderno e 🔴 no legado ("Detalhe da exceção exibido na tela") para o **mesmo risco**. Inconsistência entre os dois documentos da mesma skill |
| B3 | Ordem de middleware errada (autorização antes de autenticação) | moderno | 🔴 | 🟠 | Falha **fechada** no ASP.NET Core moderno: policy sem esquema explícito avalia `context.User` vazio e devolve 401 para todo mundo; e `[Authorize]` sem `UseAuthorization()` lança na primeira requisição. É bug funcional ruidoso, detectado pelo primeiro teste. O 🔴 deve ir para as ordens que falham **abertas**: middleware próprio que lê `HttpContext.User` antes de `UseAuthentication`, `UseCors` mal posicionado, `UseStaticFiles` servindo conteúdo privado antes da autenticação |
| B4 | `AllowAnyOrigin` + `AllowCredentials` | moderno | 🔴 | 🟠 (e criar 🔴 para reflexão de origem) | Ver A1: o navegador rejeita; falha fechada |
| B5 | `validateRequest="false"` 🔴 vs `requestValidationMode` reduzido 🟠 | legado | 🔴 / 🟠 | 🟠 / 🟠 | Mesmo defeito (defesa em profundidade desligada), severidades divergentes. O 🔴 do tema pertence ao sink de XSS, que não existe no documento |
| B6 | `ViewState sem MAC` / `enableViewStateMac="false"` | legado | 🔴 | 🟡 (e criar 🔴 para `<machineKey>` fixo/versionado) | Ver A2: ignorado pelo runtime desde 4.5.2 |
| B7 | Endpoint de escrita sem `RequireAuthorization` | moderno | 🔴 | 🔴 (manter) mas **ampliar escopo** | Escopo estreito demais: endpoint de **leitura** anônimo que devolve dado pessoal é exfiltração em massa, igual ou pior. Incluir `[AllowAnonymous]`/`.AllowAnonymous()` sobrepondo fallback policy, e recomendar `SetFallbackPolicy(RequireAuthenticatedUser)` como correção sistêmica em vez de item-por-item |
| B8 | Autorização por role hardcoded espalhada | moderno | 🟠 | 🟠 (manter) — mas falta o irmão 🔴 | Como está, o documento só tem o aspecto de manutenibilidade. Falta `[Authorize]`/`RequireAuthorization()` **sem policy** em operação administrativa: qualquer usuário autenticado (inclusive self-service) executa ação de admin. Isso é 🔴 (authz vertical) |
| B9 | Ausência de validação de tamanho em upload | moderno | 🟠 | 🟠 (manter para DoS) — mas falta o 🔴 do tema | O risco grave de upload não é tamanho, é caminho e tipo (ver C4) |
| B10 | Deserialização de tipo arbitrário | moderno | 🔴 | 🔴 (manter) — gatilho vago | "Tipo arbitrário" não diz ao revisor o que procurar. Nomear os sinais: `TypeNameHandling` no Newtonsoft, `BinaryFormatter`/`NetDataContractSerializer`/`LosFormatter`/`SoapFormatter`, `JavaScriptSerializer` com `SimpleTypeResolver`, `Type.GetType(input)`, `XmlSerializer` construído a partir de tipo vindo de input |
| B11 | Log de dado sensível | moderno | 🔴 | 🔴 (manter) — falta o sinal mais comum | `EnableSensitiveDataLogging()` do EF Core em produção loga **valores de parâmetro** (senha, CPF, cartão). É 🔴 e é o vetor real, muito mais comum que `LogInformation(senha)` |
| B12 | `catch { }` vazio | legado | 🔴 | 🔴 (manter) — acrescentar o ângulo de segurança | Falta dizer que `catch` vazio em caminho de **verificação** (validação de assinatura, checagem de permissão, verificação de token, decriptação) converte fail-closed em fail-open. Não é só perda de diagnóstico |

---

# (c) Lacunas críticas

Ordenadas por probabilidade de aparecer num code review profissional. Linhas prontas para colar nas tabelas existentes.

## C1 — XSS e encoding de saída (a maior lacuna dos dois documentos)

Nenhum dos dois documentos tem um único item sobre o sink de XSS. Isso é a lacuna mais grave da auditoria.

**Moderno:**

| Sinal | Gravidade |
|---|---|
| `@Html.Raw(...)`, `HtmlString`/`MarkupString` com dado que passou por input do usuário | 🔴 |
| `(MarkupString)` em Blazor com conteúdo vindo do banco/API | 🔴 |
| Dado do usuário injetado em bloco `<script>` sem `JavaScriptEncoder` (`JsonSerializer.Serialize` com encoder default dentro de HTML) | 🔴 |
| `Results.Content(html, "text/html")` / `Text(...)` montando HTML por concatenação | 🔴 |
| Ausência de Content-Security-Policy em app que renderiza HTML | 🟠 (defesa em profundidade; exigir `default-src 'self'`, sem `unsafe-inline`, e nonce nos scripts) |
| `ServeUnknownFileTypes = true` em `UseStaticFiles` sobre diretório com upload | 🔴 (stored XSS servindo HTML enviado pelo usuário) |
| `UseDirectoryBrowser` habilitado | 🟠 |

**Legado:**

| Sinal | Gravidade |
|---|---|
| `<%= %>` ou `Response.Write` com dado de usuário (em vez de `<%: %>`) | 🔴 |
| `Html.Raw`, `MvcHtmlString.Create` em dado de usuário | 🔴 |
| `Literal.Mode` não `Encode`, ou `Label.Text` recebendo HTML | 🟠 |
| `innerHTML`/`document.write` com valor renderizado pelo servidor | 🔴 |
| `encoderType` não configurado para `AntiXssEncoder` | 🟡 |

## C2 — Autorização vertical e identidade vinda do cliente

| Sinal | Gravidade | Correção |
|---|---|---|
| Id de usuário/tenant lido do body, query ou header (`X-User-Id`, `dto.UsuarioId`) em vez de `User.FindFirst(...)` | 🔴 | Ler sempre do `ClaimsPrincipal`. Se o DTO tem o campo, ele é ignorado ou rejeitado |
| `[Authorize]` / `RequireAuthorization()` sem policy em operação administrativa ou destrutiva | 🔴 | Policy nomeada com requisito específico; `RequireAuthorization("GerenciarUsuarios")` |
| Policy de role dependendo de claim que não foi mapeado (`role` vs `ClaimTypes.Role`) | 🟠 | Falha fechada, mas some silenciosamente em refactor de auth. Testar a policy, não só o endpoint |
| Verificação de propriedade feita **depois** de carregar o recurso, e só num `if` de controller | 🟠 | `IAuthorizationService.AuthorizeAsync(user, recurso, requisito)` com `AuthorizationHandler<TReq, TRes>`, ou filtro no próprio query (`Where(x => x.OwnerId == userId)`) |
| Multi-tenant sem global query filter (`HasQueryFilter`), ou com `IgnoreQueryFilters()` num fluxo de request | 🔴 | Isolamento de tenant no `DbContext`, não em cada query. `IgnoreQueryFilters` só em job administrativo |
| Autorização aplicada no client (esconde o botão) sem checagem no servidor | 🔴 | — |

O documento moderno cita IDOR mas não cita **nenhum** mecanismo de authz do ASP.NET Core além de `RequireAuthorization`. `IAuthorizationService`, `AuthorizationHandler<TRequirement, TResource>` e `SetFallbackPolicy` deveriam estar ali.

## C3 — JWT e tokens (ausente por completo no documento moderno)

| Sinal | Gravidade |
|---|---|
| `ValidateIssuer = false`, `ValidateAudience = false` ou `ValidateLifetime = false` | 🔴 |
| `ValidateIssuerSigningKey = false` ou `SignatureValidator` sobrescrito devolvendo o token sem verificar | 🔴 (aceita token forjado) |
| Aceitar token cuja `aud` é de outra aplicação/tenant (audience confusion) | 🔴 |
| `RequireHttpsMetadata = false` fora de dev | 🟠 |
| Chave simétrica (HS256) hardcoded, curta, ou compartilhada entre ambientes | 🔴 |
| `ClockSkew` aumentado para "resolver" expiração | 🟠 |
| Refresh token guardado em claro, sem rotação e sem revogação | 🟠 |
| Token em query string ou em `localStorage` quando havia cookie `HttpOnly` disponível | 🟠 |
| Comparação de API key / token / HMAC com `==` ou `SequenceEqual` | 🟠 (timing attack — `CryptographicOperations.FixedTimeEquals`) |
| Token/OTP/reset gerado com `new Random()` ou `Guid.NewGuid()` | 🔴 (`RandomNumberGenerator.GetBytes` / `GetHexString`) |

## C4 — Upload: caminho e tipo (o 🔴 que falta)

| Sinal | Gravidade |
|---|---|
| `Path.Combine(pasta, file.FileName)` com `IFormFile.FileName` sem sanitizar | 🔴 (path traversal → escrita arbitrária; e `Path.Combine` **descarta** o prefixo se o segundo argumento for caminho absoluto) |
| Extensão/content-type não validados por allowlist, ou confiança no `ContentType` enviado pelo cliente | 🔴 |
| Arquivo gravado dentro do webroot / diretório servido estaticamente | 🔴 |
| Descompactação de zip iterando `entry.FullName` com `Path.Combine` sem checar o destino canônico | 🔴 (Zip Slip) |
| Ausência de limite de tamanho (`RequestSizeLimit`, `MultipartBodyLengthLimit`, limite do Kestrel/IIS) | 🟠 |

Correção a documentar: nome gerado pelo servidor (`Guid`/hash) + extensão da allowlist; `Path.GetFileName` no nome original só para exibição; validação canônica `Path.GetFullPath(destino).StartsWith(raizCanonica)`; armazenamento fora do webroot ou em blob storage.

Vale um item genérico de **path traversal** também fora de upload: download por `?arquivo=`, `File(caminho)`, `Server.MapPath(Request["f"])`.

## C5 — SSRF (ausente nos dois)

| Sinal | Gravidade |
|---|---|
| `HttpClient` chamando URL derivada de input do usuário (webhook, "importar de URL", proxy de imagem, render de PDF/HTML) | 🔴 |
| `AllowAutoRedirect` habilitado nesse cenário (redirect para host interno) | 🟠 |
| `XmlResolver`/`XmlUrlResolver` ativo resolvendo entidade externa | 🔴 (SSRF + XXE) |

Correção: allowlist de host/esquema, resolução de DNS validada contra faixas privadas e link-local (169.254.169.254 → metadata da cloud), sem seguir redirect, timeout curto, e egress restrito na infra.

## C6 — Mass assignment / over-posting (ausente)

O documento moderno cobre o lado da **saída** ("entidade do EF devolvida direto na resposta 🟠") mas não o lado da **entrada**, que é o mais grave.

| Sinal | Gravidade |
|---|---|
| Entidade de domínio/EF usada como parâmetro de binding do endpoint (`[FromBody] Usuario`) | 🔴 (atacante escreve `IsAdmin`, `Role`, `Saldo`, `TenantId`, ou navegações) |
| `TryUpdateModelAsync`/`SetValues` aplicando o payload inteiro na entidade rastreada | 🔴 |
| `AutoMapper` mapeando DTO → entidade com `ForAllMembers` sem restringir campos sensíveis | 🟠 |
| DTO de update contendo `Id`, `CriadoEm`, `OwnerId` e usando o valor do payload | 🟠 |

## C7 — Itens que existem no legado e faltam no moderno (inconsistência de cobertura)

| Sinal | Gravidade | Observação |
|---|---|---|
| Redirecionamento aberto (`Redirect(returnUrl)` sem validar) | 🔴 | Existe no legado, ausente no moderno. Correção: `Url.IsLocalUrl` / `LocalRedirect` |
| Cookie de autenticação sem `Secure`/`SameSite` | 🟠 | Ausente no moderno. Nuance real: `CookieAuthenticationOptions.Cookie.SecurePolicy` default é `SameAsRequest` — atrás de proxy que termina TLS e sem `ForwardedHeaders`, o cookie sai **sem** `Secure`. Forçar `Always` |
| Desserialização insegura por `TypeNameHandling` | 🔴 | O legado abençoa `Newtonsoft.Json` na seção de datação (correto) mas nenhum dos dois flagra `TypeNameHandling.Auto/Objects/All`, que é o gadget de RCE mais usado em .NET |

## C8 — Infraestrutura de segurança do ASP.NET Core que a skill ignora

| Sinal | Gravidade |
|---|---|
| Data Protection sem persistência de key ring em ambiente multi-instância/container | 🟠 (cookies e antiforgery quebram a cada restart/deploy) |
| Key ring persistido em volume/blob compartilhado **sem** `ProtectKeysWith...` | 🔴 (quem lê as chaves forja cookie de autenticação e token antiforgery) |
| `ForwardedHeaders` com `KnownProxies`/`KnownNetworks` limpos e `ForwardedHeaders.All` | 🟠 (IP de cliente falsificável → quebra rate limiting, allowlist de IP e trilha de auditoria) |
| Ausência de `UseHttpsRedirection`/`UseHsts` em app com navegador | 🟠 (não aplicável a API puramente máquina-a-máquina; HSTS é controle de navegador) |
| `ServerCertificateCustomValidationCallback` aceitando qualquer certificado (`DangerousAcceptAnyServerCertificateValidator`) | 🔴 |
| Antiforgery: `DisableAntiforgery()` espalhado em endpoints de formulário no .NET 8+ | 🟠 |
| Headers de resposta ausentes: `X-Content-Type-Options: nosniff`, `Referrer-Policy`, `frame-ancestors` | 🟡 |
| Ausência de log de auditoria para evento de segurança (login, falha de login, mudança de permissão, exportação de dados) | 🟠 (relevante para LGPD, e é achado recorrente em review de sistema regulado) |

## C9 — DoS por entrada (ReDoS e limites) — ausente nos dois

| Sinal | Gravidade |
|---|---|
| `Regex` com backtracking catastrófico, ou pattern construído a partir de input, sem `matchTimeout` | 🟠 (`RegexOptions.NonBacktracking` no .NET 7+, ou timeout explícito) |
| Ausência de `[MaxLength]`/`[StringLength]` em campo de texto livre que vai para banco ou regex | 🟠 |
| `JsonSerializerOptions.MaxDepth` elevado, ou grafo profundo/recursivo aceito no body | 🟠 |
| Paginação sem limite máximo de `pageSize` (`?pageSize=1000000`) | 🟠 |
| Endpoint que aceita `include`/`expand` arbitrário do cliente | 🟠 |

## C10 — XXE e XML (ausente nos dois; relevante sobretudo no legado)

| Sinal | Gravidade |
|---|---|
| `XmlDocument`/`XmlTextReader` carregando XML externo sem `XmlResolver = null` e `DtdProcessing = Prohibit` | 🔴 |
| `XmlReaderSettings` com `DtdProcessing = Parse` e resolver ativo | 🔴 |
| `XslCompiledTransform` com `EnableScript = true` sobre XSLT de terceiro | 🔴 |
| Ausência de `MaxCharactersFromEntities`/`MaxCharactersInDocument` (billion laughs) | 🟠 |

Nota de precisão importante para o documento: os defaults variam por API e por versão (`XmlReader.Create` é seguro por default; `XmlDocument`/`XmlTextReader` mudaram entre 4.0 e 4.5.2 e dependem de `targetFramework`). A orientação de review deve ser **"defina explicitamente, não confie no default"**, porque afirmar "é seguro por default em 4.5.2+" leva o revisor a aprovar código que roda com `httpRuntime targetFramework` antigo.

## C11 — Criptografia de uso geral (ausente nos dois)

| Sinal | Gravidade |
|---|---|
| `Aes` em modo ECB, ou IV fixo/zerado | 🔴 |
| Criptografia sem autenticação (sem AES-GCM, sem HMAC sobre o ciphertext) | 🟠 |
| `DES`, `TripleDES`, `RC2`, `MD5` para integridade | 🔴 |
| Criptografia caseira em vez de `IDataProtectionProvider` (moderno) / `MachineKey.Protect` (net4x 4.5+) | 🟠 |
| Chave de criptografia derivada de senha com `Rfc2898DeriveBytes` default (SHA1, iteração baixa) | 🟠 |

## C12 — Enumeração e vazamento por resposta (falta na seção "Erros na borda HTTP")

A seção acerta no mapeamento de status, mas falta o ângulo de segurança:

- **403 vs 404 em IDOR:** devolver 403 para recurso de outro usuário confirma que o id existe. Preferir 404 para recurso não pertencente.
- **Login não deve distinguir** "usuário não existe" de "senha incorreta" (enumeração de conta) — nem na mensagem, nem no status, nem no **tempo de resposta** (não pular o hash quando o usuário não existe; executar hash dummy).
- **`detail = ex.Message`** no `IExceptionHandler`/`ProblemDetails` é o vazamento mais comum de stack/SQL/caminho — vale item explícito.
- **`AddExceptionHandler<T>()` sem `app.UseExceptionHandler()`**: o handler nunca roda e a exceção sobe crua. É misconfiguração silenciosa com consequência de segurança.
- **Mensagem de validação ecoando o valor recebido** de campo sensível volta para o log e para o cliente.

## C13 — Logging: sinais que faltam

| Sinal | Gravidade |
|---|---|
| `EnableSensitiveDataLogging()` do EF Core habilitado fora de dev | 🔴 |
| `IConfiguration.GetDebugView()` logado na subida | 🔴 (despeja todos os segredos resolvidos) |
| Log de header `Authorization`/`Cookie` ou de URL com token em query string (`HttpClient` logging sem `RedactLoggedHeaders`) | 🔴 |
| Body de request/response logado integralmente em endpoint que trafega dado pessoal | 🟠 |
| Log forging: input do usuário com `\n`/`\r` escrito em log não estruturado | 🟡 (o log estruturado que o documento já recomenda mitiga — vale dizer isso explicitamente, é um argumento a mais para a recomendação que já existe) |
| Serilog destructurando DTO que contém senha/token (sem `Destructure.ByTransforming`) | 🟠 |

## C14 — Configuração e segredos: sinais que faltam

| Sinal | Gravidade |
|---|---|
| Segredo em `launchSettings.json`, `docker-compose.yml`, YAML de CI, `.env` versionado | 🔴 |
| `appsettings.Development.json` com credencial real de ambiente compartilhado | 🟠 |
| Segredo commitado e apenas removido do arquivo, sem rotação | 🔴 (permanece no histórico do Git) |
| Ausência de `dotnet list package --vulnerable` / auditoria de dependência (NuGetAudit) no pipeline | 🟠 |
| Chave de assinatura JWT ou de criptografia lida de `appsettings` em produção em vez de Key Vault/managed identity | 🟠 |

Nota de precisão a acrescentar: User Secrets é **texto claro** no perfil do usuário — é isolamento contra commit acidental, não controle criptográfico. Vale dizer, porque o documento pode ser lido como "User Secrets protege o segredo".

---

# (d) Legado: viabilidade das correções em .NET Framework 4.x

Veredito geral: as correções propostas na seção Segurança do `smells-legado.md` **são viáveis** em `net4x` — o problema não é viabilidade, é que **a maioria dos itens não traz correção nenhuma** (a tabela de Segurança tem só as colunas `Sinal | Grav.`, ao contrário das outras seções do mesmo arquivo, que têm `Correção`). Num review real, apontar 🔴 sem caminho de correção compatível com a plataforma é o que faz o autor ignorar o achado. Abaixo, viabilidade item a item e as armadilhas de plataforma.

## D1 — Hash de senha: viável, mas o caminho óbvio é o errado

| Opção em `net4x` | Viável? | Ressalva |
|---|---|---|
| `System.Web.Helpers.Crypto.HashPassword` / `Microsoft.AspNet.Identity` | Sim | **PBKDF2-HMAC-SHA1, 1.000 iterações.** Melhor que MD5, mas abaixo do aceitável hoje. Não recomendar como destino final |
| `Rfc2898DeriveBytes` com `HashAlgorithmName.SHA256` e ≥100k iterações | Sim, **só a partir de 4.7.2** | A sobrecarga que aceita `HashAlgorithmName` existe a partir do .NET Framework 4.7.2. Em ≤4.7.1, `Rfc2898DeriveBytes` é HMAC-SHA1 |
| `BCrypt.Net-Next` (NuGet) | Sim (net461+) | Caminho de menor risco na prática. Cost ≥10. Trunca em 72 bytes |
| `Konscious.Security.Cryptography.Argon2` (NuGet) | Sim | Argon2id; exige tuning de memória e atenção a consumo em pool IIS |
| Migração progressiva | Sim | Padrão: rehash no próximo login bem-sucedido, com marcador de versão no registro. Vale documentar, porque "trocar o hash" numa base existente é o obstáculo real e sem isso o achado não é acionável |

**Recomendação para o documento legado:** acrescentar coluna `Correção` com "BCrypt.Net-Next (ou Argon2) + rehash no login; se precisar ficar no BCL, `Rfc2898DeriveBytes` com SHA256 e ≥100k iterações exige 4.7.2+". Hoje o item não diz nada.

## D2 — Cookies: viável, com dois detalhes de versão

- `HttpOnly` e `Secure`: viáveis em qualquer 4.x — `<httpCookies httpOnlyCookies="true" requireSSL="true" />` e `<forms requireSSL="true" />`. **Armadilha a documentar:** `requireSSL="true"` no `<forms>` derruba a autenticação em qualquer ambiente que não seja HTTPS ponta a ponta (inclusive dev e healthcheck interno) — é a razão pela qual times revertem o ajuste. A correção precisa vir com a nota de ambiente.
- `SameSite`: **exige .NET Framework 4.7.2+** (com os patches de dezembro de 2019). `HttpCookie.SameSite`, `<httpCookies sameSite="...">`, `<forms cookieSameSite="Lax">`, `<sessionState cookieSameSite="Lax">`. Em ≤4.7.1 a única via é reescrever o header (`Response.AddOnSendingHeaders`, disponível desde 4.5.2) — viável, mas trabalhoso. O default de `sameSite` é `Lax` **se o app tem `targetFramework` 4.7.2+**, e `None` caso contrário: ou seja, um app rodando em 4.8 mas com `<httpRuntime targetFramework="4.5" />` no `web.config` **não** ganha o default seguro. Esse é exatamente o tipo de detalhe que um review de legado precisa checar, e é uma ótima adição à skill.
  Fonte: [Work with SameSite cookies in ASP.NET](https://learn.microsoft.com/aspnet/samesite/system-web-samesite#using-samesite-in-aspnet-472-and-48); [HttpCookiesSection.SameSite](https://learn.microsoft.com/dotnet/api/system.web.configuration.httpcookiessection.samesite).
- **Falta um item:** `<sessionState cookieless="UseUri" />` ou `<forms cookieless="UseUri">` coloca o id de sessão/ticket na URL — vaza em Referer, log de proxy e histórico. 🔴, viável de corrigir (`UseCookies`), e é achado clássico de `net4x`.

## D3 — Anti-forgery: viável, mas a correção difere por stack e o documento generaliza

| Stack `net4x` | Correção viável | Ressalva |
|---|---|---|
| MVC 5 | `@Html.AntiForgeryToken()` + `[ValidateAntiForgeryToken]` | `[AutoValidateAntiforgeryToken]` **não existe** no MVC 5 (é ASP.NET Core). O equivalente é filtro global próprio que valida só verbos não seguros — registrar `ValidateAntiForgeryTokenAttribute` como filtro global quebra GETs |
| Web Forms | `ViewStateUserKey` no `Page_Init` | Não há token anti-forgery; é outro mecanismo. O item genérico "ausência de anti-forgery token em POST" não se aplica literalmente |
| Web API 2 com cookie | Validação manual (`AntiForgery.Validate` a partir de header + cookie) | Não há suporte embutido. Se a API usa só `Authorization: Bearer`, CSRF não se aplica — apontar aqui é falso positivo |
| Web farm | Token depende de `<machineKey>` compartilhada | Amarra com A2: compartilhe a chave **sem versionar** |

## D4 — `customErrors`: viável, e falta o interruptor mais forte da plataforma

`<customErrors mode="RemoteOnly" defaultRedirect="~/Erro" />` é viável e correto. Duas adições viáveis e ausentes:

- **IIS 7+ integrado tem um segundo interruptor:** `<system.webServer><httpErrors errorMode="DetailedLocalOnly" />`. Só `customErrors` não cobre erros gerados pelo IIS antes do pipeline gerenciado.
- **`<deployment retail="true" />` no `machine.config`** do servidor de produção força `customErrors` on, desabilita trace e ignora `debug="true"`. É a trava de plataforma, viável em `net4x`, e é o item que resolve a família inteira.
- **Falta o item `<compilation debug="true" />` em produção** (🟠/🔴): além de performance e timeouts, expõe detalhe em erro e desabilita otimizações. Achado `net4x` clássico, e ausente da seção.
- **Falta `trace.axd` habilitado com `localOnly="false"`** (🔴): despeja cookies, sessão e headers das últimas requisições. E `elmah.axd` (ou similar) exposto sem autorização (🔴). Ambos são achados de `net4x` extremamente comuns em auditoria real e não estão no documento.

## D5 — TLS: o item está certo, mas a correção "óbvia" não é a viável

O sinal (`SecurityProtocol = Ssl3`) está correto. Falta a correção, e as ingênuas são armadilhas:

| Abordagem | Viável em `net4x`? | Veredito |
|---|---|---|
| `ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls13` | Só existe em 4.8, e depende de Windows 11/Server 2022 + SChannel; na prática não funciona | **Não recomendar** |
| Fixar `= Tls12` | Sim | Aceitável como remediação imediata, mas envelhece igual ao `Ssl3` que estamos consertando |
| **Retargetar para 4.7+ e deixar `SystemDefault`** (não mexer em `SecurityProtocol`) | Sim | **Correção preferida:** a partir do 4.7 o default delega ao SO, que passa a ser atualizável por patch/registro sem recompilar |
| `AppContextSwitchOverrides`: `Switch.System.Net.DontEnableSystemDefaultTlsVersions=false` / `DontEnableSchUseStrongCrypto=false` | Sim | Caminho para quem não pode retargetar (≤4.6) |
| Registro `SchUseStrongCrypto` (`HKLM\...\.NETFramework\v4.0.30319`) | Sim | Ajuste de máquina; combinar com o app |

**Item 🔴 ausente no mesmo tema:** `ServicePointManager.ServerCertificateValidationCallback = (s,c,ch,e) => true` (e o equivalente moderno `ServerCertificateCustomValidationCallback`). Desligar validação de certificado é mais grave e mais comum que fixar protocolo antigo — normalmente entra "temporariamente" para resolver erro de certificado em homologação e nunca sai.

## D6 — Desserialização: viável, com o caminho correto explicitado

`BinaryFormatter` continua **funcionando** em `net4x` (a remoção é .NET 9), então o achado é válido e a correção não pode ser "atualize o runtime". Caminhos viáveis, em ordem:

1. Trocar o formato por um com tipos fixos (`DataContractSerializer` com `KnownTypes` explícitos, `XmlSerializer`, JSON com tipo concreto) — correção real.
2. Se não puder trocar já: `SerializationBinder` com allowlist de tipos no `BinaryFormatter`. Mitigação, não solução — vale dizer isso, do mesmo jeito que o documento já faz com `ConfigureAwait(false)` na seção de deadlock (bom padrão desse arquivo, aplicar aqui também).
3. Se o payload é local e confiável mas passa por canal externo: HMAC do payload antes de desserializar.

**Irmãos ausentes, mesmo defeito:** `NetDataContractSerializer`, `LosFormatter`, `ObjectStateFormatter` (é a via do ViewState forjado, ligando com A2), `SoapFormatter`, `JavaScriptSerializer` com `SimpleTypeResolver`, e `Newtonsoft.Json` com `TypeNameHandling` diferente de `None`. Todos 🔴, todos frequentes em `net4x`.

## D7 — Seção Exceções: viabilidade OK, falta o ângulo de segurança

As correções da seção Exceções (`throw;`, exceção específica, logar com stack e inner) são todas viáveis em `net4x` sem ressalva. O que falta é o recorte de segurança:

| Sinal | Gravidade |
|---|---|
| `catch` vazio ou "loga e continua" em caminho de verificação (permissão, assinatura, token, decriptação, validação de pagamento) | 🔴 (converte fail-closed em fail-open) |
| `Exception.Message` de `SqlException`/`WebException` devolvido ou logado com connection string, URL com token ou credencial embutida | 🟠 |
| `Application_Error` logando o request inteiro (form + cookies) | 🟠 (vaza senha do POST de login para o log) |
| `Server.ClearError()` sem log | 🔴 (já coberto parcialmente em "ASP.NET: acoplamento") |

Nota de consistência: `Detalhe da exceção exibido na tela` está 🔴 aqui e o equivalente moderno (`Mensagem de erro detalhada para o cliente`) está 🟠 — ver B2.

---

## Sugestão de fechamento para a skill

Três mudanças estruturais valem mais que qualquer item individual:

1. **A seção Segurança do `smells-legado.md` precisa da coluna `Correção`**, como todas as outras seções do mesmo arquivo têm. Hoje ela é a única tabela puramente diagnóstica do documento, e é justamente a que mais depende de nuance de plataforma (4.7.2 para SameSite, 4.7.2 para PBKDF2-SHA256, 4.5.2 para ViewState MAC).
2. **Separar "authz vertical" de "authz horizontal"** nos dois documentos. Hoje só existe IDOR (horizontal); falta o vertical, que é bypass igualmente 🔴 e mais fácil de detectar em review.
3. **Reservar o 🔴 para o que falha aberto.** Três dos 🔴 atuais (`AllowAnyOrigin`+`AllowCredentials`, ordem de middleware de autorização, `enableViewStateMac="false"`) falham fechado ou são inócuos na plataforma atual, enquanto XSS por `Html.Raw`, SSRF, mass assignment, path traversal em upload e JWT sem validação de issuer/audience — todos fail-open — não estão catalogados.
