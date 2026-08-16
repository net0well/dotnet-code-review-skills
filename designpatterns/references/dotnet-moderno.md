# .NET moderno: checklist de review por área

Esta é a maior fonte de achados 🔴 e 🟠 **legítimos**, porque são defeitos objetivos e não preferência de design. Percorra as áreas relevantes ao código recebido.

Assume .NET 8 ou superior e C# 12+. Para `net4x`, use a skill `designpatterns-legacy`.

## Índice

- [Async e concorrência](#async-e-concorrência)
- [CancellationToken](#cancellationtoken)
- [Injeção de dependência e lifetimes](#injeção-de-dependência-e-lifetimes)
- [Entity Framework Core](#entity-framework-core)
- [HttpClient e resiliência](#httpclient-e-resiliência)
- [Configuração e segredos](#configuração-e-segredos)
- [Logging e observabilidade](#logging-e-observabilidade)
- [Erros na borda HTTP](#erros-na-borda-http)
- [Nullable reference types](#nullable-reference-types)
- [C# moderno: o que usar](#c-moderno-o-que-usar)
- [Minimal APIs e ASP.NET Core](#minimal-apis-e-aspnet-core)
- [Background services](#background-services)
- [Performance e alocação](#performance-e-alocação)
- [Segurança](#segurança)
- [Descarte de recursos](#descarte-de-recursos)
- [Quando NÃO recomendar cada tecnologia](#quando-não-recomendar-cada-tecnologia)

---

## Async e concorrência

| Sinal | Gravidade | Problema | Correção |
|---|---|---|---|
| `async void` (fora de event handler) | 🔴 | Exceção não é capturável e derruba o processo | `async Task` |
| `.Result`, `.Wait()`, `.GetAwaiter().GetResult()` | 🔴 | Bloqueia thread do pool; risco de deadlock e de thread pool starvation sob carga | `await` até a borda |
| `Task.Run` para embrulhar I/O | 🟠 | Gasta thread sem ganho; I/O já é assíncrono | Chamar o método `...Async` direto |
| `async` sem `await` no corpo | 🟡 | Máquina de estado sem necessidade | Remover `async` e devolver a `Task` |
| Loop com `await` sequencial em chamadas independentes | 🟠 | Latência somada em vez de paralela | `await Task.WhenAll(tasks)` com cuidado de limite de concorrência |
| `Task.WhenAll` sobre `DbContext` compartilhado | 🔴 | `DbContext` não é thread safe | Sequencial, ou um escopo/contexto por tarefa |
| `lock` em volta de `await` | 🔴 | Não compila com `lock`, e usar `Monitor` manualmente entre awaits corrompe o estado | `SemaphoreSlim.WaitAsync()` |
| Campo mutável compartilhado sem sincronização em singleton | 🔴 | Race condition | `ConcurrentDictionary`, `Interlocked`, `Lock` (.NET 9+) |
| `List<T>` sendo populada por várias tasks | 🔴 | `List<T>` não é thread safe; corrompe ou lança | `ConcurrentBag`, ou coletar resultados de `WhenAll` |
| `ConfigureAwait(false)` em ASP.NET Core | 🟢 | Desnecessário: não há `SynchronizationContext`. Não é defeito, só ruído | Pode remover; obrigatório apenas em bibliotecas que também rodam em UI/legado |
| `await` dentro de `foreach` sobre `IEnumerable` de banco | 🟠 | Pode manter conexão aberta por muito tempo | Materializar antes, ou usar `IAsyncEnumerable` deliberadamente |

## CancellationToken

- Todo método assíncrono público que faz I/O deve aceitar `CancellationToken`, e **propagar** para as chamadas internas. Token aceito e ignorado é pior que não aceitar, porque promete cancelamento que não acontece.
- Em Minimal APIs e controllers, o token vem por injeção automática. Se o endpoint não recebe, requisição abortada continua consumindo banco.
- `EF Core`, `HttpClient`, `Stream` e `Channel` aceitam token em todos os métodos assíncronos.
- Cancelamento **não é erro**: não logue `OperationCanceledException` como falha.
- Em `BackgroundService`, respeite o `stoppingToken` no loop, senão o shutdown trava até o timeout do host.

```csharp
// sinal de problema: token aceito e não propagado
public async Task<Order?> GetAsync(Guid id, CancellationToken ct = default) =>
    await db.Orders.FirstOrDefaultAsync(o => o.Id == id);   // falta o ct

// correção
    await db.Orders.FirstOrDefaultAsync(o => o.Id == id, ct);
```

## Injeção de dependência e lifetimes

| Sinal | Gravidade | Problema |
|---|---|---|
| `Scoped` injetado em `Singleton` | 🔴 | Captive dependency: `DbContext` preso vive para sempre, acumula tracking e vaza dados entre requisições |
| `IServiceProvider` injetado em regra de negócio | 🟠 | Service Locator: dependências escondidas, falha em runtime |
| `IServiceScopeFactory` ausente em `BackgroundService` que usa `DbContext` | 🔴 | Hosted service é singleton; precisa criar escopo por operação |
| `new` de serviço registrado no container | 🟠 | Ignora o container, perde configuração e lifetime |
| Registro duplicado com lifetimes diferentes | 🟠 | Comportamento imprevisível |
| `AddTransient` em objeto caro (cliente HTTP, cache) | 🟡 | Custo desnecessário |
| Validação de escopo desligada | 🟠 | Remove a única detecção automática de captive dependency |

```csharp
// correto: singleton consumindo algo scoped
public sealed class Reconciler(IServiceScopeFactory scopeFactory) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            using var scope = scopeFactory.CreateScope();
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            await db.SaveChangesAsync(stoppingToken);
            await Task.Delay(TimeSpan.FromMinutes(5), stoppingToken);
        }
    }
}
```

## Entity Framework Core

Fonte muito frequente de 🔴 real, e frequentemente ignorada em reviews focados só em design.

| Sinal | Gravidade | Problema | Correção |
|---|---|---|---|
| Query ao banco (`Where`, `First`, `LoadAsync`) dentro de `foreach` | 🔴 | N+1 de verdade: uma ida ao banco por item | Uma query só, com `Include()` ou projeção; ou carregar as chaves e fazer `Where(x => ids.Contains(x.Id))` |
| Navegação lida sem `Include` nem projeção | 🔴 | **Depende de proxies, e os dois casos são ruins.** Com `UseLazyLoadingProxies()`: N+1. Sem proxies: devolve `null` na referência e coleção vazia, ou pior, o *relationship fixup* do change tracker preenche **parcialmente** com o que já está rastreado, o que dá dado errado sem erro nenhum e muda conforme a ordem das queries anteriores | `Include()` explícito ou projeção. **Em review, verifique primeiro se `UseLazyLoadingProxies()` está registrado**, porque isso decide qual dos dois defeitos você está olhando |
| `ToList()` antes de `Where()` | 🔴 | Traz a tabela e filtra em memória | Filtrar no `IQueryable` |
| Query que materializa **entidades** num caminho só de leitura, sem `AsNoTracking()` | 🟠 | Change tracking pago sem uso, e mutação acidental fica persistível pelo próximo `SaveChanges` (note: `AsNoTracking` não impede mutar o objeto, só impede persistir) | `AsNoTracking()`, ou `AsNoTrackingWithIdentityResolution()` se o grafo repete referências ao mesmo pai |
| `AsNoTracking()` numa query que já projeta para DTO | 🟢 | Projeção para tipo que não é entidade **já não é rastreada**: a chamada não faz nada | Remover como ruído. Não é defeito, e não vale achado |
| Projetar a entidade inteira para devolver 3 campos | 🟠 | Tráfego e memória desperdiçados | `Select()` para DTO |
| `SaveChangesAsync` dentro de loop | 🔴 | Uma transação por item; lento e sem atomicidade | Um `SaveChangesAsync` no fim |
| Paginação com `Skip/Take` sem `OrderBy` | 🟠 | Ordem não determinística, itens repetidos ou perdidos entre páginas | `OrderBy` estável antes |
| SQL concatenado com interpolação em `FromSqlRaw` | 🔴 | SQL injection | `FromSql` com interpolação parametrizada, ou parâmetros explícitos |
| `Include` em cascata profunda | 🟠 | Explosão cartesiana de linhas | `AsSplitQuery()` ou projeção |
| Update lendo a entidade só para alterar um campo | 🟡 | Round trip extra | `ExecuteUpdateAsync`, **com as ressalvas abaixo** |
| Delete carregando entidades | 🟡 | Round trip extra | `ExecuteDeleteAsync`, **com as ressalvas abaixo** |
| `DbContext` usado concorrentemente | 🔴 | Não é thread safe | Um contexto por unidade de trabalho |
| Migration ausente para mudança de modelo | 🟠 | Divergência entre modelo e banco | Gerar migration |
| Lazy loading habilitado | 🟠 | N+1 silencioso e difícil de rastrear | Desabilitar, usar `Include` explícito |

### Ressalvas de `ExecuteUpdateAsync` e `ExecuteDeleteAsync`

São ótimos para operação em lote, e péssimos como substituto genérico de `SaveChanges`. Nunca recomende sem dizer isto, porque cada item é uma forma de perder garantia que o autor achava que tinha:

- **Executam na hora, fora do change tracker.** Não é unidade de trabalho: se você já tinha alterações pendentes, elas não vão junto, e entidades já rastreadas ficam **desatualizadas** em memória.
- **Não verificam concorrência otimista.** Um `RowVersion` no modelo é simplesmente ignorado, então a atualização sobrescreve mudança de outro usuário sem erro.
- **Não disparam nada que esteja pendurado no `SaveChanges`:** interceptors, eventos de domínio, auditoria, `SaveChangesAsync` sobrescrito.
- **Não aplicam comportamento em cascata do modelo** nem soft delete implementado por interceptor ou query filter na escrita.
- **Não entram na mesma transação** de um `SaveChanges` vizinho, a não ser que você abra a transação explicitamente.

Regra prática para o review: em operação de lote sem invariante e sem auditoria, recomende. Em fluxo de domínio com agregado, concorrência ou evento, não recomende.

## HttpClient e resiliência

| Sinal | Gravidade | Problema |
|---|---|---|
| `new HttpClient()` por requisição | 🔴 | Socket exhaustion (portas em TIME_WAIT) |
| `HttpClient` estático de longa duração | 🟠 | Não respeita mudança de DNS |
| Chamada externa sem timeout | 🔴 | Uma dependência lenta trava o pool de threads |
| Chamada externa sem retry para falha transitória | 🟠 | Falha evitável chegando ao usuário |
| Retry sem backoff nem jitter | 🟠 | Amplifica a falha do serviço remoto |
| Retry em operação não idempotente (POST de cobrança) | 🔴 | Efeito duplicado. Exige chave de idempotência |
| Sem circuit breaker em dependência crítica | 🟡 | Continua batendo em serviço morto |
| `EnsureSuccessStatusCode()` sem tratamento | 🟠 | Exceção genérica, perde o corpo do erro |

Forma idiomática: `AddHttpClient<TClient>()` com `AddStandardResilienceHandler()` (`Microsoft.Extensions.Http.Resilience`), que já traz timeout, retry com backoff, circuit breaker e rate limiter em ordem sensata.

## Configuração e segredos

| Sinal | Gravidade |
|---|---|
| Connection string, chave de API ou senha em `appsettings.json` versionado | 🔴 |
| `IConfiguration["Chave:Aninhada"]` espalhado na regra de negócio | 🟠 |
| Options sem validação | 🟠 |
| Configuração lida no construtor de singleton quando precisa recarregar | 🟡 |

Forma correta: classe de opções tipada, `AddOptions<T>().BindConfiguration(...).ValidateDataAnnotations().ValidateOnStart()`. Falhar na subida é preferível a falhar em produção. Segredos em User Secrets no dev, e Key Vault ou variáveis de ambiente em produção.

## Logging e observabilidade

| Sinal | Gravidade | Problema |
|---|---|---|
| `Console.WriteLine` para diagnóstico | 🟠 | Não estruturado, sem nível, sem correlação |
| Interpolação de string no log: `LogInformation($"id {id}")` | 🟠 | Perde o log estruturado; impede busca por campo |
| Log de dado sensível (senha, token, CPF, cartão) | 🔴 | Vazamento em repositório de log |
| `LogError` sem passar a exceção | 🟠 | Perde stack trace |
| Log dentro de loop quente | 🟡 | Custo e ruído |
| Exceção logada e relançada no mesmo nível | 🟡 | Log duplicado |
| Ausência de correlation id em sistema distribuído | 🟡 | Impossível seguir a requisição |

```csharp
// errado: perde estrutura
log.LogInformation($"Pedido {id} confirmado em {elapsed}ms");
// certo: campos nomeados, pesquisáveis
log.LogInformation("Pedido {OrderId} confirmado em {Elapsed}", id, elapsed);
```

## Erros na borda HTTP

- Use `ProblemDetails` (RFC 9457) como contrato único de erro. `AddProblemDetails()` mais `IExceptionHandler` (.NET 8+) evita `try/catch` em cada endpoint.
- Nunca devolva stack trace nem mensagem de exceção crua ao cliente.
- Mapeie: validação para 400/422, não encontrado para 404, conflito de concorrência para 409, autorização para 401/403.
- Erro de negócio esperado deve ser `Result`, e o endpoint traduz. Erro inesperado sobe e o handler global trata.

## Nullable reference types

| Sinal | Gravidade |
|---|---|
| `<Nullable>` ausente ou `disable` em projeto novo | 🟠 |
| `!` (null-forgiving) usado para silenciar aviso sem garantia real | 🟠 |
| `#pragma warning disable CS86xx` | 🟠 |
| Propriedade de referência não anulável sem `required` nem inicialização | 🟡 |
| Checagem `== null` em tipo declarado não anulável (indica que o contrato mente) | 🟡 |

O `!` é aceitável quando você tem garantia que o compilador não consegue provar, e nesse caso o review deve pedir um comentário curto explicando a garantia.

## C# moderno: o que usar

Recomende quando melhora legibilidade, não por modernidade.

| Situação | Prefira |
|---|---|
| Serviço com dependências | Construtor primário |
| DTO, contrato, evento | `record` |
| Value object pequeno | `readonly record struct` |
| Criação de coleção | Collection expression `[]`, spread `[..a, ..b]` |
| Despacho por tipo ou por forma | `switch` de expressão com pattern matching |
| Campo obrigatório | `required` com `init` |
| SQL, JSON ou XML embutido | Raw string literal `"""` |
| Propriedade com validação | Palavra-chave `field` (C# 14) |
| Dicionário só de leitura e quente | `FrozenDictionary` |
| Membros extra em tipo externo | Extension members (C# 14) |
| Relógio | `TimeProvider`, nunca `DateTime.Now` |
| Data sem hora | `DateOnly` / `TimeOnly` |
| Instante | `DateTimeOffset`, não `DateTime` |
| Cache | `HybridCache` (unifica memória e distribuído, com stampede protection) |

Cuidados a apontar: pattern matching aninhado profundo fica ilegível (extraia método); `var` quando o tipo não é óbvio prejudica leitura; `record` mutável com `set` público perde o sentido.

## Minimal APIs e ASP.NET Core

| Sinal | Gravidade |
|---|---|
| Regra de negócio dentro do endpoint ou controller | 🟠 |
| Endpoint sem `CancellationToken` | 🟠 |
| Entidade do EF devolvida direto na resposta | 🟠 (acopla contrato de API ao esquema, e pode vazar campo) |
| Endpoint sem `Produces`/`TypedResults` | 🟡 (OpenAPI incompleto) |
| Ausência de rate limiting em endpoint público de escrita | 🟡 |
| CORS: `SetIsOriginAllowed(_ => true)` junto com `AllowCredentials` | 🔴 Reflete qualquer origem **com** credenciais, e é a variante realmente explorável |
| CORS: `AllowAnyOrigin` mais `AllowCredentials` | 🟡 Falha **fechada**: gera resposta CORS inválida que o navegador rejeita. Corrija, mas não gaste severidade crítica nisso |
| Ordem de middleware errada (autorização antes de autenticação) | 🔴 |
| Endpoints repetindo o mesmo prefixo em vez de `MapGroup` | 🟢 |

Use `TypedResults` em vez de `Results` quando quiser metadados de OpenAPI corretos, e `MapGroup` com filtros para preocupações compartilhadas.

## Background services

| Sinal | Gravidade | Problema |
|---|---|---|
| `ExecuteAsync` sem `try/catch` no loop | 🔴 | Desde o .NET 6 o default é `StopHost`: exceção não tratada é logada e **para o host inteiro**, derrubando também a API que roda no mesmo processo. Pior, o host para de forma limpa com exit code 0, então orquestrador e Windows Service podem **não reiniciar**. Se quer restart, `Environment.Exit(código != 0)` no catch |
| `stoppingToken` ignorado | 🟠 | Shutdown trava até o timeout |
| `DbContext` injetado direto no hosted service | 🔴 | Captive dependency; precisa de escopo por iteração |
| Trabalho pesado no `StartAsync` | 🟠 | Atrasa a subida da aplicação |
| `Task.Delay` sem token | 🟠 | Não cancela |

## Performance e alocação

Só levante se houver evidência ou se for caminho claramente quente. Otimização sem medição é aposta, e sugerir micro-otimização em CRUD é ruído.

| Sinal | Quando importa |
|---|---|
| Concatenação de string em loop | Loop com muitas iterações: `StringBuilder` |
| LINQ com múltiplas passagens sobre coleção grande | Uma passagem, ou `foreach` |
| `Count()` em `IEnumerable` quando existe `Count` | Sempre: evita enumerar |
| `Any()` versus `Count() > 0` | Sempre: `Any()` para-cedo |
| Boxing em caminho quente | Genéricos, `Span<T>` |
| Alocação de buffer grande por requisição | `ArrayPool<T>` com `try/finally` |
| `ToList()` só para iterar uma vez | Remover a materialização |
| `async` em método trivial de caminho quente | `ValueTask` quando o resultado costuma ser síncrono |

## Segurança

| Sinal | Gravidade |
|---|---|
| SQL concatenado ou interpolado sem parâmetro | 🔴 |
| Segredo hardcoded | 🔴 |
| Senha com hash próprio ou MD5/SHA1 | 🔴 (use `IPasswordHasher`, Argon2, bcrypt) |
| Endpoint de escrita sem `RequireAuthorization` | 🔴 |
| Autorização por role hardcoded espalhada | 🟠 (políticas nomeadas) |
| Falta de verificação de propriedade do recurso (IDOR) | 🔴 (usuário A acessando pedido de B pelo id) |
| Dado sensível em log ou em URL | 🔴 |
| Deserialização de tipo arbitrário | 🔴 |
| Mensagem de erro detalhada para o cliente | 🟠 |
| Ausência de validação de tamanho em upload | 🟠 |
| Nome de arquivo de upload usado no caminho de gravação | 🔴 Path traversal com `..\`. Gere o nome você mesmo e valide a extensão por allowlist |
| Identidade lida do corpo, de query, ou de header (`X-User-Id`) em vez do `ClaimsPrincipal` | 🔴 O cliente escolhe quem ele é |
| Endpoint de admin com `[Authorize]` sem policy nem role | 🔴 Autenticado não é autorizado. Authz vertical ausente |
| `ValidateIssuer = false` ou `ValidateAudience = false` no JWT | 🔴 Aceita token emitido para outro sistema (audience confusion) |
| Binding do request direto na entidade de domínio | 🟠 Mass assignment: o cliente escreve em campo que você não expôs. Use DTO com só o que é editável |
| URL fornecida pelo usuário usada em `HttpClient` | 🟠 SSRF, com risco maior em nuvem por causa do endpoint de metadados. Allowlist de host |
| Comparação de token ou hash com `==` | 🟡 Timing attack. `CryptographicOperations.FixedTimeEquals` |
| Regex com quantificador aninhado sobre entrada do usuário | 🟠 ReDoS. Defina `matchTimeout` ou use `RegexOptions.NonBacktracking` |

### XSS e encoding de saída

Fica em seção própria porque é a categoria que mais aparece em aplicação web e a mais fácil de passar batido num review focado em design. A regra: **encoding é responsabilidade do ponto de saída, e o contexto de saída define o encoder.**

| Sinal | Gravidade | Observação |
|---|---|---|
| `@Html.Raw(algoQueVeioDoUsuario)` | 🔴 Razor encoda por padrão; `Html.Raw` é exatamente o desligamento dessa proteção |
| `MarkupString` em Blazor com conteúdo de usuário | 🔴 Mesmo mecanismo, nome diferente |
| `innerHTML` em JS recebendo valor do servidor sem encoding | 🔴 Contexto JS dentro de HTML precisa de encoder de JS, não de HTML |
| Valor de usuário interpolado dentro de `<script>` no Razor | 🔴 Serialize com `System.Text.Json` e leia como dado, não como código |
| Valor de usuário em atributo `href`/`src` | 🟠 `javascript:` continua funcionando. Valide o esquema |
| Ausência de Content-Security-Policy | 🟡 Não substitui encoding, mas reduz muito o impacto de uma falha |
| Sanitização caseira com `Replace("<script>", "")` | 🔴 Blacklist de HTML nunca funciona. Use encoding, ou HtmlSanitizer se HTML rico é requisito |

Não aceite configuração como prova de proteção: filtro de request no pipeline não conserta um `Html.Raw`.

## Descarte de recursos

| Sinal | Gravidade |
|---|---|
| `IDisposable` criado sem `using` | 🔴 |
| Classe com campo `IDisposable` sem implementar `IDisposable` | 🟠 |
| `IAsyncDisposable` descartado com `using` sincrônico | 🟠 (`await using`) |
| `Stream`/`FileStream` sem descarte em caminho de exceção | 🔴 |
| Inscrição em `event` sem cancelamento em objeto de vida longa | 🔴 (vazamento) |
| `CancellationTokenSource` não descartado | 🟡 |

## Quando NÃO recomendar cada tecnologia

O usuário pediu explicitamente que a skill avalie contexto antes de sugerir. Guia rápido:

| Tecnologia | Não recomende quando |
|---|---|
| MediatR / mediator | Não vai usar pipeline de behaviors. E verifique licenciamento comercial nas versões recentes |
| CQRS | Leitura e escrita têm exigências parecidas; CRUD simples |
| Clean Architecture (4 projetos) | Domínio sem complexidade real. Prefira Vertical Slice |
| Repository | `DbContext` já resolve e não há agregado nem query de negócio nomeada |
| AutoMapper e similares | O mapeamento é trivial e explícito é mais legível e depurável. Verifique licenciamento |
| Aspire | Projeto único sem orquestração local de múltiplos recursos |
| Microsserviços | Time pequeno, domínio não estabilizado. Monolito modular primeiro |
| Event sourcing | Não há requisito de auditoria temporal nem replay |
| gRPC | Cliente é navegador sem proxy, ou o contrato precisa ser legível por humanos |
| Dapper substituindo EF | Não há gargalo medido de query |
| Redis distribuído | Instância única sem necessidade de cache compartilhado. `HybridCache` local resolve |
| Feature flags | Não há entrega contínua nem rollout gradual |
